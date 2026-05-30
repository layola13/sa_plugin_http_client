const std = @import("std");
const plugin_api = @import("plugin_api");
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

    fn init(allocator: std.mem.Allocator, cfg: HttpClientConfig) !*HttpClient {
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

    fn deinit(self: *HttpClient) void {
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

    fn init(client: *HttpClient, cfg: HttpRequestConfig) !*HttpRequest {
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
        try self.headers.appendSlice(cfg.headers);
        self.body = if (cfg.body) |body| try client.allocator.dupe(u8, body) else null;
        errdefer if (self.body) |body| client.allocator.free(body);
        return self;
    }

    fn deinit(self: *HttpRequest) void {
        if (self.body) |body| self.allocator.free(body);
        self.allocator.free(self.url);
        self.headers.deinit();
        self.client.allocator.destroy(self);
    }
};

pub const HttpResponse = struct {
    allocator: std.mem.Allocator,
    status: u16,
    headers: []std.http.Header,
    body: []u8,

    fn deinit(self: *HttpResponse) void {
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
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = request.read(&buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try body.appendSlice(buf[0..n]);
    }
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

pub export fn sa_http_client_req_add_header(req: ?*anyopaque, key_ptr: ?[*]const u8, key_len: u64, val_ptr: ?[*]const u8, val_len: u64) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const key = key_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const val = val_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const name = request.allocator.dupe(u8, key[0..@intCast(key_len)]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    errdefer request.allocator.free(name);
    const value = request.allocator.dupe(u8, val[0..@intCast(val_len)]) catch {
        request.allocator.free(name);
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
    errdefer request.allocator.free(value);
    request.headers.append(.{ .name = name, .value = value }) catch {
        request.allocator.free(name);
        request.allocator.free(value);
        return @intFromEnum(plugin_api.AbiStatus.failed);
    };
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
    cli.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_client_req_free(req: ?*anyopaque) u32 {
    const value = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(value)));
    request.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}
