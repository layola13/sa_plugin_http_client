const std = @import("std");
const plugin_api = @import("plugin_api");
const sa_std_net = @import("sa_std_net.zig");
pub const SaHttpClientHandle = extern struct {
    impl: ?*anyopaque,
};

pub const SaHttpRequestHandle = extern struct {
    impl: ?*anyopaque,
};

pub const SaHttpResponseHandle = extern struct {
    impl: ?*anyopaque,
};

pub const SaHttpBodyReaderHandle = extern struct {
    impl: ?*anyopaque,
};

pub const HttpMethod = enum(u8) {
    get = 1,
    post = 2,
    put = 3,
    delete = 4,
};

pub const HttpClientConfig = struct {
    use_tls: u8,
    ca_bundle_path: ?[]const u8 = null,
};

pub const HttpRequestConfig = struct {
    method: HttpMethod,
    url: []const u8,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    lifetime_mutex: std.Thread.Mutex = .{},
    reference_count: usize = 1,

    pub fn init(allocator: std.mem.Allocator, cfg: HttpClientConfig) !*HttpClient {
        const self = try allocator.create(HttpClient);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
        };
        try self.configureHttpsTrust(cfg);
        return self;
    }

    fn configureHttpsTrust(self: *HttpClient, cfg: HttpClientConfig) !void {
        if (std.http.Client.disable_tls or cfg.use_tls == 0) return;
        if (cfg.ca_bundle_path) |bundle_path| {
            const abs_path = try std.fs.cwd().realpathAlloc(self.allocator, bundle_path);
            defer self.allocator.free(abs_path);
            try self.client.ca_bundle.addCertsFromFilePathAbsolute(self.allocator, abs_path);
            self.client.next_https_rescan_certs = false;
        }
    }

    pub fn retain(self: *HttpClient) void {
        self.lifetime_mutex.lock();
        defer self.lifetime_mutex.unlock();
        std.debug.assert(self.reference_count > 0);
        self.reference_count += 1;
    }

    pub fn release(self: *HttpClient) void {
        self.lifetime_mutex.lock();
        std.debug.assert(self.reference_count > 0);
        self.reference_count -= 1;
        const destroy = self.reference_count == 0;
        self.lifetime_mutex.unlock();
        if (!destroy) return;
        self.client.deinit();
        self.allocator.destroy(self);
    }
};

pub const HttpRequest = struct {
    allocator: std.mem.Allocator,
    client: *HttpClient,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8 = null,
    headers: std.ArrayList(std.http.Header),
    timeout_ms: u32 = 0,
    max_response_bytes: u64 = 16 * 1024 * 1024,
    retains_client: bool = false,

    pub fn init(client: *HttpClient, cfg: HttpRequestConfig) !*HttpRequest {
        const self = try client.allocator.create(HttpRequest);
        errdefer client.allocator.destroy(self);
        self.* = .{
            .allocator = client.allocator,
            .client = client,
            .method = switch (cfg.method) {
                .get => .GET,
                .post => .POST,
                .put => .PUT,
                .delete => .DELETE,
            },
            .url = try client.allocator.dupe(u8, cfg.url),
            .headers = std.ArrayList(std.http.Header).init(client.allocator),
        };
        errdefer client.allocator.free(self.url);
        errdefer self.headers.deinit();
        for (cfg.headers) |header| {
            const name = try client.allocator.dupe(u8, header.name);
            errdefer client.allocator.free(name);
            const value = try client.allocator.dupe(u8, header.value);
            errdefer client.allocator.free(value);
            try self.headers.append(.{ .name = name, .value = value });
        }
        self.body = if (cfg.body) |body| try client.allocator.dupe(u8, body) else null;
        errdefer if (self.body) |body| client.allocator.free(body);
        return self;
    }

    pub fn deinit(self: *HttpRequest) void {
        const client = self.client;
        const retains_client = self.retains_client;
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        if (self.body) |body| self.allocator.free(body);
        self.allocator.free(self.url);
        self.headers.deinit();
        client.allocator.destroy(self);
        if (retains_client) client.release();
    }
};

fn requestUrlOriginLen(target: []const u8) usize {
    var authority_start: usize = 0;
    var scan: usize = 0;
    while (scan + 2 < target.len) : (scan += 1) {
        if (target[scan] == ':' and target[scan + 1] == '/' and target[scan + 2] == '/') {
            authority_start = scan + 3;
            break;
        }
    }
    var i = authority_start;
    while (i < target.len) : (i += 1) {
        switch (target[i]) {
            '/', '?', '#' => return i,
            else => {},
        }
    }
    return target.len;
}

fn targetBasePath(target: []const u8) []const u8 {
    const start = requestUrlOriginLen(target);
    if (start >= target.len or target[start] != '/') return "";
    var end = start;
    while (end < target.len and target[end] != '?' and target[end] != '#') : (end += 1) {}
    while (end > start and target[end - 1] == '/') end -= 1;
    if (end <= start) return "";
    return target[start..end];
}

fn requestPathWithoutLeadingSlashes(request_path: []const u8) []const u8 {
    var start: usize = 0;
    while (start < request_path.len and request_path[start] == '/') : (start += 1) {}
    return request_path[start..];
}

fn buildUpstreamUrl(allocator: std.mem.Allocator, target: []const u8, request_path: []const u8, preserve_base_path: bool) ![]u8 {
    const origin = target[0..requestUrlOriginLen(target)];
    if (!preserve_base_path) {
        if (request_path.len > 0 and request_path[0] == '/') {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, request_path });
        }
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ origin, request_path });
    }

    const base_path = targetBasePath(target);
    var relative_path = requestPathWithoutLeadingSlashes(request_path);
    if (std.mem.endsWith(u8, base_path, "/v1") and std.mem.startsWith(u8, relative_path, "v1/")) {
        relative_path = relative_path["v1/".len..];
    }
    if (relative_path.len == 0) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, base_path });
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ origin, base_path, relative_path });
}

fn addRequestHeader(request: *HttpRequest, key: []const u8, val: []const u8) !void {
    const name = try request.allocator.dupe(u8, key);
    errdefer request.allocator.free(name);
    const value = try request.allocator.dupe(u8, val);
    errdefer request.allocator.free(value);
    try request.headers.append(.{ .name = name, .value = value });
}

fn cloneRequestForAsync(src: *HttpRequest) !*HttpRequest {
    const allocator = src.allocator;
    const cloned = try allocator.create(HttpRequest);
    errdefer allocator.destroy(cloned);
    cloned.* = .{
        .allocator = allocator,
        .client = src.client,
        .method = src.method,
        .url = try allocator.dupe(u8, src.url),
        .headers = std.ArrayList(std.http.Header).init(allocator),
        .timeout_ms = src.timeout_ms,
        .max_response_bytes = src.max_response_bytes,
        .retains_client = true,
    };
    cloned.client.retain();
    errdefer cloned.client.release();
    errdefer allocator.free(cloned.url);
    errdefer cloned.headers.deinit();

    for (src.headers.items) |header| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        try cloned.headers.append(.{ .name = name, .value = value });
    }
    cloned.body = if (src.body) |body| try allocator.dupe(u8, body) else null;
    return cloned;
}

pub const HttpResponse = struct {
    allocator: std.mem.Allocator,
    status: u16,
    headers: []std.http.Header,
    body: []u8,

    pub fn deinit(self: *HttpResponse) void {
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
        if (self.body.len != 0) self.allocator.free(self.body);
        self.headers = &.{};
        self.body = &.{};
        self.status = 0;
        self.allocator.destroy(self);
    }
};

pub const HttpBodyReader = struct {
    allocator: std.mem.Allocator,
    body: []u8,
    cursor: usize = 0,

    fn init(allocator: std.mem.Allocator, body: []u8) !*HttpBodyReader {
        const self = try allocator.create(HttpBodyReader);
        self.* = .{
            .allocator = allocator,
            .body = body,
            .cursor = 0,
        };
        return self;
    }

    fn deinit(self: *HttpBodyReader) void {
        self.allocator.destroy(self);
    }
};

pub const HttpRequestAsyncOp = struct {
    allocator: std.mem.Allocator,
    request: *HttpRequest,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    done: bool = false,
    response: ?*HttpResponse = null,

    fn init(request: *HttpRequest) !*HttpRequestAsyncOp {
        const cloned_request = try cloneRequestForAsync(request);
        errdefer cloned_request.deinit();
        const self = try cloned_request.allocator.create(HttpRequestAsyncOp);
        errdefer cloned_request.allocator.destroy(self);
        self.* = .{
            .allocator = cloned_request.allocator,
            .request = cloned_request,
        };
        self.thread = try std.Thread.spawn(.{}, HttpRequestAsyncOp.run, .{self});
        return self;
    }

    fn run(self: *HttpRequestAsyncOp) void {
        const response = httpRequestExec(self.request) catch null;
        self.mutex.lock();
        self.response = response;
        self.done = true;
        self.mutex.unlock();
    }

    fn poll(self: *HttpRequestAsyncOp) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done;
    }

    fn takeResponse(self: *HttpRequestAsyncOp) ?*HttpResponse {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.done) return null;
        const response = self.response orelse return null;
        self.response = null;
        return response;
    }

    fn deinit(self: *HttpRequestAsyncOp) void {
        if (self.thread) |thread| thread.join();
        if (self.response) |response| response.deinit();
        self.request.deinit();
        self.allocator.destroy(self);
    }
};

fn mapStatus(status: std.http.Status) u16 {
    return @intCast(@intFromEnum(status));
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

    var it = response.iterateHeaders();
    while (it.next()) |header| {
        try headers.append(.{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        });
    }
    return headers.toOwnedSlice();
}

fn makeStatusResponse(allocator: std.mem.Allocator, status: u16, headers: []std.http.Header, body: []u8) !*HttpResponse {
    const resp = try allocator.create(HttpResponse);
    errdefer allocator.destroy(resp);
    resp.* = .{
        .allocator = allocator,
        .status = status,
        .headers = headers,
        .body = body,
    };
    return resp;
}

fn httpRequestExec(req: *HttpRequest) !*HttpResponse {
    const uri = try std.Uri.parse(req.url);
    var header_buf: [16 * 1024]u8 = undefined;
    var request = try req.client.client.open(req.method, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .headers = .{},
        .extra_headers = req.headers.items,
    });
    defer request.deinit();

    request.transfer_encoding = if (req.body) |body| .{ .content_length = body.len } else .none;
    try request.send();
    if (req.body) |body| try request.writeAll(body);
    try request.finish();
    try request.wait();

    var body = std.ArrayList(u8).init(req.allocator);
    errdefer body.deinit();
    try request.reader().readAllArrayList(&body, 16 * 1024 * 1024);
    const headers = try cloneResponseHeaders(req.allocator, request.response);
    errdefer {
        for (headers) |header| {
            req.allocator.free(header.name);
            req.allocator.free(header.value);
        }
        req.allocator.free(headers);
    }
    return try makeStatusResponse(req.allocator, mapStatus(request.response.status), headers, try body.toOwnedSlice());
}

fn readAllIntoList(reader: anytype, allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    return out;
}

pub export fn sa_http_client_new(use_tls: u8, out_client: ?*?*anyopaque) u32 {
    const slot = out_client orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const client = HttpClient.init(std.heap.page_allocator, .{ .use_tls = use_tls }) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(client);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_new(client: ?*anyopaque, method: u8, url_ptr: ?[*]const u8, url_len: u64, out_req: ?*?*anyopaque) u32 {
    const client_ptr = client orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const url = url_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const cli = @as(*HttpClient, @ptrCast(@alignCast(client_ptr)));
    const request = HttpRequest.init(cli, .{
        .method = @enumFromInt(method),
        .url = url[0..@intCast(url_len)],
    }) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(request);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_new_joined(
    client: ?*anyopaque,
    method: u8,
    target_ptr: ?[*]const u8,
    target_len: u64,
    path_ptr: ?[*]const u8,
    path_len: u64,
    preserve_base_path: u8,
    out_req: ?*?*anyopaque,
) u32 {
    const client_ptr = client orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const target = target_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const path = path_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const cli = @as(*HttpClient, @ptrCast(@alignCast(client_ptr)));
    const url = buildUpstreamUrl(
        cli.allocator,
        target[0..@intCast(target_len)],
        path[0..@intCast(path_len)],
        preserve_base_path != 0,
    ) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer cli.allocator.free(url);
    const request = HttpRequest.init(cli, .{
        .method = @enumFromInt(method),
        .url = url,
    }) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(request);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_add_header(req: ?*anyopaque, key_ptr: ?[*]const u8, key_len: u64, val_ptr: ?[*]const u8, val_len: u64) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const key = key_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const val = val_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    addRequestHeader(request, key[0..@intCast(key_len)], val[0..@intCast(val_len)]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_add_openai_auth(req: ?*anyopaque, key_ptr: ?[*]const u8, key_len: u64) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const key = key_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const api_key = key[0..@intCast(key_len)];
    if (api_key.len == 0) return @intFromEnum(plugin_api.AbiStatus.ok);
    const bearer = std.fmt.allocPrint(request.allocator, "Bearer {s}", .{api_key}) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer request.allocator.free(bearer);
    addRequestHeader(request, "authorization", bearer) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    addRequestHeader(request, "x-api-key", api_key) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_set_body(req: ?*anyopaque, body_ptr: ?[*]const u8, body_len: u64) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const body = body_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    if (request.body) |old| request.allocator.free(old);
    request.body = request.allocator.dupe(u8, body[0..@intCast(body_len)]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_send(req: ?*anyopaque, out_resp: ?*?*anyopaque) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const response = httpRequestExec(request) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(response);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_send_async(req: ?*anyopaque, out_op: ?*?*anyopaque) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_op orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const op = HttpRequestAsyncOp.init(request) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(op);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_async_poll(op: ?*anyopaque, out_ready: ?*u8) u32 {
    const op_ptr = op orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const ready_slot = out_ready orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const async_op = @as(*HttpRequestAsyncOp, @ptrCast(@alignCast(op_ptr)));
    ready_slot.* = if (async_op.poll()) 1 else 0;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_async_take_response(op: ?*anyopaque, out_resp: ?*?*anyopaque) u32 {
    const op_ptr = op orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const async_op = @as(*HttpRequestAsyncOp, @ptrCast(@alignCast(op_ptr)));
    const response = async_op.takeResponse() orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(response);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_async_free(op: ?*anyopaque) u32 {
    const value = op orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const async_op = @as(*HttpRequestAsyncOp, @ptrCast(@alignCast(value)));
    async_op.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_resp_status(resp: ?*anyopaque) u16 {
    const response = resp orelse return 0;
    return @as(*HttpResponse, @ptrCast(@alignCast(response))).status;
}

pub export fn sa_http_client_resp_get_header(resp: ?*anyopaque, key_ptr: ?[*]const u8, key_len: u64, out_val_ptr: ?*?[*]const u8, out_val_len: ?*u64) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const key = key_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const value_slot = out_val_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const len_slot = out_val_len orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    const wanted = key[0..@intCast(key_len)];
    for (response.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, wanted)) {
            value_slot.* = header.value.ptr;
            len_slot.* = header.value.len;
            return @intFromEnum(plugin_api.AbiStatus.ok);
        }
    }
    return @intFromEnum(plugin_api.AbiStatus.failed);
}

pub export fn sa_http_client_resp_body_slice(resp: ?*anyopaque, out_body_ptr: ?*?[*]const u8, out_body_len: ?*u64) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const ptr_slot = out_body_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const len_slot = out_body_len orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    ptr_slot.* = response.body.ptr;
    len_slot.* = response.body.len;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_resp_body_ptr(resp: ?*anyopaque) ?[*]const u8 {
    const response = resp orelse return null;
    const value = @as(*HttpResponse, @ptrCast(@alignCast(response)));
    if (value.body.len == 0) return null;
    return value.body.ptr;
}

pub export fn sa_http_client_resp_body_len(resp: ?*anyopaque) u64 {
    const response = resp orelse return 0;
    return @as(*HttpResponse, @ptrCast(@alignCast(response))).body.len;
}

pub export fn sa_http_client_resp_body_reader(resp: ?*anyopaque, out_reader: ?*?*anyopaque) u32 {
    const response = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_reader orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const resp_ptr = @as(*HttpResponse, @ptrCast(@alignCast(response)));
    const reader = HttpBodyReader.init(resp_ptr.allocator, resp_ptr.body) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(reader);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

fn bodyReaderReadChunk(reader: *HttpBodyReader, buf: []u8) usize {
    if (reader.cursor >= reader.body.len) return 0;
    const n = @min(buf.len, reader.body.len - reader.cursor);
    @memcpy(buf[0..n], reader.body[reader.cursor .. reader.cursor + n]);
    reader.cursor += n;
    return n;
}

pub export fn sa_http_client_resp_read_chunk(reader: ?*anyopaque, buf_ptr: ?[*]u8, cap: u64, out_len: ?*u64) u32 {
    const reader_ptr = reader orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const buf = buf_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_len orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const body_reader = @as(*HttpBodyReader, @ptrCast(@alignCast(reader_ptr)));
    const n = bodyReaderReadChunk(body_reader, buf[0..@intCast(cap)]);
    slot.* = n;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_resp_free(resp: ?*anyopaque) u32 {
    const response = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const resp_ptr = @as(*HttpResponse, @ptrCast(@alignCast(response)));
    resp_ptr.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_body_reader_free(reader: ?*anyopaque) u32 {
    const value = reader orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const body_reader = @as(*HttpBodyReader, @ptrCast(@alignCast(value)));
    body_reader.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_free(client: ?*anyopaque) u32 {
    const value = client orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const cli = @as(*HttpClient, @ptrCast(@alignCast(value)));
    cli.release();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_free(req: ?*anyopaque) u32 {
    const value = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(value)));
    request.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

const WebSocketOpcode = enum(u8) {
    continuation = 0,
    text = 1,
    binary = 2,
    connection_close = 8,
    ping = 9,
    pong = 10,
};

const WebSocketHandle = struct {
    allocator: std.mem.Allocator,
    stream: ?std.net.Stream = null,

    fn isClient(self: *WebSocketHandle) bool {
        _ = self;
        return true;
    }

    fn readExact(self: *WebSocketHandle, buffer: []u8) bool {
        const stream = self.stream orelse return false;
        var index: usize = 0;
        while (index < buffer.len) {
            const read_n = stream.read(buffer[index..]) catch return false;
            if (read_n == 0) return false;
            index += read_n;
        }
        return true;
    }

    fn writeExact(self: *WebSocketHandle, bytes: []const u8) bool {
        const stream = self.stream orelse return false;
        stream.writeAll(bytes) catch return false;
        return true;
    }

    fn deinit(self: *WebSocketHandle) void {
        if (self.stream) |stream| {
            stream.close();
        }
        self.allocator.destroy(self);
    }
};

fn websocketResponseHeader(response: *std.http.Client.Response, key: []const u8) ?[]const u8 {
    var it = response.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, key)) return header.value;
    }
    return null;
}

fn websocketHeaderContainsToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t,");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, token)) return true;
    }
    return false;
}

fn websocketWriteFrame(handle: *WebSocketHandle, opcode: u8, payload: []const u8) bool {
    const masked = handle.isClient();
    var mask_key: [4]u8 = undefined;
    const mask = if (masked) blk: {
        std.crypto.random.bytes(&mask_key);
        break :blk &mask_key;
    } else null;
    const frame_cap = std.math.add(usize, payload.len, 14) catch return false;
    const frame = handle.allocator.alloc(u8, frame_cap) catch return false;
    defer handle.allocator.free(frame);
    const frame_len = sa_std_net.buildWebSocketFrame(frame, opcode, payload, mask) catch return false;
    return handle.writeExact(frame[0..frame_len]);
}

fn websocketSendPingPong(handle: *WebSocketHandle, opcode: u8, payload: []const u8) bool {
    return websocketWriteFrame(handle, opcode, payload);
}

fn fail() u32 {
    return @intFromEnum(plugin_api.AbiStatus.failed);
}
fn websocketReadFrame(handle: *WebSocketHandle, max_len: u64, out_opcode: ?*u8, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const opcode_slot = out_opcode orelse return fail();
    const ptr_slot = out_ptr orelse return fail();
    const len_slot = out_len orelse return fail();

    while (true) {
        const stream = handle.stream orelse return fail();
        const frame = sa_std_net.readWebSocketFrameAlloc(handle.allocator, stream, max_len, !handle.isClient()) catch return fail();
        const opcode = frame.opcode;
        const payload = frame.payload;

        switch (opcode) {
            @intFromEnum(WebSocketOpcode.ping) => {
                if (!websocketSendPingPong(handle, @intFromEnum(WebSocketOpcode.pong), payload)) {
                    if (payload.len > 0) handle.allocator.free(payload);
                    return fail();
                }
                if (payload.len > 0) handle.allocator.free(payload);
                continue;
            },
            @intFromEnum(WebSocketOpcode.pong) => {
                if (payload.len > 0) handle.allocator.free(payload);
                continue;
            },
            @intFromEnum(WebSocketOpcode.connection_close), @intFromEnum(WebSocketOpcode.text), @intFromEnum(WebSocketOpcode.binary) => {
                opcode_slot.* = opcode;
                if (payload.len == 0) {
                    ptr_slot.* = null;
                    len_slot.* = 0;
                } else {
                    ptr_slot.* = payload.ptr;
                    len_slot.* = payload.len;
                }
                return 0;
            },
            else => {
                if (payload.len > 0) handle.allocator.free(payload);
                return fail();
            },
        }
    }
}

pub export fn sa_http_websocket_read(ws: ?*anyopaque, max_len: u64, out_opcode: ?*u8, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const value = ws orelse return fail();
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(value)));
    return websocketReadFrame(handle, max_len, out_opcode, out_ptr, out_len);
}

pub export fn sa_http_websocket_write(ws: ?*anyopaque, opcode: u8, data_ptr: ?[*]const u8, data_len: u64) u32 {
    const value = ws orelse return fail();
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(value)));
    const payload = if (data_ptr) |ptr| ptr[0..@intCast(data_len)] else &[_]u8{};
    if (!websocketWriteFrame(handle, opcode, payload)) return fail();
    return 0;
}

pub export fn sa_http_websocket_free(ws: ?*anyopaque) u32 {
    const value = ws orelse return fail();
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(value)));
    handle.deinit();
    return 0;
}

pub export fn sa_http_client_websocket_connect(client: ?*anyopaque, url_ptr: ?[*]const u8, url_len: u64, out_ws: ?*?*anyopaque) u32 {
    const client_ptr = client orelse return fail();
    const url = url_ptr orelse return fail();
    const slot = out_ws orelse return fail();
    const cli = @as(*HttpClient, @ptrCast(@alignCast(client_ptr)));
    const url_slice = url[0..@intCast(url_len)];
    const uri = std.Uri.parse(url_slice) catch return fail();

    var request_headers: [3]std.http.Header = .{
        .{ .name = "upgrade", .value = "websocket" },
        .{ .name = "sec-websocket-version", .value = "13" },
        undefined,
    };

    var key_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&key_bytes);
    var key_b64: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);
    request_headers[2] = .{ .name = "sec-websocket-key", .value = key };

    var header_buf: [16 * 1024]u8 = undefined;
    var req = cli.client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
        .headers = .{
            .connection = .{ .override = "Upgrade" },
            .user_agent = .omit,
            .accept_encoding = .omit,
        },
        .extra_headers = &request_headers,
        .keep_alive = true,
    }) catch return fail();
    defer req.deinit();

    req.transfer_encoding = .none;
    req.send() catch return fail();
    req.finish() catch return fail();
    req.wait() catch return fail();

    if (req.response.status != .switching_protocols) {
        if (req.connection) |connection| connection.closing = true;
        return fail();
    }

    const upgrade = websocketResponseHeader(&req.response, "upgrade") orelse {
        if (req.connection) |connection| connection.closing = true;
        return fail();
    };
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
        if (req.connection) |connection| connection.closing = true;
        return fail();
    }

    const connection_value = websocketResponseHeader(&req.response, "connection") orelse {
        if (req.connection) |connection| connection.closing = true;
        return fail();
    };
    if (!websocketHeaderContainsToken(connection_value, "upgrade")) {
        if (req.connection) |connection| connection.closing = true;
        return fail();
    }

    const accept_value = websocketResponseHeader(&req.response, "sec-websocket-accept") orelse {
        if (req.connection) |connection| connection.closing = true;
        return fail();
    };
    var expected_accept_buf: [28]u8 = undefined;
    const expected_accept = sa_std_net.websocketAccept(key, &expected_accept_buf) catch {
        if (req.connection) |connection| connection.closing = true;
        return fail();
    };
    if (!std.mem.eql(u8, accept_value, expected_accept)) {
        if (req.connection) |connection| connection.closing = true;
        return fail();
    }

    const connection = req.connection orelse {
        return fail();
    };
    const duplicated_handle = std.posix.dup(connection.stream.handle) catch return fail();
    const duplicated_stream = std.net.Stream{ .handle = duplicated_handle };

    const handle = cli.allocator.create(WebSocketHandle) catch return fail();
    req.connection = null;
    req.deinit();

    handle.* = .{
        .allocator = cli.allocator,
        .stream = duplicated_stream,
    };
    slot.* = @ptrCast(handle);
    return 0;
}
