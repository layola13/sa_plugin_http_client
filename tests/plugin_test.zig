const std = @import("std");
const plugin = @import("plugin");
const plugin_api = @import("plugin_api");

const CaptureStream = struct {
    buffer: *std.ArrayList(u8),
};

fn captureWriteAll(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    const stream_ctx: *CaptureStream = @ptrCast(@alignCast(ctx orelse return @intFromEnum(plugin_api.AbiStatus.failed)));
    stream_ctx.buffer.appendSlice(bytes[0..len]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

fn captureHostStream(ctx: *CaptureStream) plugin_api.HostStream {
    return .{ .ctx = ctx, .write_all = captureWriteAll };
}

fn dupeZArgs(allocator: std.mem.Allocator, argv: []const []const u8) ![][*:0]const u8 {
    var out = try allocator.alloc([*:0]const u8, argv.len);
    errdefer allocator.free(out);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |arg| allocator.free(std.mem.sliceTo(arg, 0));
    }
    for (argv, 0..) |arg, idx| {
        out[idx] = try allocator.dupeZ(u8, arg);
        copied += 1;
    }
    return out;
}

fn freeZArgs(allocator: std.mem.Allocator, argv: [][*:0]const u8) void {
    for (argv) |arg| allocator.free(std.mem.sliceTo(arg, 0));
    allocator.free(argv);
}

fn spawnLoopbackServer(allocator: std.mem.Allocator, body: []const u8) !struct {
    thread: std.Thread,
    server: *std.net.Server,
    done: *bool,
} {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try allocator.create(std.net.Server);
    server.* = try address.listen(.{ .reuse_address = true });

    const done_flag = try allocator.create(bool);
    done_flag.* = false;

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server, finished: *bool, response_body: []const u8) void {
            defer listen_server.deinit();

            var conn = listen_server.accept() catch return;
            defer conn.stream.close();

            var request_buffer: [4096]u8 = undefined;
            var http_server = std.http.Server.init(conn, &request_buffer);
            _ = http_server.receiveHead() catch return;

            var response_buf: [256]u8 = undefined;
            const response = std.fmt.bufPrint(
                &response_buf,
                "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
                .{ response_body.len, response_body },
            ) catch return;
            conn.stream.writeAll(response) catch return;
            finished.* = true;
        }
    }.run, .{ server, done_flag, body });

    return .{ .thread = thread, .server = server, .done = done_flag };
}

test "http client plugin abi maps missing get URL to cli diagnostic" {
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    var stdout_ctx = CaptureStream{ .buffer = &stdout_buf };
    var stderr_ctx = CaptureStream{ .buffer = &stderr_buf };

    const argv = try dupeZArgs(std.testing.allocator, &.{ "sa", "http-client", "get" });
    defer freeZArgs(std.testing.allocator, argv);

    var out_code: u8 = 255;
    const status = plugin.runHttpClientCommandAbi(
        &ctx,
        argv.ptr,
        argv.len,
        captureHostStream(&stdout_ctx),
        captureHostStream(&stderr_ctx),
        &out_code,
    );

    try std.testing.expectEqual(@intFromEnum(plugin_api.AbiStatus.ok), status);
    try std.testing.expectEqual(@as(u8, 1), out_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "error[SA-HTTP-CLIENT-CLI]: missing required HTTP client URL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "usage: sa http-client get"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, stderr_buf.items, 1, "PluginFailed"));
}

test "http client plugin exports runtime descriptor and loopback GET works" {
    const exported = &plugin.saasm_plugin_descriptor_v1;
    try std.testing.expectEqual(plugin_api.abi_version, exported.abi_version);
    try std.testing.expectEqualStrings("http-client", std.mem.span(exported.name));
    try std.testing.expectEqual(@as(usize, 1), exported.skills_len);
    try std.testing.expectEqualStrings("http client", exported.skills_ptr[0].name);
    try std.testing.expectEqualStrings("http-client get <url>", exported.skills_ptr[0].items[0]);

    const loopback = try spawnLoopbackServer(std.testing.allocator, "hello from loopback");
    var loopback_joined = false;
    defer {
        if (!loopback_joined) loopback.thread.join();
        std.testing.allocator.destroy(loopback.server);
        std.testing.allocator.destroy(loopback.done);
    }

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/hello", .{loopback.server.listen_address.getPort()});
    defer std.testing.allocator.free(url);

    const args = [_][]const u8{ "sa", "http-client", "get", url };
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const code = try plugin.runHttpClientCommand(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expectEqualStrings("status: 200\nhello from loopback\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    loopback.thread.join();
    loopback_joined = true;
    try std.testing.expect(loopback.done.*);
}

test "http client saasm api exposes response headers" {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try std.testing.allocator.create(std.net.Server);
    server.* = try address.listen(.{ .reuse_address = true });
    defer std.testing.allocator.destroy(server);

    const done_flag = try std.testing.allocator.create(bool);
    done_flag.* = false;
    defer std.testing.allocator.destroy(done_flag);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server, finished: *bool) void {
            defer listen_server.deinit();
            var conn = listen_server.accept() catch return;
            defer conn.stream.close();
            var request_buffer: [4096]u8 = undefined;
            var http_server = std.http.Server.init(conn, &request_buffer);
            const request = http_server.receiveHead() catch return;
            _ = request;
            conn.stream.writeAll(
                "HTTP/1.1 418 I'm a teapot\r\ncontent-type: application/json\r\nconnection: close\r\ncontent-length: 2\r\n\r\n{}",
            ) catch return;
            finished.* = true;
        }
    }.run, .{ server, done_flag });

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_new(0, &client));
    defer _ = plugin.sa_http_client_free(client);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/headers", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_new(client, 1, url.ptr, url.len, &req));
    defer _ = plugin.sa_http_client_req_free(req);

    var resp: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_send(req, &resp));
    defer _ = plugin.sa_http_client_resp_free(resp);

    try std.testing.expectEqual(@as(u16, 418), plugin.sa_http_client_resp_status(resp));

    const key = "content-type";
    var value_ptr: ?[*]const u8 = null;
    var value_len: u64 = 0;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_resp_get_header(resp, key.ptr, key.len, &value_ptr, &value_len));
    try std.testing.expectEqualStrings("application/json", (value_ptr orelse return error.NullHeader)[0..@intCast(value_len)]);

    var body_ptr: ?[*]const u8 = null;
    var body_len: u64 = 0;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_resp_body_slice(resp, &body_ptr, &body_len));
    try std.testing.expectEqualStrings("{}", (body_ptr orelse return error.NullBody)[0..@intCast(body_len)]);
    try std.testing.expectEqual(@as(u64, 2), plugin.sa_http_client_resp_body_len(resp));
    const direct_body_ptr = plugin.sa_http_client_resp_body_ptr(resp) orelse return error.NullBody;
    try std.testing.expectEqualStrings("{}", direct_body_ptr[0..@intCast(plugin.sa_http_client_resp_body_len(resp))]);

    thread.join();
    try std.testing.expect(done_flag.*);
}

test "http client saasm api builds joined upstream URL and OpenAI auth headers" {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try std.testing.allocator.create(std.net.Server);
    server.* = try address.listen(.{ .reuse_address = true });
    defer std.testing.allocator.destroy(server);

    const target_seen = try std.testing.allocator.create(bool);
    target_seen.* = false;
    defer std.testing.allocator.destroy(target_seen);
    const auth_seen = try std.testing.allocator.create(bool);
    auth_seen.* = false;
    defer std.testing.allocator.destroy(auth_seen);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server, saw_target: *bool, saw_auth: *bool) void {
            defer listen_server.deinit();
            var conn = listen_server.accept() catch return;
            defer conn.stream.close();

            var request_buffer: [4096]u8 = undefined;
            var http_server = std.http.Server.init(conn, &request_buffer);
            var request = http_server.receiveHead() catch return;
            saw_target.* = std.mem.eql(u8, request.head.target, "/openai/v1/models");

            var saw_authorization = false;
            var saw_x_api_key = false;
            var it = request.iterateHeaders();
            while (it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "authorization") and std.mem.eql(u8, header.value, "Bearer sk-test")) {
                    saw_authorization = true;
                }
                if (std.ascii.eqlIgnoreCase(header.name, "x-api-key") and std.mem.eql(u8, header.value, "sk-test")) {
                    saw_x_api_key = true;
                }
            }
            saw_auth.* = saw_authorization and saw_x_api_key;
            conn.stream.writeAll(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\ncontent-length: 11\r\n\r\n{\"ok\":true}",
            ) catch return;
        }
    }.run, .{ server, target_seen, auth_seen });

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_new(0, &client));
    defer _ = plugin.sa_http_client_free(client);

    const target = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/openai/v1", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(target);
    const path = "/v1/models";
    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_new_joined(client, 1, target.ptr, target.len, path.ptr, path.len, 1, &req));
    defer _ = plugin.sa_http_client_req_free(req);

    const api_key = "sk-test";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_add_openai_auth(req, api_key.ptr, api_key.len));

    var resp: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_send(req, &resp));
    defer _ = plugin.sa_http_client_resp_free(resp);
    try std.testing.expectEqual(@as(u16, 200), plugin.sa_http_client_resp_status(resp));

    thread.join();
    try std.testing.expect(target_seen.*);
    try std.testing.expect(auth_seen.*);
}

test "http client saasm async request poll and take response" {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try std.testing.allocator.create(std.net.Server);
    server.* = try address.listen(.{ .reuse_address = true });
    defer std.testing.allocator.destroy(server);

    const done_flag = try std.testing.allocator.create(bool);
    done_flag.* = false;
    defer std.testing.allocator.destroy(done_flag);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server, finished: *bool) void {
            defer listen_server.deinit();
            var conn = listen_server.accept() catch return;
            defer conn.stream.close();

            var request_buffer: [4096]u8 = undefined;
            var http_server = std.http.Server.init(conn, &request_buffer);
            const request = http_server.receiveHead() catch return;
            _ = request;

            std.time.sleep(50 * std.time.ns_per_ms);
            conn.stream.writeAll(
                "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nconnection: close\r\ncontent-length: 10\r\n\r\nasync body",
            ) catch return;
            finished.* = true;
        }
    }.run, .{ server, done_flag });

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_new(0, &client));
    defer _ = plugin.sa_http_client_free(client);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/async", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_new(client, 1, url.ptr, url.len, &req));

    var op: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_send_async(req, &op));
    defer _ = plugin.sa_http_client_async_free(op);

    // The async operation owns a request clone, so callers may release their handle.
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_free(req));

    var ready: u8 = 255;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_async_poll(op, &ready));
    try std.testing.expectEqual(@as(u8, 0), ready);

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_async_poll(op, &ready));
        if (ready == 1) break;
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(u8, 1), ready);

    var resp: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_async_take_response(op, &resp));
    defer _ = plugin.sa_http_client_resp_free(resp);
    try std.testing.expectEqual(@as(u16, 200), plugin.sa_http_client_resp_status(resp));

    var body_ptr: ?[*]const u8 = null;
    var body_len: u64 = 0;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_resp_body_slice(resp, &body_ptr, &body_len));
    try std.testing.expectEqualStrings("async body", (body_ptr orelse return error.NullBody)[0..@intCast(body_len)]);

    thread.join();
    try std.testing.expect(done_flag.*);
}

test "http client plugin stream command forwards chunked SSE body incrementally" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try std.testing.allocator.create(std.net.Server);
    server.* = try address.listen(.{ .reuse_address = true });

    const done_flag = try std.testing.allocator.create(bool);
    done_flag.* = false;

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server, finished: *bool) void {
            defer listen_server.deinit();

            var conn = listen_server.accept() catch return;
            defer conn.stream.close();

            var request_buffer: [4096]u8 = undefined;
            var http_server = std.http.Server.init(conn, &request_buffer);
            const request = http_server.receiveHead() catch return;

            const chunks = [_][]const u8{
                "data: first\n\n",
                "data: second\n\n",
            };
            var response_buf: [256]u8 = undefined;
            var head = std.ArrayListUnmanaged(u8).initBuffer(&response_buf);
            head.fixedWriter().print("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n", .{}) catch return;
            conn.stream.writeAll(head.items) catch return;
            for (chunks, 0..) |chunk, idx| {
                var chunk_header: [32]u8 = undefined;
                const header = std.fmt.bufPrint(&chunk_header, "{x}\r\n", .{chunk.len}) catch return;
                conn.stream.writeAll(header) catch return;
                conn.stream.writeAll(chunk) catch return;
                conn.stream.writeAll("\r\n") catch return;
                if (idx == 0) std.time.sleep(20 * std.time.ns_per_ms);
            }
            conn.stream.writeAll("0\r\n\r\n") catch return;
            _ = request;
            finished.* = true;
        }
    }.run, .{ server, done_flag });

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/events", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);

    const args = [_][]const u8{ "sa", "http-client", "stream", url };
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const code = try plugin.runHttpClientCommand(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());
    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expectEqualStrings("data: first\n\ndata: second\n\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    thread.join();
    try std.testing.expect(done_flag.*);
    std.testing.allocator.destroy(server);
    std.testing.allocator.destroy(done_flag);
}

test "http client plugin custom CA bundle path is accepted by parser" {
    const parsed = try plugin.parseRequestArgs(std.testing.allocator, &.{ "https://example.com", "--ca-bundle", "server.crt" }, false);
    try std.testing.expectEqualStrings("https://example.com", parsed.url);
    try std.testing.expectEqualStrings("server.crt", parsed.ca_bundle_path.?);
}

test "http client plugin post command forwards headers and body" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try std.testing.allocator.create(std.net.Server);
    server.* = try address.listen(.{ .reuse_address = true });
    defer std.testing.allocator.destroy(server);

    const seen_body = try std.testing.allocator.create(bool);
    seen_body.* = false;
    defer std.testing.allocator.destroy(seen_body);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server, finished: *bool) void {
            defer listen_server.deinit();

            var conn = listen_server.accept() catch return;
            defer conn.stream.close();

            var request_buffer: [4096]u8 = undefined;
            var http_server = std.http.Server.init(conn, &request_buffer);
            var request = http_server.receiveHead() catch return;

            var header_seen = false;
            var header_it = request.iterateHeaders();
            while (header_it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "content-type") and std.mem.eql(u8, header.value, "text/plain")) {
                    header_seen = true;
                    break;
                }
            }
            if (!header_seen) return;

            var body_buf: [128]u8 = undefined;
            const reader = request.reader() catch return;
            const n = reader.readAll(&body_buf) catch return;
            if (n != "payload body".len) return;
            if (!std.mem.eql(u8, body_buf[0..n], "payload body")) return;

            const response = "ok";
            request.respond(response, .{ .status = .ok }) catch return;
            finished.* = true;
        }
    }.run, .{ server, seen_body });

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/submit", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);

    const args = [_][]const u8{
        "sa",
        "http-client",
        "post",
        "--header",
        "content-type: text/plain",
        url,
        "payload body",
    };
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const code = try plugin.runHttpClientCommand(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any());

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "status: 200"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    thread.join();
    try std.testing.expect(seen_body.*);
}

test "http client plugin https ca bundle works against a local self-signed server" {
    if (std.http.Client.disable_tls) return error.SkipZigTest;

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const cert_conf =
        \\[req]
        \\distinguished_name = req_distinguished_name
        \\x509_extensions = v3_req
        \\prompt = no
        \\
        \\[req_distinguished_name]
        \\CN = localhost
        \\
        \\[v3_req]
        \\subjectAltName = @alt_names
        \\
        \\[alt_names]
        \\DNS.1 = localhost
        \\IP.1 = 127.0.0.1
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = "cert.cnf", .data = cert_conf });

    const gen = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-days",
            "1",
            "-nodes",
            "-keyout",
            "server.key",
            "-out",
            "server.crt",
            "-config",
            "cert.cnf",
            "-extensions",
            "v3_req",
        },
        .cwd = ".",
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(gen.stdout);
    defer std.testing.allocator.free(gen.stderr);
    switch (gen.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    var server_child = std.process.Child.init(&.{
        "openssl",
        "s_server",
        "-accept",
        "18443",
        "-cert",
        "server.crt",
        "-key",
        "server.key",
        "-www",
        "-naccept",
        "1",
    }, std.testing.allocator);
    server_child.cwd = ".";
    server_child.stdin_behavior = .Ignore;
    server_child.stdout_behavior = .Ignore;
    server_child.stderr_behavior = .Ignore;
    try server_child.spawn();

    const url = "https://localhost:18443/";
    const ca_bundle = "server.crt";
    const args = [_][]const u8{ "sa", "http-client", "get", "--ca-bundle", ca_bundle, url };
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };

    var attempt: usize = 0;
    var result_code: ?u8 = null;
    while (attempt < 50) : (attempt += 1) {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();
        const code = plugin.runHttpClientCommand(&ctx, args[0..], stdout_buf.writer().any(), stderr_buf.writer().any()) catch null;
        if (code) |exit_code| {
            if (exit_code == 0) {
                result_code = exit_code;
                break;
            }
        }
        std.time.sleep(20 * std.time.ns_per_ms);
    }

    const wait_result = try server_child.wait();
    if (result_code == null) {
        std.debug.print("tls stdout:\n{s}\ntls stderr:\n{s}\n", .{ stdout_buf.items, stderr_buf.items });
    }
    try std.testing.expectEqual(@as(?u8, 0), result_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "status: 200\n"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    _ = wait_result;
}

fn spawnV2HttpServer(delay_ms: u64, status_line: []const u8, body: []const u8) !struct {
    thread: std.Thread,
    server: *std.net.Server,
} {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try std.testing.allocator.create(std.net.Server);
    errdefer std.testing.allocator.destroy(server);
    server.* = try address.listen(.{ .reuse_address = true });
    errdefer server.deinit();
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server, wait_ms: u64, response_status: []const u8, response_body: []const u8) void {
            defer listen_server.deinit();
            var connection = listen_server.accept() catch return;
            defer connection.stream.close();
            var request_buffer: [4096]u8 = undefined;
            var http_server = std.http.Server.init(connection, &request_buffer);
            _ = http_server.receiveHead() catch return;
            if (wait_ms != 0) std.Thread.sleep(wait_ms * std.time.ns_per_ms);
            var response_buffer: [512]u8 = undefined;
            const response = std.fmt.bufPrint(
                &response_buffer,
                "HTTP/1.1 {s}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
                .{ response_status, response_body.len, response_body },
            ) catch return;
            connection.stream.writeAll(response) catch return;
        }
    }.run, .{ server, delay_ms, status_line, body });
    return .{ .thread = thread, .server = server };
}

test "http client v2 status values and invalid arguments are stable" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(plugin.NetworkStatus.ok));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(plugin.NetworkStatus.would_block));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(plugin.NetworkStatus.closed));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(plugin.NetworkStatus.timeout));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(plugin.NetworkStatus.too_large));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(plugin.NetworkStatus.invalid));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(plugin.NetworkStatus.io_error));

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_new_v2(0, null, 0, &client));
    defer _ = plugin.sa_http_client_free(client);

    var request: ?*anyopaque = @ptrFromInt(1);
    const url = "http://127.0.0.1/";
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.invalid), plugin.sa_http_client_req_new_v2(client, 99, url.ptr, url.len, &request));
    try std.testing.expectEqual(@as(?*anyopaque, null), request);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.invalid), plugin.sa_http_client_req_set_max_response_bytes_v2(null, 0));
}

test "http client v2 enforces request deadline and response limit" {
    const delayed = try spawnV2HttpServer(80, "200 OK", "late");
    const delayed_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/timeout", .{delayed.server.listen_address.getPort()});
    defer std.testing.allocator.free(delayed_url);

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_new_v2(0, null, 0, &client));
    defer _ = plugin.sa_http_client_free(client);
    var request: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_req_new_v2(client, 1, delayed_url.ptr, delayed_url.len, &request));
    defer _ = plugin.sa_http_client_req_free(request);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_req_set_timeout_v2(request, 20));
    var response: ?*anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.timeout), plugin.sa_http_client_req_send_v2(request, &response));
    try std.testing.expectEqual(@as(?*anyopaque, null), response);
    delayed.thread.join();
    std.testing.allocator.destroy(delayed.server);

    const oversized = try spawnV2HttpServer(0, "200 OK", "0123456789abcdef");
    const oversized_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/large", .{oversized.server.listen_address.getPort()});
    defer std.testing.allocator.free(oversized_url);
    var limited_request: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_req_new_v2(client, 1, oversized_url.ptr, oversized_url.len, &limited_request));
    defer _ = plugin.sa_http_client_req_free(limited_request);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_req_set_max_response_bytes_v2(limited_request, 8));
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.too_large), plugin.sa_http_client_req_send_v2(limited_request, &response));
    try std.testing.expectEqual(@as(?*anyopaque, null), response);
    oversized.thread.join();
    std.testing.allocator.destroy(oversized.server);
}

test "http client v2 async cancel wakes IO and retains client lifetime" {
    const delayed = try spawnV2HttpServer(200, "200 OK", "cancelled");
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/cancel", .{delayed.server.listen_address.getPort()});
    defer std.testing.allocator.free(url);

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_new_v2(0, null, 0, &client));
    var request: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_req_new_v2(client, 1, url.ptr, url.len, &request));
    var operation: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_req_send_async_v2(request, &operation));

    // The operation owns a retained request/client pair.
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_req_free(request));
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_free(client));
    std.Thread.sleep(20 * std.time.ns_per_ms);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_async_cancel_v2(operation));
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_async_cancel_v2(operation));

    var ready: u8 = 0;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.closed), plugin.sa_http_client_async_poll_v2(operation, 1000, &ready));
    try std.testing.expectEqual(@as(u8, 1), ready);
    var response: ?*anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.closed), plugin.sa_http_client_async_take_response_v2(operation, &response));
    try std.testing.expectEqual(@as(?*anyopaque, null), response);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_async_free_v2(operation));

    delayed.thread.join();
    std.testing.allocator.destroy(delayed.server);
}

test "http client v2 leaves redirects to the caller" {
    const redirect = try spawnV2HttpServer(0, "302 Found\r\nlocation: http://127.0.0.1:9/not-followed", "");
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/redirect", .{redirect.server.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_new_v2(0, null, 0, &client));
    defer _ = plugin.sa_http_client_free(client);
    var request: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_req_new_v2(client, 1, url.ptr, url.len, &request));
    defer _ = plugin.sa_http_client_req_free(request);
    var response: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_req_send_v2(request, &response));
    defer _ = plugin.sa_http_client_resp_free(response);
    try std.testing.expectEqual(@as(u16, 302), plugin.sa_http_client_resp_status(response));
    redirect.thread.join();
    std.testing.allocator.destroy(redirect.server);
}

fn readExactTest(stream: std.net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const amount = try stream.read(buffer[offset..]);
        if (amount == 0) return error.EndOfStream;
        offset += amount;
    }
}

fn websocketAcceptTest(key: []const u8, out: *[28]u8) []const u8 {
    var digest: [20]u8 = undefined;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    sha1.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

fn websocketServerHandshakeStreams(reader: anytype, writer: anytype, expected_target: []const u8) !void {
    var request_buffer: [8192]u8 = undefined;
    var request_len: usize = 0;
    while (std.mem.indexOf(u8, request_buffer[0..request_len], "\r\n\r\n") == null) {
        if (request_len == request_buffer.len) return error.HttpHeadersOversize;
        const amount = try reader.read(request_buffer[request_len..]);
        if (amount == 0) return error.EndOfStream;
        request_len += amount;
    }
    const request = request_buffer[0..request_len];
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    const first_line = lines.next() orelse return error.InvalidRequest;
    var first_parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = first_parts.next() orelse return error.InvalidRequest;
    const target = first_parts.next() orelse return error.InvalidRequest;
    if (!std.mem.eql(u8, target, expected_target)) return error.InvalidRequest;

    var websocket_key: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
            websocket_key = std.mem.trim(u8, line[separator + 1 ..], " \t");
        }
    }
    const key = websocket_key orelse return error.InvalidRequest;
    var accept_buffer: [28]u8 = undefined;
    const accept = websocketAcceptTest(key, &accept_buffer);
    var response_buffer: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buffer,
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: {s}\r\n\r\n",
        .{accept},
    );
    try writer.writeAll(response);
}

fn websocketServerHandshake(stream: std.net.Stream, expected_target: []const u8) !void {
    return websocketServerHandshakeStreams(stream, stream, expected_target);
}

fn writeServerWebSocketFrame(stream: anytype, fin: bool, opcode: u8, payload: []const u8) !void {
    if (payload.len > 125) return error.TestPayloadTooLarge;
    var frame: [127]u8 = undefined;
    frame[0] = (if (fin) @as(u8, 0x80) else 0) | opcode;
    frame[1] = @intCast(payload.len);
    @memcpy(frame[2 .. 2 + payload.len], payload);
    try stream.writeAll(frame[0 .. 2 + payload.len]);
}

fn readClientWebSocketFrame(stream: std.net.Stream, out_opcode: *u8, payload_buffer: []u8) ![]const u8 {
    var header: [2]u8 = undefined;
    try readExactTest(stream, &header);
    if (header[1] & 0x80 == 0) return error.UnmaskedClientFrame;
    var payload_len: u64 = header[1] & 0x7f;
    if (payload_len == 126) {
        var extended: [2]u8 = undefined;
        try readExactTest(stream, &extended);
        payload_len = std.mem.readInt(u16, &extended, .big);
    } else if (payload_len == 127) {
        var extended: [8]u8 = undefined;
        try readExactTest(stream, &extended);
        payload_len = std.mem.readInt(u64, &extended, .big);
    }
    if (payload_len > payload_buffer.len) return error.TestPayloadTooLarge;
    var mask: [4]u8 = undefined;
    try readExactTest(stream, &mask);
    const payload = payload_buffer[0..@intCast(payload_len)];
    try readExactTest(stream, payload);
    for (payload, 0..) |*byte, index| byte.* ^= mask[index & 3];
    out_opcode.* = header[0] & 0x0f;
    return payload;
}

const WebSocketServerResult = struct {
    pong_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    text_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    close_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

test "http client v2 TCP websocket polls fragments pongs masks and closes" {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try std.testing.allocator.create(std.net.Server);
    server.* = try address.listen(.{ .reuse_address = true });
    defer std.testing.allocator.destroy(server);
    var result = WebSocketServerResult{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server, server_result: *WebSocketServerResult) void {
            defer listen_server.deinit();
            var connection = listen_server.accept() catch return;
            defer connection.stream.close();
            websocketServerHandshake(connection.stream, "/events?client=codex-max") catch return;
            std.Thread.sleep(60 * std.time.ns_per_ms);
            writeServerWebSocketFrame(connection.stream, true, 9, "p") catch return;
            writeServerWebSocketFrame(connection.stream, false, 1, "hel") catch return;
            writeServerWebSocketFrame(connection.stream, true, 0, "lo") catch return;

            var payload_buffer: [128]u8 = undefined;
            var opcode: u8 = 0;
            const pong = readClientWebSocketFrame(connection.stream, &opcode, &payload_buffer) catch return;
            server_result.pong_seen.store(opcode == 10 and std.mem.eql(u8, pong, "p"), .release);
            const text = readClientWebSocketFrame(connection.stream, &opcode, &payload_buffer) catch return;
            server_result.text_seen.store(opcode == 1 and std.mem.eql(u8, text, "client"), .release);
            const close_payload = readClientWebSocketFrame(connection.stream, &opcode, &payload_buffer) catch return;
            server_result.close_seen.store(opcode == 8 and close_payload.len >= 2, .release);
            writeServerWebSocketFrame(connection.stream, true, 8, close_payload) catch return;
        }
    }.run, .{ server, &result });

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_new_v2(0, null, 0, &client));
    const url = try std.fmt.allocPrint(std.testing.allocator, "ws://127.0.0.1:{d}/events?client=codex-max", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var websocket: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_websocket_connect_v2(client, url.ptr, url.len, 1000, &websocket));
    // The WebSocket retains the client and remains valid after owner release.
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_client_free(client));

    var events: u32 = 99;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.would_block), plugin.sa_http_websocket_poll_v2(websocket, plugin.PollEvent.readable, 0, &events));
    try std.testing.expectEqual(@as(u32, 0), events);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_websocket_poll_v2(websocket, plugin.PollEvent.readable, 1000, &events));
    try std.testing.expect(events & plugin.PollEvent.readable != 0);

    var opcode: u8 = 0;
    var message_ptr: ?[*]const u8 = null;
    var message_len: u64 = 0;
    var read_status = plugin.sa_http_websocket_read_v2(websocket, 64 * 1024, &opcode, &message_ptr, &message_len);
    var attempts: usize = 0;
    while (read_status == @intFromEnum(plugin.NetworkStatus.would_block) and attempts < 20) : (attempts += 1) {
        _ = plugin.sa_http_websocket_poll_v2(websocket, plugin.PollEvent.readable, 100, &events);
        read_status = plugin.sa_http_websocket_read_v2(websocket, 64 * 1024, &opcode, &message_ptr, &message_len);
    }
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), read_status);
    try std.testing.expectEqual(@as(u8, 1), opcode);
    try std.testing.expectEqualStrings("hello", (message_ptr orelse return error.NullWebSocketMessage)[0..@intCast(message_len)]);

    const outbound = "client";
    var written: u64 = 99;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_websocket_write_v2(websocket, 1, outbound.ptr, outbound.len, &written));
    try std.testing.expectEqual(@as(u64, outbound.len), written);
    const reason = "done";
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_websocket_close_v2(websocket, 1000, reason.ptr, reason.len));

    _ = plugin.sa_http_websocket_poll_v2(websocket, plugin.PollEvent.readable, 1000, &events);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.closed), plugin.sa_http_websocket_read_v2(websocket, 64 * 1024, &opcode, &message_ptr, &message_len));
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_websocket_free_v2(websocket));
    thread.join();
    try std.testing.expect(result.pong_seen.load(.acquire));
    try std.testing.expect(result.text_seen.load(.acquire));
    try std.testing.expect(result.close_seen.load(.acquire));
}

test "http client v2 Unix websocket uses socket endpoint and logical URL" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const temporary_path = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(temporary_path);
    const socket_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "codex-max.sock" });
    defer std.testing.allocator.free(socket_path);

    const address = try std.net.Address.initUnix(socket_path);
    const server = try std.testing.allocator.create(std.net.Server);
    server.* = try address.listen(.{});
    defer std.testing.allocator.destroy(server);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server) void {
            defer listen_server.deinit();
            var connection = listen_server.accept() catch return;
            defer connection.stream.close();
            websocketServerHandshake(connection.stream, "/daemon?engine=official") catch return;
            writeServerWebSocketFrame(connection.stream, true, 1, "unix-ok") catch return;
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }.run, .{server});

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_new_v2(0, null, 0, &client));
    defer _ = plugin.sa_http_client_free(client);
    const logical_url = "ws://localhost/daemon?engine=official";
    var websocket: ?*anyopaque = null;
    try std.testing.expectEqual(
        @intFromEnum(plugin.NetworkStatus.ok),
        plugin.sa_http_client_websocket_connect_unix_v2(client, socket_path.ptr, socket_path.len, logical_url.ptr, logical_url.len, 1000, &websocket),
    );
    defer _ = plugin.sa_http_websocket_free_v2(websocket);

    var events: u32 = 0;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_websocket_poll_v2(websocket, plugin.PollEvent.readable, 1000, &events));
    var opcode: u8 = 0;
    var message_ptr: ?[*]const u8 = null;
    var message_len: u64 = 0;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_websocket_read_v2(websocket, 64 * 1024, &opcode, &message_ptr, &message_len));
    try std.testing.expectEqual(@as(u8, 1), opcode);
    try std.testing.expectEqualStrings("unix-ok", (message_ptr orelse return error.NullWebSocketMessage)[0..@intCast(message_len)]);

    thread.join();
}

test "http client v2 websocket rejects an oversized frame before allocation" {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try std.testing.allocator.create(std.net.Server);
    server.* = try address.listen(.{ .reuse_address = true });
    defer std.testing.allocator.destroy(server);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(listen_server: *std.net.Server) void {
            defer listen_server.deinit();
            var connection = listen_server.accept() catch return;
            defer connection.stream.close();
            websocketServerHandshake(connection.stream, "/oversized") catch return;
            const oversized_header = [_]u8{ 0x82, 0x7f, 0, 0, 0, 0, 1, 0, 0, 1 };
            connection.stream.writeAll(&oversized_header) catch return;
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }.run, .{server});

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_new_v2(0, null, 0, &client));
    defer _ = plugin.sa_http_client_free(client);
    const url = try std.fmt.allocPrint(std.testing.allocator, "ws://127.0.0.1:{d}/oversized", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var websocket: ?*anyopaque = null;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_client_websocket_connect_v2(client, url.ptr, url.len, 1000, &websocket));
    defer _ = plugin.sa_http_websocket_free_v2(websocket);
    var events: u32 = 0;
    _ = plugin.sa_http_websocket_poll_v2(websocket, plugin.PollEvent.readable, 1000, &events);
    var opcode: u8 = 0;
    var message_ptr: ?[*]const u8 = null;
    var message_len: u64 = 0;
    try std.testing.expectEqual(
        @intFromEnum(plugin.NetworkStatus.too_large),
        plugin.sa_http_websocket_read_v2(websocket, plugin.max_v2_message_bytes, &opcode, &message_ptr, &message_len),
    );
    try std.testing.expectEqual(@as(?[*]const u8, null), message_ptr);
    thread.join();
}

test "http client v2 TLS websocket preserves TLS state after upgrade" {
    if (std.http.Client.disable_tls) return error.SkipZigTest;

    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const temporary_path = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(temporary_path);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "cert.cnf" });
    defer std.testing.allocator.free(config_path);
    const certificate_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "server.crt" });
    defer std.testing.allocator.free(certificate_path);
    const key_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "server.key" });
    defer std.testing.allocator.free(key_path);
    const certificate_config =
        \\[req]
        \\distinguished_name = req_distinguished_name
        \\x509_extensions = v3_req
        \\prompt = no
        \\
        \\[req_distinguished_name]
        \\CN = localhost
        \\
        \\[v3_req]
        \\subjectAltName = @alt_names
        \\
        \\[alt_names]
        \\DNS.1 = localhost
        \\IP.1 = 127.0.0.1
    ;
    try temporary.dir.writeFile(.{ .sub_path = "cert.cnf", .data = certificate_config });
    const generate = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-days",
            "1",
            "-nodes",
            "-keyout",
            key_path,
            "-out",
            certificate_path,
            "-config",
            config_path,
            "-extensions",
            "v3_req",
        },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(generate.stdout);
    defer std.testing.allocator.free(generate.stderr);
    switch (generate.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var port_reservation = try address.listen(.{ .reuse_address = true });
    const port = port_reservation.listen_address.getPort();
    port_reservation.deinit();
    const port_text = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{port});
    defer std.testing.allocator.free(port_text);

    var server_child = std.process.Child.init(&.{
        "openssl",
        "s_server",
        "-accept",
        port_text,
        "-cert",
        certificate_path,
        "-key",
        key_path,
        "-quiet",
        "-naccept",
        "1",
    }, std.testing.allocator);
    server_child.stdin_behavior = .Pipe;
    server_child.stdout_behavior = .Pipe;
    server_child.stderr_behavior = .Ignore;
    try server_child.spawn();
    const server_stdin = server_child.stdin orelse return error.MissingServerPipe;
    const server_stdout = server_child.stdout orelse return error.MissingServerPipe;
    server_child.stdin = null;
    server_child.stdout = null;

    const responder = try std.Thread.spawn(.{}, struct {
        fn run(reader: std.fs.File, writer: std.fs.File) void {
            defer reader.close();
            defer writer.close();
            websocketServerHandshakeStreams(reader, writer, "/tls") catch return;
            writeServerWebSocketFrame(writer, true, 1, "tls-ok") catch return;
        }
    }.run, .{ server_stdout, server_stdin });
    var server_reaped = false;
    defer {
        if (!server_reaped) _ = server_child.kill() catch {};
        responder.join();
    }

    var client: ?*anyopaque = null;
    try std.testing.expectEqual(
        @intFromEnum(plugin.NetworkStatus.ok),
        plugin.sa_http_client_new_v2(1, certificate_path.ptr, certificate_path.len, &client),
    );
    defer _ = plugin.sa_http_client_free(client);
    const url = try std.fmt.allocPrint(std.testing.allocator, "wss://localhost:{d}/tls", .{port});
    defer std.testing.allocator.free(url);
    var websocket: ?*anyopaque = null;
    defer {
        if (websocket) |value| _ = plugin.sa_http_websocket_free_v2(value);
    }
    var connect_status: u32 = @intFromEnum(plugin.NetworkStatus.io_error);
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        connect_status = plugin.sa_http_client_websocket_connect_v2(client, url.ptr, url.len, 1000, &websocket);
        if (connect_status == @intFromEnum(plugin.NetworkStatus.ok)) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), connect_status);

    var events: u32 = 0;
    _ = plugin.sa_http_websocket_poll_v2(websocket, plugin.PollEvent.readable, 1000, &events);
    var opcode: u8 = 0;
    var message_ptr: ?[*]const u8 = null;
    var message_len: u64 = 0;
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_websocket_read_v2(websocket, 64 * 1024, &opcode, &message_ptr, &message_len));
    try std.testing.expectEqual(@as(u8, 1), opcode);
    try std.testing.expectEqualStrings("tls-ok", (message_ptr orelse return error.NullWebSocketMessage)[0..@intCast(message_len)]);
    try std.testing.expectEqual(@intFromEnum(plugin.NetworkStatus.ok), plugin.sa_http_websocket_free_v2(websocket));
    websocket = null;

    _ = try server_child.wait();
    server_reaped = true;
}
