const std = @import("std");
const legacy = @import("http_saasm_api.zig");
const sa_std_net = @import("sa_std_net.zig");

pub const max_v2_message_bytes: u64 = 16 * 1024 * 1024;
pub const default_v2_response_bytes: u64 = 16 * 1024 * 1024;

pub const NetworkStatus = enum(u32) {
    ok = 0,
    would_block = 1,
    closed = 2,
    timeout = 3,
    too_large = 4,
    invalid = 5,
    io_error = 6,
};

pub const PollEvent = struct {
    pub const readable: u32 = 1;
    pub const writable: u32 = 2;
    pub const closed: u32 = 4;
};

const V2Error = error{
    WouldBlock,
    Closed,
    Timeout,
    TooLarge,
    Invalid,
    Io,
};

fn statusCode(status: NetworkStatus) u32 {
    return @intFromEnum(status);
}

fn statusFromV2Error(err: V2Error) NetworkStatus {
    return switch (err) {
        error.WouldBlock => .would_block,
        error.Closed => .closed,
        error.Timeout => .timeout,
        error.TooLarge => .too_large,
        error.Invalid => .invalid,
        error.Io => .io_error,
    };
}

fn statusFromOperationError(err: anyerror, has_timeout: bool) NetworkStatus {
    return switch (err) {
        error.WouldBlock => if (has_timeout) .timeout else .would_block,
        error.ConnectionTimedOut => .timeout,
        error.EndOfStream,
        error.BrokenPipe,
        error.ConnectionAborted,
        error.ConnectionResetByPeer,
        error.NotOpenForReading,
        error.NotOpenForWriting,
        => .closed,
        error.StreamTooLong, error.BodyTooLarge => .too_large,
        error.InvalidCharacter,
        error.InvalidContentLength,
        error.InvalidPort,
        error.InvalidUri,
        error.UriMissingHost,
        error.UnsupportedUriScheme,
        error.HttpHeadersInvalid,
        error.HttpHeadersOversize,
        error.InvalidWebSocketFrame,
        error.InvalidArgument,
        => .invalid,
        else => .io_error,
    };
}

fn requiredSlice(ptr: ?[*]const u8, len: u64) V2Error![]const u8 {
    if (len > std.math.maxInt(usize)) return error.Invalid;
    if (len == 0) return "";
    return (ptr orelse return error.Invalid)[0..@intCast(len)];
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        const valid = std.ascii.isAlphanumeric(ch) or switch (ch) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
        if (!valid) return false;
    }
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n\x00") == null;
}

fn methodFromCode(method: u8) ?legacy.HttpMethod {
    return switch (method) {
        1 => .get,
        2 => .post,
        3 => .put,
        4 => .delete,
        else => null,
    };
}

pub export fn sa_http_client_new_v2(
    use_tls: u8,
    ca_bundle_path_ptr: ?[*]const u8,
    ca_bundle_path_len: u64,
    out_client: ?*?*anyopaque,
) u32 {
    const slot = out_client orelse return statusCode(.invalid);
    slot.* = null;
    const ca_path = requiredSlice(ca_bundle_path_ptr, ca_bundle_path_len) catch return statusCode(.invalid);
    const client = legacy.HttpClient.init(std.heap.page_allocator, .{
        .use_tls = use_tls,
        .ca_bundle_path = if (ca_path.len == 0) null else ca_path,
    }) catch |err| return statusCode(statusFromOperationError(err, false));
    slot.* = @ptrCast(client);
    return statusCode(.ok);
}

pub export fn sa_http_client_req_new_v2(
    client: ?*anyopaque,
    method: u8,
    url_ptr: ?[*]const u8,
    url_len: u64,
    out_req: ?*?*anyopaque,
) u32 {
    const slot = out_req orelse return statusCode(.invalid);
    slot.* = null;
    const client_ptr = client orelse return statusCode(.invalid);
    const url = requiredSlice(url_ptr, url_len) catch return statusCode(.invalid);
    if (url.len == 0) return statusCode(.invalid);
    const http_method = methodFromCode(method) orelse return statusCode(.invalid);
    const cli: *legacy.HttpClient = @ptrCast(@alignCast(client_ptr));
    cli.retain();
    const request = legacy.HttpRequest.init(cli, .{
        .method = http_method,
        .url = url,
    }) catch |err| {
        cli.release();
        return statusCode(statusFromOperationError(err, false));
    };
    request.retains_client = true;
    slot.* = @ptrCast(request);
    return statusCode(.ok);
}

pub export fn sa_http_client_req_add_header_v2(
    req: ?*anyopaque,
    key_ptr: ?[*]const u8,
    key_len: u64,
    value_ptr: ?[*]const u8,
    value_len: u64,
) u32 {
    const req_ptr = req orelse return statusCode(.invalid);
    const key = requiredSlice(key_ptr, key_len) catch return statusCode(.invalid);
    const value = requiredSlice(value_ptr, value_len) catch return statusCode(.invalid);
    if (!validHeaderName(key) or !validHeaderValue(value)) return statusCode(.invalid);
    const request: *legacy.HttpRequest = @ptrCast(@alignCast(req_ptr));
    const name_copy = request.allocator.dupe(u8, key) catch return statusCode(.io_error);
    const value_copy = request.allocator.dupe(u8, value) catch {
        request.allocator.free(name_copy);
        return statusCode(.io_error);
    };
    request.headers.append(.{ .name = name_copy, .value = value_copy }) catch {
        request.allocator.free(name_copy);
        request.allocator.free(value_copy);
        return statusCode(.io_error);
    };
    return statusCode(.ok);
}

pub export fn sa_http_client_req_set_body_v2(req: ?*anyopaque, body_ptr: ?[*]const u8, body_len: u64) u32 {
    const req_ptr = req orelse return statusCode(.invalid);
    const body = requiredSlice(body_ptr, body_len) catch return statusCode(.invalid);
    const request: *legacy.HttpRequest = @ptrCast(@alignCast(req_ptr));
    const body_copy = request.allocator.dupe(u8, body) catch return statusCode(.io_error);
    if (request.body) |old| request.allocator.free(old);
    request.body = body_copy;
    return statusCode(.ok);
}

pub export fn sa_http_client_req_set_timeout_v2(req: ?*anyopaque, timeout_ms: u32) u32 {
    const req_ptr = req orelse return statusCode(.invalid);
    const request: *legacy.HttpRequest = @ptrCast(@alignCast(req_ptr));
    request.timeout_ms = timeout_ms;
    return statusCode(.ok);
}

pub export fn sa_http_client_req_set_max_response_bytes_v2(req: ?*anyopaque, max_bytes: u64) u32 {
    const req_ptr = req orelse return statusCode(.invalid);
    if (max_bytes == 0 or max_bytes > std.math.maxInt(usize)) return statusCode(.invalid);
    const request: *legacy.HttpRequest = @ptrCast(@alignCast(req_ptr));
    request.max_response_bytes = max_bytes;
    return statusCode(.ok);
}

const Deadline = struct {
    started: ?std.time.Instant,
    duration_ns: u64 = 0,
    immediate: bool = false,

    fn request(timeout_ms: u32) Deadline {
        if (timeout_ms == 0) return .{ .started = null };
        return .{
            .started = std.time.Instant.now() catch null,
            .duration_ns = @as(u64, timeout_ms) * std.time.ns_per_ms,
        };
    }

    fn operation(timeout_ms: u32) Deadline {
        return .{
            .started = std.time.Instant.now() catch null,
            .duration_ns = @as(u64, timeout_ms) * std.time.ns_per_ms,
            .immediate = timeout_ms == 0,
        };
    }

    fn hasTimeout(self: Deadline) bool {
        return self.started != null;
    }

    fn remainingNs(self: Deadline) V2Error!u64 {
        const started = self.started orelse return 0;
        const now = std.time.Instant.now() catch return error.Io;
        const elapsed = now.since(started);
        if (elapsed >= self.duration_ns) return error.Timeout;
        return self.duration_ns - elapsed;
    }

    fn pollMillis(self: Deadline) V2Error!u32 {
        if (self.immediate) return 0;
        if (self.started == null) return 0;
        const remaining = try self.remainingNs();
        const rounded = @divFloor(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(rounded, std.math.maxInt(u32)));
    }

    fn socketMillis(self: Deadline) V2Error!u32 {
        if (self.immediate) return 1;
        if (self.started == null) return 0;
        const remaining = try self.remainingNs();
        const rounded = @divFloor(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@max(@as(u64, 1), @min(rounded, std.math.maxInt(u32))));
    }
};

fn timevalFromMs(timeout_ms: u32) std.posix.timeval {
    return .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
}

fn setConnectionTimeout(connection: *std.http.Client.Connection, timeout_ms: u32) V2Error!void {
    const value = timevalFromMs(timeout_ms);
    std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&value)) catch return error.Io;
    std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&value)) catch return error.Io;
}

fn cloneResponseHeaders(allocator: std.mem.Allocator, response: std.http.Client.Response) ![]std.http.Header {
    var headers = std.ArrayList(std.http.Header).init(allocator);
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        headers.deinit();
    }
    var iterator = response.iterateHeaders();
    while (iterator.next()) |header| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        try headers.append(.{ .name = name, .value = value });
    }
    return headers.toOwnedSlice();
}

fn freeResponseHeaders(allocator: std.mem.Allocator, headers: []std.http.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

fn requestCancelled(tracker: ?*V2AsyncOp) bool {
    return if (tracker) |op| op.cancelled() else false;
}

fn mapHttpError(err: anyerror, deadline: Deadline, tracker: ?*V2AsyncOp) V2Error {
    if (requestCancelled(tracker)) return error.Closed;
    if (deadline.hasTimeout() and (err == error.UnexpectedReadFailure or err == error.UnexpectedWriteFailure)) {
        const remaining = deadline.remainingNs() catch |deadline_err| return deadline_err;
        if (remaining <= std.time.ns_per_ms) return error.Timeout;
    }
    return switch (statusFromOperationError(err, deadline.hasTimeout())) {
        .would_block => error.WouldBlock,
        .closed => error.Closed,
        .timeout => error.Timeout,
        .too_large => error.TooLarge,
        .invalid => error.Invalid,
        .io_error => error.Io,
        .ok => unreachable,
    };
}

fn checkRequestState(deadline: Deadline, tracker: ?*V2AsyncOp) V2Error!void {
    if (requestCancelled(tracker)) return error.Closed;
    _ = deadline.socketMillis() catch |err| return err;
}

fn configureRequestConnection(connection: *std.http.Client.Connection, deadline: Deadline, tracker: ?*V2AsyncOp) V2Error!void {
    if (tracker) |op| try op.attach(connection.stream.handle);
    errdefer if (tracker) |op| op.detach(connection.stream.handle);
    try setConnectionTimeout(connection, try deadline.socketMillis());
}

fn executeRequestV2(request: *legacy.HttpRequest, tracker: ?*V2AsyncOp) V2Error!*legacy.HttpResponse {
    const deadline = Deadline.request(request.timeout_ms);
    if (requestCancelled(tracker)) return error.Closed;
    const uri = std.Uri.parse(request.url) catch |err| return mapHttpError(err, deadline, tracker);
    var header_buffer: [16 * 1024]u8 = undefined;
    var http_request = request.client.client.open(request.method, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{},
        .extra_headers = request.headers.items,
    }) catch |err| return mapHttpError(err, deadline, tracker);
    defer http_request.deinit();

    const connection = http_request.connection orelse return error.Closed;
    try configureRequestConnection(connection, deadline, tracker);
    defer if (tracker) |op| op.detach(connection.stream.handle);

    http_request.transfer_encoding = if (request.body) |body| .{ .content_length = body.len } else .none;
    checkRequestState(deadline, tracker) catch |err| return err;
    setConnectionTimeout(connection, try deadline.socketMillis()) catch |err| return err;
    http_request.send() catch |err| return mapHttpError(err, deadline, tracker);
    if (request.body) |body| {
        checkRequestState(deadline, tracker) catch |err| return err;
        setConnectionTimeout(connection, try deadline.socketMillis()) catch |err| return err;
        http_request.writeAll(body) catch |err| return mapHttpError(err, deadline, tracker);
    }
    checkRequestState(deadline, tracker) catch |err| return err;
    setConnectionTimeout(connection, try deadline.socketMillis()) catch |err| return err;
    http_request.finish() catch |err| return mapHttpError(err, deadline, tracker);
    http_request.wait() catch |err| return mapHttpError(err, deadline, tracker);

    const headers = cloneResponseHeaders(request.allocator, http_request.response) catch return error.Io;
    errdefer freeResponseHeaders(request.allocator, headers);

    var body = std.ArrayList(u8).init(request.allocator);
    errdefer body.deinit();
    var response_reader = http_request.reader();
    var read_buffer: [8192]u8 = undefined;
    while (true) {
        checkRequestState(deadline, tracker) catch |err| return err;
        setConnectionTimeout(connection, try deadline.socketMillis()) catch |err| return err;
        const read_len = response_reader.read(&read_buffer) catch |err| return mapHttpError(err, deadline, tracker);
        if (read_len == 0) break;
        const next_len = std.math.add(u64, @intCast(body.items.len), @intCast(read_len)) catch return error.TooLarge;
        if (next_len > request.max_response_bytes) return error.TooLarge;
        body.appendSlice(read_buffer[0..read_len]) catch return error.Io;
    }

    const response = request.allocator.create(legacy.HttpResponse) catch return error.Io;
    errdefer request.allocator.destroy(response);
    response.* = .{
        .allocator = request.allocator,
        .status = @intCast(@intFromEnum(http_request.response.status)),
        .headers = headers,
        .body = body.toOwnedSlice() catch return error.Io,
    };
    return response;
}

pub export fn sa_http_client_req_send_v2(req: ?*anyopaque, out_resp: ?*?*anyopaque) u32 {
    const slot = out_resp orelse return statusCode(.invalid);
    slot.* = null;
    const req_ptr = req orelse return statusCode(.invalid);
    const request: *legacy.HttpRequest = @ptrCast(@alignCast(req_ptr));
    const response = executeRequestV2(request, null) catch |err| return statusCode(statusFromV2Error(err));
    slot.* = @ptrCast(response);
    return statusCode(.ok);
}

fn cloneRequestV2(source: *legacy.HttpRequest) !*legacy.HttpRequest {
    const allocator = source.allocator;
    const request = try allocator.create(legacy.HttpRequest);
    errdefer allocator.destroy(request);
    source.client.retain();
    errdefer source.client.release();
    request.* = .{
        .allocator = allocator,
        .client = source.client,
        .method = source.method,
        .url = try allocator.dupe(u8, source.url),
        .headers = std.ArrayList(std.http.Header).init(allocator),
        .timeout_ms = source.timeout_ms,
        .max_response_bytes = source.max_response_bytes,
        .retains_client = true,
    };
    errdefer allocator.free(request.url);
    errdefer request.headers.deinit();
    for (source.headers.items) |header| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        try request.headers.append(.{ .name = name, .value = value });
    }
    request.body = if (source.body) |body| try allocator.dupe(u8, body) else null;
    return request;
}

const V2AsyncOp = struct {
    allocator: std.mem.Allocator,
    request: *legacy.HttpRequest,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    done: bool = false,
    cancel_requested: bool = false,
    active_fd: ?std.posix.socket_t = null,
    result_status: NetworkStatus = .would_block,
    response: ?*legacy.HttpResponse = null,

    fn init(source: *legacy.HttpRequest) !*V2AsyncOp {
        const request = try cloneRequestV2(source);
        errdefer request.deinit();
        const self = try request.allocator.create(V2AsyncOp);
        errdefer request.allocator.destroy(self);
        self.* = .{ .allocator = request.allocator, .request = request };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *V2AsyncOp) void {
        const response = executeRequestV2(self.request, self) catch |err| {
            self.complete(statusFromV2Error(err), null);
            return;
        };
        self.complete(.ok, response);
    }

    fn complete(self: *V2AsyncOp, result_status: NetworkStatus, response: ?*legacy.HttpResponse) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancel_requested) {
            if (response) |value| value.deinit();
            self.response = null;
            self.result_status = .closed;
        } else {
            self.response = response;
            self.result_status = result_status;
        }
        self.active_fd = null;
        self.done = true;
        self.condition.broadcast();
    }

    fn attach(self: *V2AsyncOp, fd: std.posix.socket_t) V2Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancel_requested) return error.Closed;
        self.active_fd = fd;
    }

    fn detach(self: *V2AsyncOp, fd: std.posix.socket_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_fd != null and self.active_fd.? == fd) self.active_fd = null;
    }

    fn cancelled(self: *V2AsyncOp) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancel_requested;
    }

    fn cancel(self: *V2AsyncOp) void {
        self.mutex.lock();
        if (self.done or self.cancel_requested) {
            self.mutex.unlock();
            return;
        }
        self.cancel_requested = true;
        if (self.active_fd) |fd| std.posix.shutdown(fd, .both) catch {};
        self.mutex.unlock();
    }

    fn poll(self: *V2AsyncOp, timeout_ms: u32, out_ready: *u8) NetworkStatus {
        out_ready.* = 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.done) {
            out_ready.* = 1;
            return self.result_status;
        }
        if (timeout_ms == 0) return .would_block;

        const started = std.time.Instant.now() catch return .io_error;
        const timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (!self.done) {
            const now = std.time.Instant.now() catch return .io_error;
            const elapsed = now.since(started);
            if (elapsed >= timeout_ns) return .timeout;
            self.condition.timedWait(&self.mutex, timeout_ns - elapsed) catch |err| switch (err) {
                error.Timeout => return .timeout,
            };
        }
        out_ready.* = 1;
        return self.result_status;
    }

    fn takeResponse(self: *V2AsyncOp, out_resp: *?*anyopaque) NetworkStatus {
        out_resp.* = null;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.done) return .would_block;
        if (self.result_status != .ok) return self.result_status;
        const response = self.response orelse return .closed;
        self.response = null;
        out_resp.* = @ptrCast(response);
        return .ok;
    }

    fn deinit(self: *V2AsyncOp) void {
        self.cancel();
        if (self.thread) |thread| thread.join();
        if (self.response) |response| response.deinit();
        self.request.deinit();
        self.allocator.destroy(self);
    }
};

pub export fn sa_http_client_req_send_async_v2(req: ?*anyopaque, out_op: ?*?*anyopaque) u32 {
    const slot = out_op orelse return statusCode(.invalid);
    slot.* = null;
    const req_ptr = req orelse return statusCode(.invalid);
    const request: *legacy.HttpRequest = @ptrCast(@alignCast(req_ptr));
    const operation = V2AsyncOp.init(request) catch return statusCode(.io_error);
    slot.* = @ptrCast(operation);
    return statusCode(.ok);
}

pub export fn sa_http_client_async_poll_v2(op: ?*anyopaque, timeout_ms: u32, out_ready: ?*u8) u32 {
    const ready = out_ready orelse return statusCode(.invalid);
    ready.* = 0;
    const op_ptr = op orelse return statusCode(.invalid);
    const operation: *V2AsyncOp = @ptrCast(@alignCast(op_ptr));
    return statusCode(operation.poll(timeout_ms, ready));
}

pub export fn sa_http_client_async_take_response_v2(op: ?*anyopaque, out_resp: ?*?*anyopaque) u32 {
    const slot = out_resp orelse return statusCode(.invalid);
    slot.* = null;
    const op_ptr = op orelse return statusCode(.invalid);
    const operation: *V2AsyncOp = @ptrCast(@alignCast(op_ptr));
    return statusCode(operation.takeResponse(slot));
}

pub export fn sa_http_client_async_cancel_v2(op: ?*anyopaque) u32 {
    const op_ptr = op orelse return statusCode(.invalid);
    const operation: *V2AsyncOp = @ptrCast(@alignCast(op_ptr));
    operation.cancel();
    return statusCode(.ok);
}

pub export fn sa_http_client_async_free_v2(op: ?*anyopaque) u32 {
    const op_ptr = op orelse return statusCode(.invalid);
    const operation: *V2AsyncOp = @ptrCast(@alignCast(op_ptr));
    operation.deinit();
    return statusCode(.ok);
}

const WebSocketOpcode = enum(u8) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

const WebSocketV2 = struct {
    allocator: std.mem.Allocator,
    client: *legacy.HttpClient,
    connection: *std.http.Client.Connection,
    receive_buffer: std.ArrayList(u8),
    receive_start: usize = 0,
    fragment_buffer: std.ArrayList(u8),
    fragment_opcode: ?u8 = null,
    last_message: ?[]u8 = null,
    pending_pong: ?[]u8 = null,
    close_sent: bool = false,
    closed: bool = false,
    io_mutex: std.Thread.Mutex = .{},

    fn init(client: *legacy.HttpClient, connection: *std.http.Client.Connection) !*WebSocketV2 {
        const self = try client.allocator.create(WebSocketV2);
        client.retain();
        self.* = .{
            .allocator = client.allocator,
            .client = client,
            .connection = connection,
            .receive_buffer = std.ArrayList(u8).init(client.allocator),
            .fragment_buffer = std.ArrayList(u8).init(client.allocator),
        };
        connection.closing = true;
        return self;
    }

    fn markClosed(self: *WebSocketV2) void {
        if (self.closed) return;
        self.closed = true;
        std.posix.shutdown(self.connection.stream.handle, .both) catch {};
    }

    fn clearLastMessage(self: *WebSocketV2) void {
        if (self.last_message) |message| self.allocator.free(message);
        self.last_message = null;
    }

    fn deinit(self: *WebSocketV2) void {
        self.io_mutex.lock();
        self.markClosed();
        self.clearLastMessage();
        if (self.pending_pong) |payload| self.allocator.free(payload);
        self.pending_pong = null;
        self.receive_buffer.deinit();
        self.fragment_buffer.deinit();
        self.connection.closing = true;
        self.client.client.connection_pool.release(self.client.allocator, self.connection);
        self.io_mutex.unlock();
        const client = self.client;
        self.allocator.destroy(self);
        client.release();
    }
};

fn timeoutMillis(timeout_ms: u32) i32 {
    return @intCast(@min(timeout_ms, @as(u32, @intCast(std.math.maxInt(i32)))));
}

fn websocketPoll(handle: *WebSocketV2, interests: u32, timeout_ms: u32, out_events: *u32) NetworkStatus {
    out_events.* = 0;
    if (interests == 0 or interests & ~(PollEvent.readable | PollEvent.writable) != 0) return .invalid;
    if (handle.closed) {
        out_events.* = PollEvent.closed;
        return .closed;
    }

    if (interests & PollEvent.readable != 0 and
        (handle.receive_start < handle.receive_buffer.items.len or handle.connection.peek().len != 0))
    {
        out_events.* |= PollEvent.readable;
    }
    if (out_events.* != 0 and interests & PollEvent.writable == 0) return .ok;

    var native_events: i16 = 0;
    if (interests & PollEvent.readable != 0 and out_events.* & PollEvent.readable == 0) native_events |= std.posix.POLL.IN;
    if (interests & PollEvent.writable != 0) native_events |= std.posix.POLL.OUT;
    if (native_events == 0) return .ok;

    var poll_fds = [1]std.posix.pollfd{.{
        .fd = handle.connection.stream.handle,
        .events = native_events,
        .revents = 0,
    }};
    const ready = std.posix.poll(&poll_fds, timeoutMillis(timeout_ms)) catch return .io_error;
    if (ready == 0) return if (timeout_ms == 0) .would_block else .timeout;
    const returned = poll_fds[0].revents;
    if (returned & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return .io_error;
    if (returned & std.posix.POLL.IN != 0) out_events.* |= PollEvent.readable;
    if (returned & std.posix.POLL.OUT != 0) out_events.* |= PollEvent.writable;
    if (returned & std.posix.POLL.HUP != 0) out_events.* |= PollEvent.closed;
    if (out_events.* & (PollEvent.readable | PollEvent.writable) != 0) return .ok;
    if (out_events.* & PollEvent.closed != 0) return .closed;
    return .would_block;
}

fn normalizedWebSocketUrl(allocator: std.mem.Allocator, url: []const u8) V2Error![]u8 {
    if (std.mem.startsWith(u8, url, "ws://")) {
        return std.fmt.allocPrint(allocator, "http{s}", .{url[2..]}) catch return error.Io;
    }
    if (std.mem.startsWith(u8, url, "wss://")) {
        return std.fmt.allocPrint(allocator, "https{s}", .{url[3..]}) catch return error.Io;
    }
    return error.Invalid;
}

fn websocketHeader(response: *std.http.Client.Response, key: []const u8) ?[]const u8 {
    var iterator = response.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, key)) return header.value;
    }
    return null;
}

fn websocketHeaderContainsToken(value: []const u8, token: []const u8) bool {
    var iterator = std.mem.tokenizeAny(u8, value, " \t,");
    while (iterator.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, token)) return true;
    }
    return false;
}

fn reservedWebSocketHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "upgrade") or
        std.ascii.eqlIgnoreCase(name, "sec-websocket-key") or
        std.ascii.eqlIgnoreCase(name, "sec-websocket-version");
}

fn websocketConnect(
    client: *legacy.HttpClient,
    logical_url: []const u8,
    headers: []const std.http.Header,
    unix_socket_path: ?[]const u8,
    timeout_ms: u32,
) V2Error!*WebSocketV2 {
    if (logical_url.len == 0) return error.Invalid;
    if (unix_socket_path != null and !std.mem.startsWith(u8, logical_url, "ws://")) return error.Invalid;
    const normalized_url = try normalizedWebSocketUrl(client.allocator, logical_url);
    defer client.allocator.free(normalized_url);
    const uri = std.Uri.parse(normalized_url) catch return error.Invalid;
    if (uri.fragment != null) return error.Invalid;

    var key_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&key_bytes);
    var key_buffer: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buffer, &key_bytes);

    var request_headers = std.ArrayList(std.http.Header).init(client.allocator);
    defer request_headers.deinit();
    for (headers) |header| {
        if (reservedWebSocketHeader(header.name)) continue;
        if (!validHeaderName(header.name) or !validHeaderValue(header.value)) return error.Invalid;
        request_headers.append(header) catch return error.Io;
    }
    request_headers.append(.{ .name = "upgrade", .value = "websocket" }) catch return error.Io;
    request_headers.append(.{ .name = "sec-websocket-version", .value = "13" }) catch return error.Io;
    request_headers.append(.{ .name = "sec-websocket-key", .value = key }) catch return error.Io;

    var supplied_connection: ?*std.http.Client.Connection = null;
    if (unix_socket_path) |path| {
        if (path.len == 0) return error.Invalid;
        supplied_connection = client.client.connectUnix(path) catch |err| return switch (statusFromOperationError(err, false)) {
            .invalid => error.Invalid,
            .closed => error.Closed,
            else => error.Io,
        };
    }

    var header_buffer: [16 * 1024]u8 = undefined;
    var http_request = client.client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .connection = supplied_connection,
        .headers = .{
            .connection = .{ .override = "Upgrade" },
            .user_agent = .omit,
            .accept_encoding = .omit,
        },
        .extra_headers = request_headers.items,
        .keep_alive = true,
        .redirect_behavior = .unhandled,
    }) catch |err| {
        if (supplied_connection) |connection| {
            connection.closing = true;
            client.client.connection_pool.release(client.allocator, connection);
        }
        return switch (statusFromOperationError(err, timeout_ms != 0)) {
            .timeout => error.Timeout,
            .invalid => error.Invalid,
            .closed => error.Closed,
            else => error.Io,
        };
    };
    var request_active = true;
    defer if (request_active) http_request.deinit();

    const connection = http_request.connection orelse return error.Closed;
    const deadline = Deadline.request(timeout_ms);
    setConnectionTimeout(connection, try deadline.socketMillis()) catch |err| return err;
    http_request.transfer_encoding = .none;
    http_request.send() catch |err| return mapHttpError(err, deadline, null);
    setConnectionTimeout(connection, try deadline.socketMillis()) catch |err| return err;
    http_request.finish() catch |err| return mapHttpError(err, deadline, null);
    setConnectionTimeout(connection, try deadline.socketMillis()) catch |err| return err;
    http_request.wait() catch |err| return mapHttpError(err, deadline, null);

    if (http_request.response.status != .switching_protocols) return error.Invalid;
    const upgrade = websocketHeader(&http_request.response, "upgrade") orelse return error.Invalid;
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return error.Invalid;
    const connection_header = websocketHeader(&http_request.response, "connection") orelse return error.Invalid;
    if (!websocketHeaderContainsToken(connection_header, "upgrade")) return error.Invalid;
    const accept = websocketHeader(&http_request.response, "sec-websocket-accept") orelse return error.Invalid;
    var expected_buffer: [28]u8 = undefined;
    const expected = sa_std_net.websocketAccept(key, &expected_buffer) catch return error.Invalid;
    if (!std.mem.eql(u8, accept, expected)) return error.Invalid;

    const handle = WebSocketV2.init(client, connection) catch return error.Io;
    http_request.connection = null;
    request_active = false;
    http_request.deinit();
    return handle;
}

pub export fn sa_http_client_websocket_connect_v2(
    client: ?*anyopaque,
    url_ptr: ?[*]const u8,
    url_len: u64,
    timeout_ms: u32,
    out_ws: ?*?*anyopaque,
) u32 {
    const slot = out_ws orelse return statusCode(.invalid);
    slot.* = null;
    const client_ptr = client orelse return statusCode(.invalid);
    const url = requiredSlice(url_ptr, url_len) catch return statusCode(.invalid);
    const cli: *legacy.HttpClient = @ptrCast(@alignCast(client_ptr));
    const websocket = websocketConnect(cli, url, &.{}, null, timeout_ms) catch |err| return statusCode(statusFromV2Error(err));
    slot.* = @ptrCast(websocket);
    return statusCode(.ok);
}

pub export fn sa_http_client_websocket_connect_unix_v2(
    client: ?*anyopaque,
    socket_path_ptr: ?[*]const u8,
    socket_path_len: u64,
    url_ptr: ?[*]const u8,
    url_len: u64,
    timeout_ms: u32,
    out_ws: ?*?*anyopaque,
) u32 {
    const slot = out_ws orelse return statusCode(.invalid);
    slot.* = null;
    const client_ptr = client orelse return statusCode(.invalid);
    const socket_path = requiredSlice(socket_path_ptr, socket_path_len) catch return statusCode(.invalid);
    const url = requiredSlice(url_ptr, url_len) catch return statusCode(.invalid);
    const cli: *legacy.HttpClient = @ptrCast(@alignCast(client_ptr));
    const websocket = websocketConnect(cli, url, &.{}, socket_path, timeout_ms) catch |err| return statusCode(statusFromV2Error(err));
    slot.* = @ptrCast(websocket);
    return statusCode(.ok);
}

pub export fn sa_http_client_req_websocket_connect_v2(req: ?*anyopaque, timeout_ms: u32, out_ws: ?*?*anyopaque) u32 {
    const slot = out_ws orelse return statusCode(.invalid);
    slot.* = null;
    const req_ptr = req orelse return statusCode(.invalid);
    const request: *legacy.HttpRequest = @ptrCast(@alignCast(req_ptr));
    const effective_timeout = if (timeout_ms == 0) request.timeout_ms else timeout_ms;
    const websocket = websocketConnect(request.client, request.url, request.headers.items, null, effective_timeout) catch |err| return statusCode(statusFromV2Error(err));
    slot.* = @ptrCast(websocket);
    return statusCode(.ok);
}

pub export fn sa_http_client_req_websocket_connect_unix_v2(
    req: ?*anyopaque,
    socket_path_ptr: ?[*]const u8,
    socket_path_len: u64,
    timeout_ms: u32,
    out_ws: ?*?*anyopaque,
) u32 {
    const slot = out_ws orelse return statusCode(.invalid);
    slot.* = null;
    const req_ptr = req orelse return statusCode(.invalid);
    const socket_path = requiredSlice(socket_path_ptr, socket_path_len) catch return statusCode(.invalid);
    const request: *legacy.HttpRequest = @ptrCast(@alignCast(req_ptr));
    const effective_timeout = if (timeout_ms == 0) request.timeout_ms else timeout_ms;
    const websocket = websocketConnect(request.client, request.url, request.headers.items, socket_path, effective_timeout) catch |err| return statusCode(statusFromV2Error(err));
    slot.* = @ptrCast(websocket);
    return statusCode(.ok);
}

const FrameMeta = struct {
    fin: bool,
    opcode: u8,
    payload_offset: usize,
    payload_len: usize,
    frame_len: usize,
};

const FrameParse = union(enum) {
    need_more,
    too_large,
    invalid,
    frame: FrameMeta,
};

fn parseServerFrame(bytes: []const u8, max_payload: u64) FrameParse {
    if (bytes.len < 2) return .need_more;
    const first = bytes[0];
    const second = bytes[1];
    if (first & 0x70 != 0) return .invalid;
    if (second & 0x80 != 0) return .invalid;

    var payload_len: u64 = second & 0x7f;
    var payload_offset: usize = 2;
    if (payload_len == 126) {
        if (bytes.len < 4) return .need_more;
        payload_len = std.mem.readInt(u16, bytes[2..4], .big);
        if (payload_len < 126) return .invalid;
        payload_offset = 4;
    } else if (payload_len == 127) {
        if (bytes.len < 10) return .need_more;
        payload_len = std.mem.readInt(u64, bytes[2..10], .big);
        if (payload_len < 65536 or payload_len & (@as(u64, 1) << 63) != 0) return .invalid;
        payload_offset = 10;
    }
    if (payload_len > max_payload or payload_len > std.math.maxInt(usize)) return .too_large;
    const payload_len_usize: usize = @intCast(payload_len);
    const frame_len = std.math.add(usize, payload_offset, payload_len_usize) catch return .too_large;
    if (bytes.len < frame_len) return .need_more;
    const opcode = first & 0x0f;
    const fin = first & 0x80 != 0;
    if (opcode >= 8 and (!fin or payload_len > 125)) return .invalid;
    return .{ .frame = .{
        .fin = fin,
        .opcode = opcode,
        .payload_offset = payload_offset,
        .payload_len = payload_len_usize,
        .frame_len = frame_len,
    } };
}

fn compactReceiveBuffer(handle: *WebSocketV2) void {
    if (handle.receive_start == 0) return;
    if (handle.receive_start == handle.receive_buffer.items.len) {
        handle.receive_buffer.clearRetainingCapacity();
        handle.receive_start = 0;
        return;
    }
    if (handle.receive_start < 4096 and handle.receive_start * 2 < handle.receive_buffer.items.len) return;
    const remaining = handle.receive_buffer.items.len - handle.receive_start;
    std.mem.copyForwards(u8, handle.receive_buffer.items[0..remaining], handle.receive_buffer.items[handle.receive_start..]);
    handle.receive_buffer.items.len = remaining;
    handle.receive_start = 0;
}

fn consumeFrame(handle: *WebSocketV2, frame_len: usize) void {
    handle.receive_start += frame_len;
    compactReceiveBuffer(handle);
}

fn errorFromNetworkStatus(status: NetworkStatus) V2Error {
    return switch (status) {
        .would_block => error.WouldBlock,
        .closed => error.Closed,
        .timeout => error.Timeout,
        .too_large => error.TooLarge,
        .invalid => error.Invalid,
        .io_error => error.Io,
        .ok => unreachable,
    };
}

fn fillWebSocketInput(handle: *WebSocketV2) V2Error!void {
    var events: u32 = 0;
    const poll_status = websocketPoll(handle, PollEvent.readable, 0, &events);
    if (poll_status != .ok) return errorFromNetworkStatus(poll_status);
    if (events & PollEvent.readable == 0) return if (events & PollEvent.closed != 0) error.Closed else error.WouldBlock;
    try setConnectionTimeout(handle.connection, 1);
    var buffer: [16 * 1024]u8 = undefined;
    const read_len = handle.connection.read(&buffer) catch |err| return switch (statusFromOperationError(err, true)) {
        .timeout, .would_block => error.WouldBlock,
        .closed => error.Closed,
        else => error.Io,
    };
    if (read_len == 0) return error.Closed;
    handle.receive_buffer.appendSlice(buffer[0..read_len]) catch return error.Io;
}

fn websocketFrameBytes(handle: *WebSocketV2, opcode: u8, payload: []const u8) V2Error![]u8 {
    if (payload.len > max_v2_message_bytes) return error.TooLarge;
    const header_len: usize = if (payload.len < 126) 2 else if (payload.len <= std.math.maxInt(u16)) 4 else 10;
    const frame_capacity = std.math.add(usize, payload.len, header_len + 4) catch return error.TooLarge;
    const frame = handle.allocator.alloc(u8, frame_capacity) catch return error.Io;
    errdefer handle.allocator.free(frame);
    var mask_key: [4]u8 = undefined;
    std.crypto.random.bytes(&mask_key);
    const frame_len = sa_std_net.buildWebSocketFrame(frame, opcode, payload, &mask_key) catch return error.Invalid;
    std.debug.assert(frame_len == frame_capacity);
    return frame;
}

fn writeWebSocketFrame(handle: *WebSocketV2, opcode: u8, payload: []const u8) V2Error!void {
    if (handle.closed or handle.close_sent) return error.Closed;
    var events: u32 = 0;
    const poll_status = websocketPoll(handle, PollEvent.writable, 0, &events);
    if (poll_status != .ok) return errorFromNetworkStatus(poll_status);
    const frame = try websocketFrameBytes(handle, opcode, payload);
    defer handle.allocator.free(frame);
    try setConnectionTimeout(handle.connection, 1);
    handle.connection.writeAllDirect(frame) catch |err| {
        handle.markClosed();
        return switch (statusFromOperationError(err, true)) {
            .closed => error.Closed,
            else => error.Io,
        };
    };
}

fn flushPendingPong(handle: *WebSocketV2) V2Error!void {
    const payload = handle.pending_pong orelse return;
    try writeWebSocketFrame(handle, @intFromEnum(WebSocketOpcode.pong), payload);
    handle.allocator.free(payload);
    handle.pending_pong = null;
}

fn validCloseCode(code: u16) bool {
    if (code >= 3000 and code <= 4999) return true;
    return switch (code) {
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014 => true,
        else => false,
    };
}

fn validateClosePayload(payload: []const u8) bool {
    if (payload.len == 0) return true;
    if (payload.len == 1) return false;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    return validCloseCode(code) and std.unicode.utf8ValidateSlice(payload[2..]);
}

fn deliverMessage(handle: *WebSocketV2, opcode: u8, payload: []const u8, out_opcode: *u8, out_ptr: *?[*]const u8, out_len: *u64) V2Error!void {
    if (opcode == @intFromEnum(WebSocketOpcode.text) and !std.unicode.utf8ValidateSlice(payload)) return error.Invalid;
    const copy = if (payload.len == 0) null else handle.allocator.dupe(u8, payload) catch return error.Io;
    handle.clearLastMessage();
    handle.last_message = copy;
    out_opcode.* = opcode;
    out_ptr.* = if (copy) |message| message.ptr else null;
    out_len.* = payload.len;
}

fn readWebSocketMessage(
    handle: *WebSocketV2,
    max_len: u64,
    out_opcode: *u8,
    out_ptr: *?[*]const u8,
    out_len: *u64,
) V2Error!void {
    const message_limit = if (max_len == 0) max_v2_message_bytes else @min(max_len, max_v2_message_bytes);
    try flushPendingPong(handle);
    while (true) {
        const available = handle.receive_buffer.items[handle.receive_start..];
        switch (parseServerFrame(available, message_limit)) {
            .need_more => {
                fillWebSocketInput(handle) catch |err| {
                    if (err == error.Closed) handle.markClosed();
                    return err;
                };
                continue;
            },
            .too_large => {
                handle.markClosed();
                return error.TooLarge;
            },
            .invalid => {
                handle.markClosed();
                return error.Invalid;
            },
            .frame => |frame| {
                const payload = available[frame.payload_offset .. frame.payload_offset + frame.payload_len];
                switch (frame.opcode) {
                    @intFromEnum(WebSocketOpcode.ping) => {
                        if (handle.pending_pong) |old| handle.allocator.free(old);
                        handle.pending_pong = handle.allocator.dupe(u8, payload) catch return error.Io;
                        consumeFrame(handle, frame.frame_len);
                        try flushPendingPong(handle);
                    },
                    @intFromEnum(WebSocketOpcode.pong) => consumeFrame(handle, frame.frame_len),
                    @intFromEnum(WebSocketOpcode.close) => {
                        if (!validateClosePayload(payload)) {
                            handle.markClosed();
                            return error.Invalid;
                        }
                        if (!handle.close_sent) {
                            writeWebSocketFrame(handle, @intFromEnum(WebSocketOpcode.close), payload) catch {};
                            handle.close_sent = true;
                        }
                        consumeFrame(handle, frame.frame_len);
                        handle.markClosed();
                        return error.Closed;
                    },
                    @intFromEnum(WebSocketOpcode.text), @intFromEnum(WebSocketOpcode.binary) => {
                        if (handle.fragment_opcode != null) {
                            handle.markClosed();
                            return error.Invalid;
                        }
                        if (frame.fin) {
                            try deliverMessage(handle, frame.opcode, payload, out_opcode, out_ptr, out_len);
                            consumeFrame(handle, frame.frame_len);
                            return;
                        }
                        handle.fragment_opcode = frame.opcode;
                        handle.fragment_buffer.clearRetainingCapacity();
                        handle.fragment_buffer.appendSlice(payload) catch return error.Io;
                        consumeFrame(handle, frame.frame_len);
                    },
                    @intFromEnum(WebSocketOpcode.continuation) => {
                        const initial_opcode = handle.fragment_opcode orelse {
                            handle.markClosed();
                            return error.Invalid;
                        };
                        const next_len = std.math.add(usize, handle.fragment_buffer.items.len, payload.len) catch {
                            handle.markClosed();
                            return error.TooLarge;
                        };
                        if (next_len > message_limit) {
                            handle.markClosed();
                            return error.TooLarge;
                        }
                        handle.fragment_buffer.appendSlice(payload) catch return error.Io;
                        consumeFrame(handle, frame.frame_len);
                        if (frame.fin) {
                            try deliverMessage(handle, initial_opcode, handle.fragment_buffer.items, out_opcode, out_ptr, out_len);
                            handle.fragment_buffer.clearRetainingCapacity();
                            handle.fragment_opcode = null;
                            return;
                        }
                    },
                    else => {
                        handle.markClosed();
                        return error.Invalid;
                    },
                }
            },
        }
    }
}

pub export fn sa_http_websocket_poll_v2(ws: ?*anyopaque, interests: u32, timeout_ms: u32, out_events: ?*u32) u32 {
    const events = out_events orelse return statusCode(.invalid);
    events.* = 0;
    const ws_ptr = ws orelse return statusCode(.invalid);
    const handle: *WebSocketV2 = @ptrCast(@alignCast(ws_ptr));
    handle.io_mutex.lock();
    defer handle.io_mutex.unlock();
    return statusCode(websocketPoll(handle, interests, timeout_ms, events));
}

pub export fn sa_http_websocket_read_v2(
    ws: ?*anyopaque,
    max_len: u64,
    out_opcode: ?*u8,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const opcode_slot = out_opcode orelse return statusCode(.invalid);
    const ptr_slot = out_ptr orelse return statusCode(.invalid);
    const len_slot = out_len orelse return statusCode(.invalid);
    opcode_slot.* = 0;
    ptr_slot.* = null;
    len_slot.* = 0;
    const ws_ptr = ws orelse return statusCode(.invalid);
    const handle: *WebSocketV2 = @ptrCast(@alignCast(ws_ptr));
    handle.io_mutex.lock();
    defer handle.io_mutex.unlock();
    readWebSocketMessage(handle, max_len, opcode_slot, ptr_slot, len_slot) catch |err| return statusCode(statusFromV2Error(err));
    return statusCode(.ok);
}

pub export fn sa_http_websocket_write_v2(
    ws: ?*anyopaque,
    opcode: u8,
    data_ptr: ?[*]const u8,
    data_len: u64,
    out_written: ?*u64,
) u32 {
    const written = out_written orelse return statusCode(.invalid);
    written.* = 0;
    const ws_ptr = ws orelse return statusCode(.invalid);
    const payload = requiredSlice(data_ptr, data_len) catch return statusCode(.invalid);
    if (opcode != @intFromEnum(WebSocketOpcode.text) and opcode != @intFromEnum(WebSocketOpcode.binary) and
        opcode != @intFromEnum(WebSocketOpcode.ping) and opcode != @intFromEnum(WebSocketOpcode.pong))
    {
        return statusCode(.invalid);
    }
    if ((opcode == @intFromEnum(WebSocketOpcode.ping) or opcode == @intFromEnum(WebSocketOpcode.pong)) and payload.len > 125) return statusCode(.too_large);
    if (opcode == @intFromEnum(WebSocketOpcode.text) and !std.unicode.utf8ValidateSlice(payload)) return statusCode(.invalid);
    const handle: *WebSocketV2 = @ptrCast(@alignCast(ws_ptr));
    handle.io_mutex.lock();
    defer handle.io_mutex.unlock();
    writeWebSocketFrame(handle, opcode, payload) catch |err| return statusCode(statusFromV2Error(err));
    written.* = payload.len;
    return statusCode(.ok);
}

pub export fn sa_http_websocket_close_v2(ws: ?*anyopaque, code: u16, reason_ptr: ?[*]const u8, reason_len: u64) u32 {
    const ws_ptr = ws orelse return statusCode(.invalid);
    const reason = requiredSlice(reason_ptr, reason_len) catch return statusCode(.invalid);
    if (!validCloseCode(code) or reason.len > 123) return statusCode(if (reason.len > 123) .too_large else .invalid);
    if (!std.unicode.utf8ValidateSlice(reason)) return statusCode(.invalid);
    const handle: *WebSocketV2 = @ptrCast(@alignCast(ws_ptr));
    handle.io_mutex.lock();
    defer handle.io_mutex.unlock();
    if (handle.closed or handle.close_sent) return statusCode(.closed);
    var payload: [125]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], code, .big);
    @memcpy(payload[2 .. 2 + reason.len], reason);
    writeWebSocketFrame(handle, @intFromEnum(WebSocketOpcode.close), payload[0 .. 2 + reason.len]) catch |err| return statusCode(statusFromV2Error(err));
    handle.close_sent = true;
    return statusCode(.ok);
}

pub export fn sa_http_websocket_free_v2(ws: ?*anyopaque) u32 {
    const ws_ptr = ws orelse return statusCode(.invalid);
    const handle: *WebSocketV2 = @ptrCast(@alignCast(ws_ptr));
    handle.deinit();
    return statusCode(.ok);
}
