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
    try std.testing.expect(loopback.done.*);
    std.testing.allocator.destroy(loopback.server);
    std.testing.allocator.destroy(loopback.done);
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

    const gen = try std.process.Child.run(.{
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
    });
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
