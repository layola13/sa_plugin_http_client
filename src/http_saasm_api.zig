const std = @import("std");
const plugin_api = @import("plugin_api.zig");
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
    // Serializes request execution so per-request proxy bypass (no_proxy)
    // can temporarily clear client.http_proxy/https_proxy safely.
    request_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, cfg: HttpClientConfig) !*HttpClient {
        const self = try allocator.create(HttpClient);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
        };
        // Route through https_proxy/http_proxy env vars when present (sandboxed
        // environments may block direct DNS/TCP; the proxy path is required).
        self.client.initDefaultProxies(allocator) catch {};
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

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

/// curl-compatible no_proxy matching: "*" matches all; ".example.com" or
/// "example.com" match the domain and subdomains; "host:port" restricts by port.
fn hostMatchesNoProxy(host: []const u8, port: u16, no_proxy: []const u8) bool {
    var h = host;
    if (h.len >= 2 and h[0] == '[' and h[h.len - 1] == ']') h = h[1 .. h.len - 1];
    var it = std.mem.splitScalar(u8, no_proxy, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return true;
        var e = entry;
        // Strip [brackets] from IPv6 entries, honor optional :port suffix.
        if (e.len >= 2 and e[0] == '[') {
            if (std.mem.indexOfScalar(u8, e, ']')) |end| {
                const rest = e[end + 1 ..];
                e = e[1..end];
                if (rest.len > 1 and rest[0] == ':') {
                    const p = std.fmt.parseInt(u16, rest[1..], 10) catch continue;
                    if (p != port) continue;
                } else if (rest.len != 0) {
                    continue;
                }
            } else continue;
        }
        var entry_host = e;
        if (std.mem.count(u8, e, ":") == 1) {
            const ci = std.mem.lastIndexOfScalar(u8, e, ':').?;
            entry_host = e[0..ci];
            const p = std.fmt.parseInt(u16, e[ci + 1 ..], 10) catch continue;
            if (p != port) continue;
        }
        if (entry_host.len > 0 and entry_host[0] == '.') {
            const suffix = entry_host[1..];
            if (std.ascii.eqlIgnoreCase(h, suffix)) return true;
            if (h.len > suffix.len and endsWithIgnoreCase(h, suffix) and h[h.len - suffix.len - 1] == '.') return true;
        } else {
            if (std.ascii.eqlIgnoreCase(h, entry_host)) return true;
            if (h.len > entry_host.len and endsWithIgnoreCase(h, entry_host) and h[h.len - entry_host.len - 1] == '.') return true;
        }
    }
    return false;
}

/// Zig 0.14.1's initDefaultProxies ignores no_proxy/NO_PROXY, so honor it here
/// by temporarily clearing the client proxies for matching hosts.
fn maybeBypassProxy(req: *HttpRequest, uri: std.Uri) void {
    const host_component = uri.host orelse return;
    const host: []const u8 = switch (host_component) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
    const no_proxy = std.process.getEnvVarOwned(req.allocator, "no_proxy") catch
        (std.process.getEnvVarOwned(req.allocator, "NO_PROXY") catch return);
    defer req.allocator.free(no_proxy);
    const port: u16 = uri.port orelse
        if (std.mem.eql(u8, uri.scheme, "https")) 443
        else if (std.mem.eql(u8, uri.scheme, "http")) 80
        else 0;
    if (hostMatchesNoProxy(host, port, no_proxy)) {
        req.client.client.http_proxy = null;
        req.client.client.https_proxy = null;
    } else {
    }
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

/// Manually establish an HTTPS connection through an HTTP proxy.
/// Replaces Zig 0.14.1's buggy connectTunnel() which builds the CONNECT
/// tunnel over plain TCP but never performs the TLS handshake, leaving the
/// Establishes a CONNECT tunnel through the HTTPS proxy and performs TLS
/// handshake. Returns the TLS client and the underlying stream.
/// The caller owns both and must close/destroy them.
fn establishProxyTlsTunnel(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    target_host: []const u8,
    target_port: u16,
) !struct { tls: *std.crypto.tls.Client, stream: std.net.Stream } {
    const proxy = client.https_proxy orelse return error.NoProxy;
    if (std.ascii.eqlIgnoreCase(proxy.host, target_host) and proxy.port == target_port) {
        return error.ProxyLoop;
    }

    const stream = std.net.tcpConnectToHost(allocator, proxy.host, proxy.port) catch |err| {
        return err;
    };
    errdefer stream.close();

    // Set socket receive timeout to avoid infinite hangs (30 seconds).
    {
        const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
    }

    // Send CONNECT request.
    var send_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&send_buf);
    const w = fbs.writer();
    try w.print("CONNECT {s}:{d} HTTP/1.1\r\n", .{ target_host, target_port });
    try w.print("Host: {s}:{d}\r\n", .{ target_host, target_port });
    if (proxy.authorization) |auth| {
        try w.writeAll("Proxy-Authorization: ");
        try w.writeAll(auth);
        try w.writeAll("\r\n");
    }
    try w.writeAll("\r\n");
    try stream.writeAll(fbs.getWritten());

    // Read CONNECT response.
    var resp_buf: [8192]u8 = undefined;
    var resp_len: usize = 0;
    while (resp_len < resp_buf.len) {
        const n = try stream.read(resp_buf[resp_len..]);
        if (n == 0) return error.ProxyClosedConnection;
        resp_len += n;
        if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |_| break;
    } else return error.ProxyResponseTooLarge;
    const status_end = std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n") orelse return error.ProxyBadResponse;
    const status_line = resp_buf[0..status_end];
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next();
    const code_str = parts.next() orelse return error.ProxyBadResponse;
    const code = std.fmt.parseInt(u16, code_str, 10) catch return error.ProxyBadResponse;
    if (code != 200) return error.ProxyConnectFailed;
    const header_end = std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n").? + 4;
    if (header_end != resp_len) return error.ProxyUnexpectedData;

    // TLS handshake.
    const tls_client = try allocator.create(std.crypto.tls.Client);
    errdefer allocator.destroy(tls_client);
    tls_client.* = try std.crypto.tls.Client.init(stream, .{
        .host = .{ .explicit = target_host },
        .ca = .{ .bundle = client.ca_bundle },
    });
    tls_client.allow_truncation_attacks = true;

    return .{ .tls = tls_client, .stream = stream };
}

/// Old wrapper kept for compatibility; prefer establishProxyTlsTunnel.
pub fn connectHttpsProxyTunnel(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    target_host: []const u8,
    target_port: u16,
) !*std.http.Client.Connection {
    const t = try establishProxyTlsTunnel(client, allocator, target_host, target_port);
    const conn = try allocator.create(std.http.Client.Connection);
    errdefer allocator.destroy(conn);
    conn.* = .{
        .stream = t.stream,
        .tls_client = t.tls,
        .protocol = .tls,
        .host = try allocator.dupe(u8, target_host),
        .port = target_port,
        .proxied = true,
    };
    return conn;
}

/// HTTP POST via curl subprocess (most stable for proxy+TLS).
/// Uses system curl which handles proxy auth, TLS, chunked correctly.
fn curlHttpPost(allocator: std.mem.Allocator, req: *HttpRequest) !*HttpResponse {
    // Build curl command.
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.append("curl");
    try args.append("-s");
    try args.append("-S");
    try args.append("--max-time");
    try args.append("30");
    try args.append("-X");
    try args.append("POST");
    // URL
    const url = try std.fmt.allocPrint(allocator, "{s}", .{req.url});
    defer allocator.free(url);
    try args.append(url);
    // Headers
    for (req.headers.items) |h| {
        const hs = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h.name, h.value });
        defer allocator.free(hs);
        try args.append("-H");
        try args.append(hs);
    }
    // Body
    if (req.body) |body| {
        try args.append("--data-binary");
        // Write body to temp file to avoid arg length limits.
        const tmp_path = "/tmp/curl_body_tmp.json";
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        try f.writeAll(body);
        f.close();
        const data_arg = try std.fmt.allocPrint(allocator, "@{s}", .{tmp_path});
        defer allocator.free(data_arg);
        try args.append(data_arg);
    }
    // Capture response body and status code.
    try args.append("-w");
    try args.append("\n%{http_code}");
    try args.append("-o");
    try args.append("-"); // stdout

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    defer stdout.deinit(allocator);
    var stderr = std.ArrayListUnmanaged(u8){};
    defer stderr.deinit(allocator);

    try child.collectOutput(allocator, &stdout, &stderr, 16 * 1024 * 1024);
    const term = try child.wait();

    // Clean up temp file.
    std.fs.cwd().deleteFile("/tmp/curl_body_tmp.json") catch {};

    if (term.Exited != 0) {
        return error.CurlFailed;
    }

    // Parse output: body + "\n" + status_code
    const out = stdout.items;
    const last_nl = std.mem.lastIndexOfScalar(u8, out, '\n') orelse return error.CurlBadOutput;
    const code_str = std.mem.trim(u8, out[last_nl + 1 ..], " \r\n");
    const status = std.fmt.parseInt(u16, code_str, 10) catch return error.CurlBadOutput;
    const body = out[0..last_nl];

    const headers = try allocator.alloc(std.http.Header, 0);
    const body_copy = try allocator.dupe(u8, body);
    return try makeStatusResponse(allocator, status, headers, body_copy);
}

/// Manual HTTP/1.1 request over an established TLS tunnel.
/// Bypasses std.http.Client entirely for the proxied-HTTPS case.
fn manualHttpOverTls(
    allocator: std.mem.Allocator,
    tls: *std.crypto.tls.Client,
    stream: std.net.Stream,
    method: std.http.Method,
    uri: std.Uri,
    headers: []const std.http.Header,
    body: ?[]const u8,
) !*HttpResponse {
    const path: []const u8 = if (uri.path.raw.len != 0) uri.path.raw else "/";
    // Build request.
    var req_buf = std.ArrayList(u8).init(allocator);
    defer req_buf.deinit();
    const w = req_buf.writer();
    try w.print("{s} {s} HTTP/1.0\r\n", .{ @tagName(method), path });
    const host_str = switch (uri.host.?) { .raw => |s| s, .percent_encoded => |s| s };
    try w.print("Host: {s}\r\n", .{host_str});
    try w.writeAll("Connection: close\r\n");
    try w.writeAll("Accept-Encoding: identity\r\n");
    for (headers) |h| {
        // Skip Accept-Encoding, we already set it.
        if (std.ascii.eqlIgnoreCase(h.name, "Accept-Encoding")) continue;
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    if (body) |b| {
        try w.print("Content-Length: {d}\r\n", .{b.len});
    }
    try w.writeAll("\r\n");
    if (body) |b| {
        try w.writeAll(b);
    }
    try tls.writeAll(stream, req_buf.items);

    // Read response headers.
    var resp_buf = std.ArrayList(u8).init(allocator);
    defer resp_buf.deinit();
    var tmp: [8192]u8 = undefined;
    var header_end: ?usize = null;
    while (header_end == null) {
        const n = tls.read(stream, tmp[0..]) catch |err| {
            return err;
        };
        if (n == 0) {
            return error.HttpResponseEof;
        }
        try resp_buf.appendSlice(tmp[0..n]);
        if (std.mem.indexOf(u8, resp_buf.items, "\r\n\r\n")) |idx| {
            header_end = idx + 4;
        }
        if (resp_buf.items.len > 64 * 1024) return error.HttpHeadersTooLarge;
    }
    const he = header_end.?;
    // Parse status.
    const status_line_end = std.mem.indexOf(u8, resp_buf.items[0..he], "\r\n") orelse return error.HttpBadResponse;
    var parts = std.mem.splitScalar(u8, resp_buf.items[0..status_line_end], ' ');
    _ = parts.next();
    const code_str = parts.next() orelse return error.HttpBadResponse;
    const status_code = std.fmt.parseInt(u16, code_str, 10) catch return error.HttpBadResponse;
    // Parse headers.
    var resp_headers = std.ArrayList(std.http.Header).init(allocator);
    errdefer resp_headers.deinit();
    var hdr_iter = std.mem.splitSequence(u8, resp_buf.items[status_line_end + 2 .. he - 2], "\r\n");
    var content_length: ?usize = null;
    var is_chunked = false;
    while (hdr_iter.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") and std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
            is_chunked = true;
        }
        try resp_headers.append(.{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, value) });
    }
    // Read body.
    var body_out = std.ArrayList(u8).init(allocator);
    errdefer body_out.deinit();
    // Any body bytes already read after headers.
    if (resp_buf.items.len > he) {
        try body_out.appendSlice(resp_buf.items[he..]);
    }
    // Simplified: read until connection close (we sent Connection: close).
    // For chunked, read until we see the 0-chunk terminator, then de-chunk.
    if (is_chunked) {
        var raw = std.ArrayList(u8).init(allocator);
        defer raw.deinit();
        try raw.appendSlice(body_out.items);
        // Read until we find the chunked terminator "0\r\n\r\n" or "0\r\n" at end.
        var found_end = false;
        while (!found_end) {
            if (std.mem.indexOf(u8, raw.items, "\r\n0\r\n\r\n") != null or
                std.mem.endsWith(u8, raw.items, "\r\n0\r\n\r\n") or
                std.mem.endsWith(u8, raw.items, "\r\n0\r\n")) {
                found_end = true;
                break;
            }
            const n = tls.read(stream, tmp[0..]) catch |err| {
                return err;
            };
            if (n == 0) break; // EOF, try to parse what we have
            try raw.appendSlice(tmp[0..n]);
            // Safety: don't read forever
            if (raw.items.len > 10 * 1024 * 1024) return error.HttpResponseTooLarge;
        }
        // De-chunk: parse chunk sizes and extract data.
        body_out.clearRetainingCapacity();
        var pos: usize = 0;
        while (pos < raw.items.len) {
            const line_end_opt = std.mem.indexOf(u8, raw.items[pos..], "\r\n");
            if (line_end_opt == null) break;
            const line_end = line_end_opt.? + pos;
            const line = raw.items[pos..line_end];
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, line[0..semi], " "), 16) catch break;
            pos = line_end + 2;
            if (chunk_size == 0) break;
            if (pos + chunk_size > raw.items.len) break;
            try body_out.appendSlice(raw.items[pos .. pos + chunk_size]);
            pos += chunk_size + 2; // skip data and trailing CRLF
        }
    } else if (content_length) |cl| {
        while (body_out.items.len < cl) {
            const n = try tls.read(stream, tmp[0..]);
            if (n == 0) return error.HttpResponseEof;
            try body_out.appendSlice(tmp[0..n]);
        }
        if (body_out.items.len > cl) {
            try body_out.resize(cl);
        }
    } else {
        // No Content-Length, not chunked: use buffered data only.
        // Server should have sent everything with headers (HTTP/1.0).
    }

    const headers_slice = try resp_headers.toOwnedSlice();
    errdefer {
        for (headers_slice) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(headers_slice);
    }
    return try makeStatusResponse(allocator, status_code, headers_slice, try body_out.toOwnedSlice());
}

/// Parse Retry-After header value in delta-seconds. Returns 0 if absent or invalid.
fn getRetryAfterSecs(headers: []std.http.Header) u64 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            const v = std.mem.trim(u8, h.value, " \t");
            if (std.fmt.parseInt(u64, v, 10)) |secs| {
                return @min(secs, 300); // Cap at 5 minutes.
            } else |_| {}
            return 0;
        }
    }
    return 0;
}

/// Retryable: 429 Too Many Requests, and 5xx server errors.
/// Other 4xx (400, 401, 403, 404, ...) are not retried.
fn isRetryableStatus(status: u16) bool {
    return status == 429 or (status >= 500 and status < 600);
}

/// Exponential backoff in seconds: 1, 2, 4, 8, 16 for attempts 0..4.
fn backoffSecs(attempt: u32) u64 {
    return @as(u64, 1) << @intCast(@min(attempt, 4));
}

/// Single attempt without retry. See httpRequestExec for the retry wrapper.
fn httpRequestExecOnce(req: *HttpRequest) !*HttpResponse {
    const uri = try std.Uri.parse(req.url);
    req.client.request_mutex.lock();
    defer req.client.request_mutex.unlock();
    // Save proxies; maybeBypassProxy may clear them for no_proxy hosts.
    const saved_http_proxy = req.client.client.http_proxy;
    const saved_https_proxy = req.client.client.https_proxy;
    defer {
        req.client.client.http_proxy = saved_http_proxy;
        req.client.client.https_proxy = saved_https_proxy;
    }
    maybeBypassProxy(req, uri);
    // Disable response compression: Zig 0.14.1's gzip/deflate decompression
    // fails on some servers (DecompressionFailure). Identity is always safe.
    {
        const ae_name = try req.allocator.dupe(u8, "Accept-Encoding");
        errdefer req.allocator.free(ae_name);
        const ae_val = try req.allocator.dupe(u8, "identity");
        errdefer req.allocator.free(ae_val);
        try req.headers.append(.{ .name = ae_name, .value = ae_val });
    }
    var header_buf: [16 * 1024]u8 = undefined;
    if (std.mem.eql(u8, uri.scheme, "https") and req.client.client.https_proxy != null) {
        const target_port = uri.port orelse 443;
        const target_host = uri.host orelse return error.InvalidUri;
        const host_str = switch (target_host) {
            .raw => |s| s,
            .percent_encoded => |s| s,
        };
        // For proxy+TLS, try curl first (most stable), fallback to manual.
        // Outer if already ensured https + proxy, so just try curl.
        if (curlHttpPost(req.allocator, req)) |resp| {
            return resp;
        } else |_| {
            // Fallback to manual on curl failure.
        }
        // Manual path: tunnel + TLS + raw HTTP/1.0, bypassing std.http.Client.
        const t = try establishProxyTlsTunnel(&req.client.client, req.allocator, host_str, target_port);
        defer {
            req.allocator.destroy(t.tls);
            t.stream.close();
        }
        return try manualHttpOverTls(req.allocator, t.tls, t.stream, req.method, uri, req.headers.items, req.body);
    }
    var request = try req.client.client.open(req.method, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .headers = .{},
        .extra_headers = req.headers.items,
    });
    defer request.deinit();

    request.transfer_encoding = if (req.body) |body| .{ .content_length = body.len } else .none;
    try request.send();
    if (req.body) |body| {
        try request.writeAll(body);
    }
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

/// Retry wrapper: up to 5 retries (6 attempts total) on 429 / 5xx /
/// transient network errors. Exponential backoff (1,2,4,8,16s),
/// respecting Retry-After when present. Covers first and follow-up requests.
fn httpRequestExec(req: *HttpRequest) !*HttpResponse {
    const max_retries: u32 = 5;
    var attempt: u32 = 0;
    while (true) {
        const resp = httpRequestExecOnce(req) catch |err| {
            if (attempt < max_retries) {
                std.time.sleep(backoffSecs(attempt) * std.time.ns_per_s);
                attempt += 1;
                continue;
            }
            return err;
        };
        if (!isRetryableStatus(resp.status) or attempt >= max_retries) {
            return resp;
        }
        const wait_secs = @max(backoffSecs(attempt), getRetryAfterSecs(resp.headers));
        resp.deinit();
        std.time.sleep(wait_secs * std.time.ns_per_s);
        attempt += 1;
    }
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

// ============ SSE streaming POST ============
// Spawns curl in the background writing the response body to a temp file
// as it arrives (-N/--no-buffer). The caller polls and reads incrementally.

var sse_stream_counter = std.atomic.Value(u64).init(0);

const SseStream = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    body_path: []u8,
    header_path: []u8,
    req_body_path: []u8,
    read_offset: u64,
    http_status: u16,
    finished: bool,
    failed: bool,
};

fn sseTempPath(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const n = sse_stream_counter.fetchAdd(1, .monotonic);
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(allocator, "/tmp/scodex_sse_{d}_{d}.{s}", .{ pid, n, suffix });
}

fn sseParseStatus(header_path: []const u8) u16 {
    const f = std.fs.cwd().openFile(header_path, .{}) catch return 0;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.read(&buf) catch return 0;
    // First line: "HTTP/1.1 200 OK"
    const line_end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    const line = buf[0..line_end];
    // Find first space, then parse the number after it.
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return 0;
    const rest = std.mem.trimLeft(u8, line[sp + 1 ..], " ");
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return std.fmt.parseInt(u16, rest[0..sp2], 10) catch 0;
}

/// Parse Retry-After from SSE header file. Returns 0 if absent/invalid. Capped at 300s.
fn sseParseRetryAfter(header_path: []const u8) u64 {
    const f = std.fs.cwd().openFile(header_path, .{}) catch return 0;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch return 0;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 12 and std.ascii.eqlIgnoreCase(trimmed[0..12], "retry-after:")) {
            const v = std.mem.trim(u8, trimmed[12..], " \t");
            if (std.fmt.parseInt(u64, v, 10)) |secs| {
                return @min(secs, 300);
            } else |_| {}
        }
    }
    return 0;
}

fn sseCheckFinished(s: *SseStream) void {
    if (s.finished) return;
    const res = std.posix.waitpid(s.child.id, std.posix.W.NOHANG);
    if (res.pid == 0) return; // still running
    s.finished = true;
    if (std.posix.W.IFEXITED(res.status)) {
        s.failed = std.posix.W.EXITSTATUS(res.status) != 0;
    } else {
        s.failed = true; // signaled or stopped
    }
    s.http_status = sseParseStatus(s.header_path);
}

pub export fn sa_http_client_sse_post(
    url_ptr: ?[*]const u8, url_len: u64,
    body_ptr: ?[*]const u8, body_len: u64,
    key_ptr: ?[*]const u8, key_len: u64,
    out_handle: ?*?*anyopaque,
) u32 {
    const allocator = std.heap.page_allocator;
    const slot = out_handle orelse return 1;
    const url = if (url_ptr) |p| p[0..url_len] else return 1;

    const body_path = sseTempPath(allocator, "body") catch return 1;
    errdefer allocator.free(body_path);
    const header_path = sseTempPath(allocator, "headers") catch return 1;
    errdefer allocator.free(header_path);
    const req_body_path = sseTempPath(allocator, "req") catch return 1;
    errdefer allocator.free(req_body_path);

    // Write request body to temp file.
    {
        const f = std.fs.cwd().createFile(req_body_path, .{}) catch return 1;
        defer f.close();
        if (body_ptr) |p| {
            f.writeAll(p[0..body_len]) catch return 1;
        }
    }

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    args.append("curl") catch return 1;
    args.append("-s") catch return 1;
    args.append("-S") catch return 1;
    args.append("-N") catch return 1; // no buffering: stream as it arrives
    args.append("--max-time") catch return 1;
    args.append("300") catch return 1;
    args.append("-X") catch return 1;
    args.append("POST") catch return 1;
    args.append(url) catch return 1;
    // Auth header
    if (key_ptr) |kp| {
        const auth = std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{kp[0..key_len]}) catch return 1;
        defer allocator.free(auth);
        args.append("-H") catch return 1;
        args.append(auth) catch return 1;
    }
    args.append("-H") catch return 1;
    args.append("Content-Type: application/json") catch return 1;
    args.append("-H") catch return 1;
    args.append("Accept: text/event-stream") catch return 1;
    const data_arg = std.fmt.allocPrint(allocator, "@{s}", .{req_body_path}) catch return 1;
    defer allocator.free(data_arg);
    args.append("--data-binary") catch return 1;
    args.append(data_arg) catch return 1;
    args.append("-D") catch return 1;
    args.append(header_path) catch return 1;
    args.append("-o") catch return 1;
    args.append(body_path) catch return 1;

    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 1;

    const s = allocator.create(SseStream) catch {
        _ = child.kill() catch unreachable;
        _ = child.wait() catch {};
        return 1;
    };
    s.* = .{
        .allocator = allocator,
        .child = child,
        .body_path = body_path,
        .header_path = header_path,
        .req_body_path = req_body_path,
        .read_offset = 0,
        .http_status = 0,
        .finished = false,
        .failed = false,
    };
    slot.* = @ptrCast(s);
    return 0;
}

pub export fn sa_http_client_sse_read(
    handle: ?*anyopaque,
    buf_ptr: ?[*]u8, buf_cap: u64,
    out_len: ?*u64,
) u32 {
    const s = @as(*SseStream, @ptrCast(@alignCast(handle orelse return 1)));
    const out = out_len orelse return 1;
    const buf = buf_ptr orelse return 1;
    out.* = 0;
    if (buf_cap == 0) return 0;

    const f = std.fs.cwd().openFile(s.body_path, .{}) catch return 0;
    defer f.close();
    const st = f.stat() catch return 0;
    if (st.size <= s.read_offset) return 0;
    f.seekTo(s.read_offset) catch return 0;
    const want: usize = @intCast(@min(buf_cap, st.size - s.read_offset));
    const n = f.read(buf[0..want]) catch return 0;
    s.read_offset += n;
    out.* = n;
    return 0;
}

// out_done: 0 = running, 1 = finished ok, 2 = finished with error
pub export fn sa_http_client_sse_poll(handle: ?*anyopaque, out_done: ?*u8) u32 {
    const s = @as(*SseStream, @ptrCast(@alignCast(handle orelse return 1)));
    const out = out_done orelse return 1;
    sseCheckFinished(s);
    // Also try to parse status from headers if not yet known.
    if (s.http_status == 0) {
        s.http_status = sseParseStatus(s.header_path);
    }
    out.* = if (!s.finished) 0 else if (s.failed) 2 else 1;
    return 0;
}

pub export fn sa_http_client_sse_status(handle: ?*anyopaque) u16 {
    const s = @as(*SseStream, @ptrCast(@alignCast(handle orelse return 0)));
    if (s.http_status == 0) {
        s.http_status = sseParseStatus(s.header_path);
    }
    return s.http_status;
}

pub export fn sa_http_client_sse_free(handle: ?*anyopaque) u32 {
    const s = @as(*SseStream, @ptrCast(@alignCast(handle orelse return 1)));
    if (!s.finished) {
        _ = s.child.kill() catch {};
        _ = s.child.wait() catch {};
    }
    std.fs.cwd().deleteFile(s.body_path) catch {};
    std.fs.cwd().deleteFile(s.header_path) catch {};
    std.fs.cwd().deleteFile(s.req_body_path) catch {};
    s.allocator.free(s.body_path);
    s.allocator.free(s.header_path);
    s.allocator.free(s.req_body_path);
    s.allocator.destroy(s);
    return 0;
}

// High-level SSE turn: POST, stream, parse events, print deltas live,
// accumulate text and tool calls. Bypasses SLA compiler limitations.
// Returns: 0=ok (text), 1=ok (tool calls), 2=error.
// Out params: text (ptr/len), calls_json (ptr/len, JSON array of {call_id,name,args}).
// Caller must free returned buffers via sa_http_client_sse_turn_free.
pub export fn sa_http_client_sse_turn(
    url_ptr: ?[*]const u8, url_len: u64,
    body_ptr: ?[*]const u8, body_len: u64,
    key_ptr: ?[*]const u8, key_len: u64,
    api_mode: u64,
    out_text_ptr: ?*?[*]u8, out_text_len: ?*u64,
    out_calls_ptr: ?*?[*]u8, out_calls_len: ?*u64,
) u32 {
    const otp = out_text_ptr orelse return 2;
    const otl = out_text_len orelse return 2;
    const ocp = out_calls_ptr orelse return 2;
    const ocl = out_calls_len orelse return 2;
    otp.* = null;
    otl.* = 0;
    ocp.* = null;
    ocl.* = 0;

    // Retry wrapper: up to 5 retries (6 attempts) on 429/5xx/transient network errors.
    // Exponential backoff 1/2/4/8/16s, respecting Retry-After (capped at 5min).
    // Once streaming starts (200 OK), no retry - mid-stream failures return error.
    var attempt: u32 = 0;
    while (true) {
        var handle: ?*anyopaque = null;
        if (sa_http_client_sse_post(url_ptr, url_len, body_ptr, body_len, key_ptr, key_len, &handle) != 0 or handle == null) {
            if (handle) |h| _ = sa_http_client_sse_free(h);
            if (attempt < 5) {
                std.time.sleep(backoffSecs(attempt) * std.time.ns_per_s);
                attempt += 1;
                continue;
            }
            return 2;
        }
        // Wait for HTTP status.
        var status: u16 = 0;
        var waits: u32 = 0;
        while (waits < 200) : (waits += 1) {
            const st = sa_http_client_sse_status(handle);
            if (st != 0) {
                status = st;
                break;
            }
            var done: u8 = 0;
            _ = sa_http_client_sse_poll(handle, &done);
            if (done != 0) break;
            std.time.sleep(50 * std.time.ns_per_ms);
        }
        if (status == 200) {
            // Success: stream to completion. sseTurnStream does not free handle;
            // we free it here via defer.
            defer _ = sa_http_client_sse_free(handle);
            return sseTurnStream(handle, api_mode, otp, otl, ocp, ocl);
        }
        // Non-200: check if retryable.
        const s = @as(*SseStream, @ptrCast(@alignCast(handle.?)));
        const retry_after = sseParseRetryAfter(s.header_path);
        _ = sa_http_client_sse_free(handle);
        if (status != 0 and isRetryableStatus(status) and attempt < 5) {
            const wait_secs = @max(backoffSecs(attempt), retry_after);
            std.time.sleep(wait_secs * std.time.ns_per_s);
            attempt += 1;
            continue;
        }
        return 2;
    }
}

/// Streaming part: assumes handle has 200 OK status. Reads SSE stream to completion.
fn sseTurnStream(
    handle: ?*anyopaque,
    api_mode: u64,
    otp: *?[*]u8, otl: *u64,
    ocp: *?[*]u8, ocl: *u64,
) u32 {
    const allocator = std.heap.page_allocator;
    const s = @as(*SseStream, @ptrCast(@alignCast(handle.?)));

    var text = std.ArrayList(u8).init(allocator);
    defer text.deinit();
    var calls = std.ArrayList(SseCall).init(allocator);
    defer {
        for (calls.items) |*c| {
            if (c.call_id.len > 0) allocator.free(c.call_id);
            if (c.name.len > 0) allocator.free(c.name);
            if (c.args.len > 0) allocator.free(c.args);
            if (c.key.len > 0) allocator.free(c.key);
        }
        calls.deinit();
    }
    var active = std.ArrayList(SseCall).init(allocator);
    defer {
        // Free any remaining active calls.
        for (active.items) |*ac| {
            if (ac.call_id.len > 0) allocator.free(ac.call_id);
            if (ac.name.len > 0) allocator.free(ac.name);
            if (ac.args.len > 0) allocator.free(ac.args);
            if (ac.key.len > 0) allocator.free(ac.key);
        }
        active.deinit();
    }
    var stream_done = false;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var processed_offset: usize = 0;

    const stdout = std.io.getStdOut().writer();

    // Main read loop.
    while (!stream_done) {
        // Read new bytes from body file.
        const new_data = sseReadNew(s, &processed_offset) catch {
            return 2;
        };
        if (new_data.len > 0) {
            buf.appendSlice(new_data) catch return 2;
            allocator.free(new_data);
            // Extract complete events.
            while (true) {
                const delim = sseFindEventEnd(buf.items) orelse break;
                const ev = buf.items[0..delim.pos];
                // Parse event data.
                if (sseParseEventData(allocator, ev)) |data| {
                    defer if (data.owned) allocator.free(data.payload);
                    if (data.is_done) {
                        stream_done = true;
                    } else if (data.payload.len > 0) {
                        sseHandleEvent(allocator, data.payload, api_mode, &text, &calls, &active, &stream_done, stdout) catch {};
                    }
                }
                // Remove processed event (+ delimiter length).
                const remove_len = delim.pos + delim.len;
                if (remove_len < buf.items.len) {
                    std.mem.copyForwards(u8, buf.items[0..], buf.items[remove_len..]);
                }
                buf.shrinkRetainingCapacity(buf.items.len - remove_len);
                if (stream_done) break;
            }
        }
        if (stream_done) break;
        var done: u8 = 0;
        _ = sa_http_client_sse_poll(handle, &done);
        if (done == 1) {
            // Process trailing.
            if (buf.items.len > 0) {
                if (sseParseEventData(allocator, buf.items)) |data| {
                    defer if (data.owned) allocator.free(data.payload);
                    if (!data.is_done and data.payload.len > 0) {
                        sseHandleEvent(allocator, data.payload, api_mode, &text, &calls, &active, &stream_done, stdout) catch {};
                    }
                }
            }
            break;
        } else if (done == 2) {
            return 2;
        }
        if (new_data.len == 0) {
            std.time.sleep(20 * std.time.ns_per_ms);
        }
    }

    // Finalize all active calls.
    sseFinalizeActive(allocator, &active, &calls) catch return 2;

    // Print newline after stream.
    stdout.writeAll("\n") catch {};

    // Build calls JSON first (so text isn't leaked on failure).
    var calls_json = std.ArrayList(u8).init(allocator);
    defer calls_json.deinit();
    calls_json.appendSlice("[") catch return 2;
    for (calls.items, 0..) |c, i| {
        if (i > 0) calls_json.appendSlice(",") catch return 2;
        calls_json.appendSlice("{\"call_id\":\"") catch return 2;
        sseJsonEscape(calls_json.writer(), c.call_id) catch return 2;
        calls_json.appendSlice("\",\"name\":\"") catch return 2;
        sseJsonEscape(calls_json.writer(), c.name) catch return 2;
        calls_json.appendSlice("\",\"args\":\"") catch return 2;
        sseJsonEscape(calls_json.writer(), c.args) catch return 2;
        calls_json.appendSlice("\"}") catch return 2;
    }
    calls_json.appendSlice("]") catch return 2;
    const cj_slice = calls_json.toOwnedSlice() catch return 2;
    errdefer allocator.free(cj_slice);

    // Return text.
    const text_slice = text.toOwnedSlice() catch {
        allocator.free(cj_slice);
        return 2;
    };

    // All succeeded; assign outputs.
    otp.* = text_slice.ptr;
    otl.* = text_slice.len;
    ocp.* = cj_slice.ptr;
    ocl.* = cj_slice.len;

    return if (calls.items.len > 0) 1 else 0;
}

const SseCall = struct {
    call_id: []u8,
    name: []u8,
    args: []u8,
    // For lookup during streaming: responses uses call_id, chat uses index.
    // We store the raw key string for matching.
    key: []u8,
};

const SseEventData = struct {
    payload: []const u8,
    is_done: bool,
    owned: bool, // if true, caller must free payload
};

fn sseReadNew(s: *SseStream, offset: *usize) ![]u8 {
    const f = std.fs.cwd().openFile(s.body_path, .{}) catch |err| {
        // File not yet created by curl; treat as no new data.
        if (err == error.FileNotFound) {
            return try s.allocator.alloc(u8, 0);
        }
        return err;
    };
    defer f.close();
    const stat = try f.stat();
    const size = stat.size;
    if (size <= offset.*) return try s.allocator.alloc(u8, 0);
    const len = size - offset.*;
    var data = try s.allocator.alloc(u8, len);
    errdefer s.allocator.free(data);
    try f.seekTo(offset.*);
    const n = try f.readAll(data);
    offset.* += n;
    // Shrink to actual bytes read so free() gets the right size.
    if (n < len) {
        data = try s.allocator.realloc(data, n);
    }
    return data;
}

const SseDelim = struct { pos: usize, len: usize };
fn sseFindEventEnd(data: []const u8) ?SseDelim {
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == '\n' and data[i + 1] == '\n') return .{ .pos = i, .len = 2 };
        // CRLF: \r\n\r\n is 4 bytes.
        if (i + 3 < data.len and data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n') return .{ .pos = i, .len = 4 };
    }
    return null;
}

fn sseParseEventData(allocator: std.mem.Allocator, ev: []const u8) ?SseEventData {
    // SSE spec: multiple "data:" lines are joined with "\n".
    var parts = std.ArrayList([]const u8).init(allocator);
    defer parts.deinit();
    var is_done = false;
    var lines = std.mem.splitScalar(u8, ev, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.mem.startsWith(u8, trimmed, "data:")) {
            const d = std.mem.trim(u8, trimmed[5..], " ");
            if (std.mem.eql(u8, d, "[DONE]")) {
                is_done = true;
            } else {
                parts.append(d) catch return null;
            }
        }
    }
    if (is_done) return .{ .payload = "", .is_done = true, .owned = false };
    if (parts.items.len == 0) return null;
    if (parts.items.len == 1) {
        return .{ .payload = parts.items[0], .is_done = false, .owned = false };
    }
    // Join with \n.
    const joined = std.mem.join(allocator, "\n", parts.items) catch return null;
    return .{ .payload = joined, .is_done = false, .owned = true };
}

fn sseHandleEvent(
    allocator: std.mem.Allocator,
    data: []const u8,
    api_mode: u64,
    text: *std.ArrayList(u8),
    calls: *std.ArrayList(SseCall),
    active: *std.ArrayList(SseCall),
    stream_done: *bool,
    stdout: anytype,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (api_mode == 0) {
        try sseHandleResponsesEvent(allocator, root, text, calls, active, stream_done, stdout);
    } else {
        try sseHandleChatEvent(allocator, root, text, calls, active, stream_done, stdout);
    }
}

// Find an active call by key (call_id for responses, index string for chat).
fn sseFindActive(active: *std.ArrayList(SseCall), key: []const u8) ?*SseCall {
    for (active.items) |*ac| {
        if (std.mem.eql(u8, ac.key, key)) return ac;
    }
    return null;
}

// Move all active calls to the completed list (finalize).
fn sseFinalizeActive(allocator: std.mem.Allocator, active: *std.ArrayList(SseCall), calls: *std.ArrayList(SseCall)) !void {
    for (active.items) |*ac| {
        if (ac.name.len > 0) {
            try calls.append(ac.*);
        } else {
            if (ac.call_id.len > 0) allocator.free(ac.call_id);
            if (ac.name.len > 0) allocator.free(ac.name);
            if (ac.args.len > 0) allocator.free(ac.args);
            if (ac.key.len > 0) allocator.free(ac.key);
        }
    }
    active.clearRetainingCapacity();
}

fn sseJsonStr(val: std.json.Value) ?[]const u8 {
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn sseHandleResponsesEvent(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    text: *std.ArrayList(u8),
    calls: *std.ArrayList(SseCall),
    active: *std.ArrayList(SseCall),
    stream_done: *bool,
    stdout: anytype,
) !void {
    const obj = switch (root) { .object => |o| o, else => return };
    const tval = obj.get("type") orelse return;
    const tstr = sseJsonStr(tval) orelse return;

    if (std.mem.eql(u8, tstr, "response.output_text.delta")) {
        if (obj.get("delta")) |dval| {
            if (sseJsonStr(dval)) |ds| {
                try stdout.writeAll(ds);
                try text.appendSlice(ds);
            }
        }
    } else if (std.mem.eql(u8, tstr, "response.output_item.added")) {
        if (obj.get("item")) |ival| {
            const item = switch (ival) { .object => |o| o, else => return };
            if (item.get("type")) |tyval| {
                if (sseJsonStr(tyval)) |tys| {
                    if (std.mem.eql(u8, tys, "function_call")) {
                        var cid: []u8 = &.{};
                        var nm: []u8 = &.{};
                        if (item.get("call_id")) |cv| {
                            if (sseJsonStr(cv)) |cs| cid = try allocator.dupe(u8, cs);
                        }
                        if (item.get("name")) |nv| {
                            if (sseJsonStr(nv)) |ns| nm = try allocator.dupe(u8, ns);
                        }
                        // Key by call_id for delta routing.
                        const key = try allocator.dupe(u8, cid);
                        errdefer allocator.free(key);
                        // If a call with same key exists, finalize it first.
                        if (sseFindActive(active, key)) |existing| {
                            if (existing.name.len > 0) {
                                try calls.append(existing.*);
                            } else {
                                if (existing.call_id.len > 0) allocator.free(existing.call_id);
                                if (existing.name.len > 0) allocator.free(existing.name);
                                if (existing.args.len > 0) allocator.free(existing.args);
                                if (existing.key.len > 0) allocator.free(existing.key);
                            }
                            // Remove from active.
                            for (active.items, 0..) |*ac, idx| {
                                if (ac == existing) {
                                    _ = active.orderedRemove(idx);
                                    break;
                                }
                            }
                        }
                        try active.append(.{
                            .call_id = cid,
                            .name = nm,
                            .args = &.{},
                            .key = key,
                        });
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, tstr, "response.function_call_arguments.delta")) {
        // Route by item_id if present, else use most recent active.
        var target: ?*SseCall = null;
        if (obj.get("item_id")) |idval| {
            if (sseJsonStr(idval)) |ids| {
                target = sseFindActive(active, ids);
            }
        }
        if (target == null and active.items.len > 0) {
            target = &active.items[active.items.len - 1];
        }
        if (target) |cc| {
            if (obj.get("delta")) |dval| {
                if (sseJsonStr(dval)) |ds| {
                    const old_args = cc.args;
                    const new_args = try std.mem.concat(allocator, u8, &.{ old_args, ds });
                    if (old_args.len > 0) allocator.free(old_args);
                    cc.args = new_args;
                }
            }
        }
    } else if (std.mem.eql(u8, tstr, "response.completed")) {
        stream_done.* = true;
    }
}

fn sseHandleChatEvent(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    text: *std.ArrayList(u8),
    calls: *std.ArrayList(SseCall),
    active: *std.ArrayList(SseCall),
    stream_done: *bool,
    stdout: anytype,
) !void {
    _ = stream_done;
    const obj = switch (root) { .object => |o| o, else => return };
    const cval = obj.get("choices") orelse return;
    const carr = switch (cval) { .array => |a| a, else => return };
    if (carr.items.len == 0) return;
    const choice = switch (carr.items[0]) { .object => |o| o, else => return };
    const dval = choice.get("delta") orelse return;
    const delta = switch (dval) { .object => |o| o, else => return };

    if (delta.get("content")) |cv| {
        if (sseJsonStr(cv)) |cs| {
            try stdout.writeAll(cs);
            try text.appendSlice(cs);
        }
    }

    if (delta.get("tool_calls")) |tcval| {
        const tcarr = switch (tcval) { .array => |a| a, else => return };
        for (tcarr.items) |tcitem| {
            const tc = switch (tcitem) { .object => |o| o, else => continue };
            // Get index for routing (default "0").
            var idx_buf: [16]u8 = undefined;
            var idx_str: []const u8 = "0";
            if (tc.get("index")) |ixval| {
                switch (ixval) {
                    .integer => |ix| {
                        idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{ix}) catch "0";
                    },
                    else => {},
                }
            }
            if (tc.get("id")) |idval| {
                if (sseJsonStr(idval)) |ids| {
                    // New call with this index: finalize previous with same index.
                    if (sseFindActive(active, idx_str)) |existing| {
                        if (existing.name.len > 0) {
                            try calls.append(existing.*);
                        } else {
                            if (existing.call_id.len > 0) allocator.free(existing.call_id);
                            if (existing.name.len > 0) allocator.free(existing.name);
                            if (existing.args.len > 0) allocator.free(existing.args);
                            if (existing.key.len > 0) allocator.free(existing.key);
                        }
                        for (active.items, 0..) |*ac, i| {
                            if (ac == existing) {
                                _ = active.orderedRemove(i);
                                break;
                            }
                        }
                    }
                    var nm: []u8 = &.{};
                    var ag: []u8 = &.{};
                    if (tc.get("function")) |fval| {
                        const func = switch (fval) { .object => |o| o, else => null };
                        if (func) |fo| {
                            if (fo.get("name")) |nv| {
                                if (sseJsonStr(nv)) |ns| nm = try allocator.dupe(u8, ns);
                            }
                            if (fo.get("arguments")) |av| {
                                if (sseJsonStr(av)) |as| ag = try allocator.dupe(u8, as);
                            }
                        }
                    }
                    const key = try allocator.dupe(u8, idx_str);
                    errdefer allocator.free(key);
                    try active.append(.{
                        .call_id = try allocator.dupe(u8, ids),
                        .name = nm,
                        .args = ag,
                        .key = key,
                    });
                }
            } else if (tc.get("function")) |fval| {
                // Arguments delta: route by index.
                if (sseFindActive(active, idx_str)) |cc| {
                    const func = switch (fval) { .object => |o| o, else => continue };
                    if (func.get("arguments")) |av| {
                        if (sseJsonStr(av)) |as| {
                            const old_args = cc.args;
                            const new_args = try std.mem.concat(allocator, u8, &.{ old_args, as });
                            if (old_args.len > 0) allocator.free(old_args);
                            cc.args = new_args;
                        }
                    }
                }
            }
        }
    }
}

fn sseJsonEscape(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
}

pub export fn sa_http_client_sse_turn_free(ptr: ?[*]u8, len: u64) void {
    if (ptr) |p| {
        const slice = p[0..len];
        std.heap.page_allocator.free(slice);
    }
}
