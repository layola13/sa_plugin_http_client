const std = @import("std");
const builtin = @import("builtin");
const sio = @import("sio");
const plugin_api = @import("plugin_api");
const sa_std_net = @import("sa_std_net.zig");

// NOTE(Zig 0.17): `std.net.tcpConnectToHost` was removed (only literals via
// `IpAddress.parse`; DNS via `HostName.connect` with Happy Eyeballs).
pub fn dialHost(host: []const u8, port: u16) !std.Io.net.Stream {
    if (std.Io.net.IpAddress.parse(host, port)) |addr| {
        var a = addr;
        return a.connect(sio.io(), .{ .mode = .stream });
    } else |_| {}
    const hn = try std.Io.net.HostName.init(host);
    return hn.connect(sio.io(), port, .{ .mode = .stream });
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}
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
    proxy_arena: std.heap.ArenaAllocator,
    lifetime_mutex: std.atomic.Mutex = .unlocked,
    reference_count: usize = 1,
    // Serializes request execution so per-request proxy bypass (no_proxy)
    // can temporarily clear client.http_proxy/https_proxy safely.
    request_mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, cfg: HttpClientConfig) !*HttpClient {
        const self = try allocator.create(HttpClient);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = sio.io() },
            .proxy_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.proxy_arena.deinit();
        // Route through https_proxy/http_proxy env vars when present (sandboxed
        // environments may block direct DNS/TCP; the proxy path is required).
        // NOTE(Zig 0.17): proxy env must be loaded explicitly via arena + map.
        if (sio.getEnvMap(allocator)) |env| {
            var owned_env = env;
            defer owned_env.deinit();
            self.client.initDefaultProxies(self.proxy_arena.allocator(), &owned_env) catch {};
        } else |_| {}
        try self.configureHttpsTrust(cfg);
        return self;
    }

    fn configureHttpsTrust(self: *HttpClient, cfg: HttpClientConfig) !void {
        if (std.http.Client.disable_tls or cfg.use_tls == 0) return;
        if (cfg.ca_bundle_path) |bundle_path| {
            const abs_path = try sio.cwd().realpathAlloc(self.allocator, bundle_path);
            defer self.allocator.free(abs_path);
            const now = std.Io.Clock.real.now(sio.io());
            try self.client.ca_bundle.addCertsFromFilePathAbsolute(
                self.allocator,
                sio.io(),
                now,
                abs_path,
            );
            // NOTE(Zig 0.17): std.http.Client.fetch() rescans the OS trust
            // store and SWAPS OUT our bundle when client.now == null. Pin now
            // so the custom CA survives.
            self.client.now = now;
        }
    }

    pub fn retain(self: *HttpClient) void {
        while (!self.lifetime_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.lifetime_mutex.unlock();
        std.debug.assert(self.reference_count > 0);
        self.reference_count += 1;
    }

    pub fn release(self: *HttpClient) void {
        while (!self.lifetime_mutex.tryLock()) std.atomic.spinLoopHint();
        std.debug.assert(self.reference_count > 0);
        self.reference_count -= 1;
        const destroy = self.reference_count == 0;
        self.lifetime_mutex.unlock();
        if (!destroy) return;
        self.client.deinit();
        self.proxy_arena.deinit();
        self.allocator.destroy(self);
    }
};

pub const HttpRequest = struct {
    allocator: std.mem.Allocator,
    client: *HttpClient,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8 = null,
    headers: std.array_list.Managed(std.http.Header),
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
            .headers = std.array_list.Managed(std.http.Header).init(client.allocator),
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
        .headers = std.array_list.Managed(std.http.Header).init(allocator),
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
    mutex: std.atomic.Mutex = .unlocked,
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
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        self.response = response;
        self.done = true;
        self.mutex.unlock();
    }

    fn poll(self: *HttpRequestAsyncOp) bool {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.done;
    }

    fn takeResponse(self: *HttpRequestAsyncOp) ?*HttpResponse {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
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
    const no_proxy = sio.getEnvVarOwned(req.allocator, "no_proxy") catch
        (sio.getEnvVarOwned(req.allocator, "NO_PROXY") catch return);
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
    var headers = std.array_list.Managed(std.http.Header).init(allocator);
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        headers.deinit();
    }

    var it = response.head.iterateHeaders();
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


/// HTTP POST via curl subprocess (most stable for proxy+TLS).
/// Uses system curl which handles proxy auth, TLS, chunked correctly.
fn curlHttpPost(allocator: std.mem.Allocator, req: *HttpRequest) !*HttpResponse {
    // Build curl command.
    var args = std.array_list.Managed([]const u8).init(allocator);
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
        const f = try sio.cwd().createFile(tmp_path, .{});
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

    const result = try sio.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Clean up temp file.
    sio.cwd().deleteFile("/tmp/curl_body_tmp.json") catch {};

    switch (result.term) {
        .exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }

    // Parse output: body + "\n" + status_code
    const out = result.stdout;
    const last_nl = std.mem.lastIndexOfScalar(u8, out, '\n') orelse return error.CurlBadOutput;
    const code_str = std.mem.trim(u8, out[last_nl + 1 ..], " \r\n");
    const status = std.fmt.parseInt(u16, code_str, 10) catch return error.CurlBadOutput;
    const body = out[0..last_nl];

    const headers = try allocator.alloc(std.http.Header, 0);
    const body_copy = try allocator.dupe(u8, body);
    return try makeStatusResponse(allocator, status, headers, body_copy);
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
    while (!req.client.request_mutex.tryLock()) std.atomic.spinLoopHint();
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
    // NOTE(Zig 0.17): proxy CONNECT tunnels + TLS are handled natively by
    // std.http.Client (see HttpClient.init -> initDefaultProxies); the manual
    // tunnel path was removed.
    var redirect_buf: [16 * 1024]u8 = undefined;
    var request = try req.client.client.request(req.method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .extra_headers = req.headers.items,
    });
    defer request.deinit();
    if (req.body) |body| {
        const owned_body = try req.allocator.dupe(u8, body);
        defer req.allocator.free(owned_body);
        try request.sendBodyComplete(owned_body);
    } else {
        try request.sendBodiless();
    }
    var response = try request.receiveHead(&redirect_buf);
    const headers = try cloneResponseHeaders(req.allocator, response);
    errdefer {
        for (headers) |header| {
            req.allocator.free(header.name);
            req.allocator.free(header.value);
        }
        req.allocator.free(headers);
    }
    var body = std.array_list.Managed(u8).init(req.allocator);
    errdefer body.deinit();
    var transfer_buf: [8192]u8 = undefined;
    var body_reader = response.reader(&transfer_buf);
    var read_buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try body_reader.readSliceShort(&read_buf);
        if (n == 0) break;
        total += n;
        if (total > 16 * 1024 * 1024) return error.StreamTooLong;
        try body.appendSlice(read_buf[0..n]);
    }
    return try makeStatusResponse(req.allocator, mapStatus(response.head.status), headers, try body.toOwnedSlice());
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
                sio.io().sleep(.fromNanoseconds(backoffSecs(attempt) * std.time.ns_per_s), .awake) catch {};
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
        sio.io().sleep(.fromNanoseconds(wait_secs * std.time.ns_per_s), .awake) catch {};
        attempt += 1;
    }
}

fn readAllIntoList(reader: anytype, allocator: std.mem.Allocator) !std.array_list.Managed(u8) {
    var out = std.array_list.Managed(u8).init(allocator);
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
    stream: ?std.Io.net.Stream = null,
    // TLS state for wss://. The net reader/writer (and their buffers) must
    // outlive tls_client, which borrows them; all live in the handle.
    tls_client: ?*std.crypto.tls.Client = null,
    net_reader: std.Io.net.Stream.Reader = undefined,
    net_writer: std.Io.net.Stream.Writer = undefined,
    net_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    net_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    // Persistent buffered reader for plain (non-TLS) frame reads. A fresh
    // reader per read would over-read past frame boundaries and lose bytes.
    frame_reader: std.Io.net.Stream.Reader = undefined,
    frame_read_buf: [8192]u8 = undefined,
    tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    ca_lock: std.Io.RwLock = .init,

    fn isClient(self: *WebSocketHandle) bool {
        _ = self;
        return true;
    }

    fn rawRead(self: *WebSocketHandle, buffer: []u8) !usize {
        if (self.tls_client) |t| {
            return try t.reader.readSliceShort(buffer);
        }
        return try self.frame_reader.interface.readSliceShort(buffer);
    }

    fn rawWrite(self: *WebSocketHandle, bytes: []const u8) !void {
        if (self.tls_client) |t| {
            try t.writer.writeAll(bytes);
            try t.writer.flush();
            return;
        }
        const stream = self.stream orelse return error.EndOfStream;
        var wbuf: [8192]u8 = undefined;
        var w = stream.writer(sio.io(), &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    fn readExact(self: *WebSocketHandle, buffer: []u8) bool {
        var offset: usize = 0;
        while (offset < buffer.len) {
            const n = self.rawRead(buffer[offset..]) catch return false;
            if (n == 0) return false;
            offset += n;
        }
        return true;
    }

    fn writeExact(self: *WebSocketHandle, bytes: []const u8) bool {
        self.rawWrite(bytes) catch return false;
        return true;
    }

    fn deinit(self: *WebSocketHandle) void {
        if (self.tls_client) |t| {
            self.allocator.destroy(t);
            self.tls_client = null;
        }
        if (self.stream) |stream| {
            stream.close(sio.io());
            self.stream = null;
        }
        self.allocator.destroy(self);
    }
};

fn findRawHeader(head: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), key)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
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
        sio.io().random(&mask_key);
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
        if (handle.stream == null and handle.tls_client == null) return fail();
        const reader: *std.Io.Reader = if (handle.tls_client) |t|
            &t.reader
        else
            &handle.frame_reader.interface;
        const frame = sa_std_net.readWebSocketFrameAlloc(handle.allocator, reader, max_len, !handle.isClient()) catch return fail();
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

    const host_slice = switch (uri.host orelse return fail()) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
    const use_tls = std.mem.eql(u8, uri.scheme, "wss") or std.mem.eql(u8, uri.scheme, "https");
    if (!use_tls and !std.mem.eql(u8, uri.scheme, "ws") and !std.mem.eql(u8, uri.scheme, "http")) return fail();
    const port: u16 = uri.port orelse if (use_tls) 443 else 80;

    // Request target: path + optional query.
    var target_buf: [8192]u8 = undefined;
    var target_stream = std.Io.Writer.fixed(&target_buf);
    const raw_path: []const u8 = switch (uri.path) {
        .raw => |s| if (s.len != 0) s else "/",
        .percent_encoded => |s| if (s.len != 0) s else "/",
    };
    target_stream.print("{s}", .{raw_path}) catch return fail();
    if (uri.query) |q| {
        const qs = switch (q) {
            .raw => |s| s,
            .percent_encoded => |s| s,
        };
        target_stream.print("?{s}", .{qs}) catch return fail();
    }
    const target = target_stream.buffer[0..target_stream.end];

    var key_bytes: [16]u8 = undefined;
    sio.io().random(&key_bytes);
    var key_b64: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

    var stream = dialHost(host_slice, port) catch return fail();
    errdefer stream.close(sio.io());

    const handle = cli.allocator.create(WebSocketHandle) catch {
        stream.close(sio.io());
        return fail();
    };
    errdefer handle.deinit();
    handle.* = .{ .allocator = cli.allocator, .stream = stream };
    handle.frame_reader = stream.reader(sio.io(), &handle.frame_read_buf);

    if (use_tls) {
        // TLS handshake over the raw stream (wss://).
        handle.net_reader = stream.reader(sio.io(), &handle.net_read_buf);
        handle.net_writer = stream.writer(sio.io(), &handle.net_write_buf);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        sio.io().random(&entropy);
        const tls_client = cli.allocator.create(std.crypto.tls.Client) catch return fail();
        errdefer cli.allocator.destroy(tls_client);
        tls_client.* = std.crypto.tls.Client.init(
            &handle.net_reader.interface,
            &handle.net_writer.interface,
            .{
                .host = .{ .explicit = host_slice },
                .ca = .{ .bundle = .{
                    .gpa = cli.allocator,
                    .io = sio.io(),
                    .lock = &handle.ca_lock,
                    .bundle = &cli.client.ca_bundle,
                } },
                .write_buffer = &handle.tls_write_buf,
                .read_buffer = &handle.tls_read_buf,
                .entropy = &entropy,
                .realtime_now = std.Io.Clock.real.now(sio.io()),
            },
        ) catch return fail();
        handle.tls_client = tls_client;
    }

    // Send upgrade request.
    var req_buf = std.array_list.Managed(u8).init(cli.allocator);
    defer req_buf.deinit();
    req_buf.print("GET {s} HTTP/1.1\r\n", .{target}) catch return fail();
    if (port == 80 or port == 443) {
        req_buf.print("Host: {s}\r\n", .{host_slice}) catch return fail();
    } else {
        req_buf.print("Host: {s}:{d}\r\n", .{ host_slice, port }) catch return fail();
    }
    req_buf.appendSlice("Connection: Upgrade\r\nUpgrade: websocket\r\nsec-websocket-version: 13\r\n") catch return fail();
    req_buf.print("sec-websocket-key: {s}\r\n\r\n", .{key}) catch return fail();
    if (!handle.writeExact(req_buf.items)) return fail();

    // Read response head.
    var head_buf = std.array_list.Managed(u8).init(cli.allocator);
    defer head_buf.deinit();
    var tmp: [4096]u8 = undefined;
    var head_end: ?usize = null;
    while (head_end == null) {
        const n = handle.rawRead(&tmp) catch return fail();
        if (n == 0) return fail();
        head_buf.appendSlice(tmp[0..n]) catch return fail();
        if (head_buf.items.len > 64 * 1024) return fail();
        if (std.mem.indexOf(u8, head_buf.items, "\r\n\r\n")) |idx| head_end = idx;
    }
    const head = head_buf.items[0..head_end.?];
    {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = lines.next() orelse return fail();
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next();
        const code_str = parts.next() orelse return fail();
        const code = std.fmt.parseInt(u16, code_str, 10) catch return fail();
        if (code != 101) return fail();
    }
    const upgrade = findRawHeader(head, "upgrade") orelse return fail();
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return fail();
    const connection_value = findRawHeader(head, "connection") orelse return fail();
    if (!websocketHeaderContainsToken(connection_value, "upgrade")) return fail();
    const accept_value = findRawHeader(head, "sec-websocket-accept") orelse return fail();
    var expected_accept_buf: [28]u8 = undefined;
    const expected_accept = sa_std_net.websocketAccept(key, &expected_accept_buf) catch return fail();
    if (!std.mem.eql(u8, accept_value, expected_accept)) return fail();

    slot.* = @ptrCast(handle);
    return 0;
}

// ============ SSE streaming POST ============
// Spawns curl in the background writing the response body to a temp file
// as it arrives (-N/--no-buffer). The caller polls and reads incrementally.

var sse_stream_counter = std.atomic.Value(u64).init(0);

const SseStream = struct {
    allocator: std.mem.Allocator,
    child: sio.Child,
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
    const f = sio.cwd().openFile(header_path, .{}) catch return 0;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.read(&buf) catch return 0;
    // First line: "HTTP/1.1 200 OK"
    const line_end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    const line = buf[0..line_end];
    // Find first space, then parse the number after it.
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return 0;
    const rest = std.mem.trimStart(u8, line[sp + 1 ..], " ");
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return std.fmt.parseInt(u16, rest[0..sp2], 10) catch 0;
}

/// Parse Retry-After from SSE header file. Returns 0 if absent/invalid. Capped at 300s.
fn sseParseRetryAfter(header_path: []const u8) u64 {
    const f = sio.cwd().openFile(header_path, .{}) catch return 0;
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
    // NOTE(Zig 0.17): `std.posix.waitpid` was removed; poll via raw Linux
    // wait4 with WNOHANG (curl SSE path is Linux-only in practice).
    if (builtin.os.tag != .linux) return;
    const inner = &(s.child.inner orelse return);
    const pid = inner.id orelse return;
    var status: i32 = 0;
    const rc = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
    if (rc == 0) return; // still running
    s.finished = true;
    if (@as(isize, @bitCast(rc)) < 0) {
        s.failed = true; // wait error (e.g. no child)
    } else {
        const st: u32 = @bitCast(status);
        if (std.os.linux.W.IFEXITED(st)) {
            s.failed = std.os.linux.W.EXITSTATUS(st) != 0;
        } else {
            s.failed = true; // signaled or stopped
        }
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
        const f = sio.cwd().createFile(req_body_path, .{}) catch return 1;
        defer f.close();
        if (body_ptr) |p| {
            f.writeAll(p[0..body_len]) catch return 1;
        }
    }

    var args = std.array_list.Managed([]const u8).init(allocator);
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

    var child = sio.Child.init(args.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 1;

    const s = allocator.create(SseStream) catch {
        child.kill() catch {};
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

    const f = sio.cwd().openFile(s.body_path, .{}) catch return 0;
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
    sio.cwd().deleteFile(s.body_path) catch {};
    sio.cwd().deleteFile(s.header_path) catch {};
    sio.cwd().deleteFile(s.req_body_path) catch {};
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
                sio.io().sleep(.fromNanoseconds(backoffSecs(attempt) * std.time.ns_per_s), .awake) catch {};
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
            sio.io().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
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
            sio.io().sleep(.fromNanoseconds(wait_secs * std.time.ns_per_s), .awake) catch {};
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

    var text = std.array_list.Managed(u8).init(allocator);
    defer text.deinit();
    var calls = std.array_list.Managed(SseCall).init(allocator);
    defer {
        for (calls.items) |*c| {
            if (c.call_id.len > 0) allocator.free(c.call_id);
            if (c.name.len > 0) allocator.free(c.name);
            if (c.args.len > 0) allocator.free(c.args);
            if (c.key.len > 0) allocator.free(c.key);
        }
        calls.deinit();
    }
    var active = std.array_list.Managed(SseCall).init(allocator);
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

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    var processed_offset: usize = 0;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_stream = std.Io.File.stdout().writerStreaming(sio.io(), &stdout_buf);
    const stdout = &stdout_stream.interface;
    defer stdout_stream.interface.flush() catch {};

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
            sio.io().sleep(.fromNanoseconds(20 * std.time.ns_per_ms), .awake) catch {};
        }
    }

    // Finalize all active calls.
    sseFinalizeActive(allocator, &active, &calls) catch return 2;

    // Print newline after stream.
    stdout.writeAll("\n") catch {};

    // Build calls JSON first (so text isn't leaked on failure).
    var calls_json = std.array_list.Managed(u8).init(allocator);
    defer calls_json.deinit();
    calls_json.appendSlice("[") catch return 2;
    for (calls.items, 0..) |c, i| {
        if (i > 0) calls_json.appendSlice(",") catch return 2;
        calls_json.appendSlice("{\"call_id\":\"") catch return 2;
        sseJsonEscape(&calls_json, c.call_id) catch return 2;
        calls_json.appendSlice("\",\"name\":\"") catch return 2;
        sseJsonEscape(&calls_json, c.name) catch return 2;
        calls_json.appendSlice("\",\"args\":\"") catch return 2;
        sseJsonEscape(&calls_json, c.args) catch return 2;
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
    const f = sio.cwd().openFile(s.body_path, .{}) catch |err| {
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
    var n: usize = 0;
    while (n < data.len) {
        const m = try f.read(data[n..]);
        if (m == 0) break;
        n += m;
    }
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
    var parts = std.array_list.Managed([]const u8).init(allocator);
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
    text: *std.array_list.Managed(u8),
    calls: *std.array_list.Managed(SseCall),
    active: *std.array_list.Managed(SseCall),
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
fn sseFindActive(active: *std.array_list.Managed(SseCall), key: []const u8) ?*SseCall {
    for (active.items) |*ac| {
        if (std.mem.eql(u8, ac.key, key)) return ac;
    }
    return null;
}

// Move all active calls to the completed list (finalize).
fn sseFinalizeActive(allocator: std.mem.Allocator, active: *std.array_list.Managed(SseCall), calls: *std.array_list.Managed(SseCall)) !void {
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
    text: *std.array_list.Managed(u8),
    calls: *std.array_list.Managed(SseCall),
    active: *std.array_list.Managed(SseCall),
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
    text: *std.array_list.Managed(u8),
    calls: *std.array_list.Managed(SseCall),
    active: *std.array_list.Managed(SseCall),
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

fn sseJsonEscape(out: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(ch),
        }
    }
}

pub export fn sa_http_client_sse_turn_free(ptr: ?[*]u8, len: u64) void {
    if (ptr) |p| {
        const slice = p[0..len];
        std.heap.page_allocator.free(slice);
    }
}
