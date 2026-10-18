const std = @import("std");
const plugin_api = @import("plugin_api");
const plugin_helpers = @import("plugin_helpers.zig");
const sio = @import("sio");
const _http_api_v1 = @import("http_saasm_api.zig");
const _http_api_v2 = @import("http_v2_api.zig");
// NOTE(Zig 0.17): force emission of the api modules' `export fn` symbols
// (plain `pub const` aliases alone are pruned, breaking `sa plugin install`
// ABI verification).
comptime {
    _ = _http_api_v1;
    _ = _http_api_v2;
}
// NOTE(Zig 0.17): `usingnamespace` was removed; explicit re-exports preserve plugin.* ABI.
pub const SaHttpClientHandle = _http_api_v1.SaHttpClientHandle;
pub const SaHttpRequestHandle = _http_api_v1.SaHttpRequestHandle;
pub const SaHttpResponseHandle = _http_api_v1.SaHttpResponseHandle;
pub const SaHttpBodyReaderHandle = _http_api_v1.SaHttpBodyReaderHandle;
pub const HttpMethod = _http_api_v1.HttpMethod;
pub const HttpClientConfig = _http_api_v1.HttpClientConfig;
pub const HttpRequestConfig = _http_api_v1.HttpRequestConfig;
pub const HttpClient = _http_api_v1.HttpClient;
pub const HttpRequest = _http_api_v1.HttpRequest;
pub const HttpResponse = _http_api_v1.HttpResponse;
pub const HttpBodyReader = _http_api_v1.HttpBodyReader;
pub const HttpRequestAsyncOp = _http_api_v1.HttpRequestAsyncOp;
pub const sa_http_client_new = _http_api_v1.sa_http_client_new;
pub const sa_http_client_req_new = _http_api_v1.sa_http_client_req_new;
pub const sa_http_client_req_new_joined = _http_api_v1.sa_http_client_req_new_joined;
pub const sa_http_client_req_add_header = _http_api_v1.sa_http_client_req_add_header;
pub const sa_http_client_req_add_openai_auth = _http_api_v1.sa_http_client_req_add_openai_auth;
pub const sa_http_client_req_set_body = _http_api_v1.sa_http_client_req_set_body;
pub const sa_http_client_req_send = _http_api_v1.sa_http_client_req_send;
pub const sa_http_client_req_send_async = _http_api_v1.sa_http_client_req_send_async;
pub const sa_http_client_async_poll = _http_api_v1.sa_http_client_async_poll;
pub const sa_http_client_async_take_response = _http_api_v1.sa_http_client_async_take_response;
pub const sa_http_client_async_free = _http_api_v1.sa_http_client_async_free;
pub const sa_http_client_resp_status = _http_api_v1.sa_http_client_resp_status;
pub const sa_http_client_resp_get_header = _http_api_v1.sa_http_client_resp_get_header;
pub const sa_http_client_resp_body_slice = _http_api_v1.sa_http_client_resp_body_slice;
pub const sa_http_client_resp_body_ptr = _http_api_v1.sa_http_client_resp_body_ptr;
pub const sa_http_client_resp_body_len = _http_api_v1.sa_http_client_resp_body_len;
pub const sa_http_client_resp_body_reader = _http_api_v1.sa_http_client_resp_body_reader;
pub const sa_http_client_resp_read_chunk = _http_api_v1.sa_http_client_resp_read_chunk;
pub const sa_http_client_resp_free = _http_api_v1.sa_http_client_resp_free;
pub const sa_http_client_body_reader_free = _http_api_v1.sa_http_client_body_reader_free;
pub const sa_http_client_free = _http_api_v1.sa_http_client_free;
pub const sa_http_client_req_free = _http_api_v1.sa_http_client_req_free;
pub const sa_http_websocket_read = _http_api_v1.sa_http_websocket_read;
pub const sa_http_websocket_write = _http_api_v1.sa_http_websocket_write;
pub const sa_http_websocket_free = _http_api_v1.sa_http_websocket_free;
pub const sa_http_client_websocket_connect = _http_api_v1.sa_http_client_websocket_connect;
pub const sa_http_client_sse_post = _http_api_v1.sa_http_client_sse_post;
pub const sa_http_client_sse_read = _http_api_v1.sa_http_client_sse_read;
pub const sa_http_client_sse_poll = _http_api_v1.sa_http_client_sse_poll;
pub const sa_http_client_sse_status = _http_api_v1.sa_http_client_sse_status;
pub const sa_http_client_sse_free = _http_api_v1.sa_http_client_sse_free;
pub const sa_http_client_sse_turn = _http_api_v1.sa_http_client_sse_turn;
pub const sa_http_client_sse_turn_free = _http_api_v1.sa_http_client_sse_turn_free;
pub const max_v2_message_bytes = _http_api_v2.max_v2_message_bytes;
pub const default_v2_response_bytes = _http_api_v2.default_v2_response_bytes;
pub const NetworkStatus = _http_api_v2.NetworkStatus;
pub const PollEvent = _http_api_v2.PollEvent;
pub const sa_http_client_new_v2 = _http_api_v2.sa_http_client_new_v2;
pub const sa_http_client_req_new_v2 = _http_api_v2.sa_http_client_req_new_v2;
pub const sa_http_client_req_add_header_v2 = _http_api_v2.sa_http_client_req_add_header_v2;
pub const sa_http_client_req_set_body_v2 = _http_api_v2.sa_http_client_req_set_body_v2;
pub const sa_http_client_req_set_timeout_v2 = _http_api_v2.sa_http_client_req_set_timeout_v2;
pub const sa_http_client_req_set_max_response_bytes_v2 = _http_api_v2.sa_http_client_req_set_max_response_bytes_v2;
pub const sa_http_client_req_send_v2 = _http_api_v2.sa_http_client_req_send_v2;
pub const sa_http_client_req_send_async_v2 = _http_api_v2.sa_http_client_req_send_async_v2;
pub const sa_http_client_async_poll_v2 = _http_api_v2.sa_http_client_async_poll_v2;
pub const sa_http_client_async_take_response_v2 = _http_api_v2.sa_http_client_async_take_response_v2;
pub const sa_http_client_async_cancel_v2 = _http_api_v2.sa_http_client_async_cancel_v2;
pub const sa_http_client_async_free_v2 = _http_api_v2.sa_http_client_async_free_v2;
pub const sa_http_client_websocket_connect_v2 = _http_api_v2.sa_http_client_websocket_connect_v2;
pub const sa_http_client_websocket_connect_unix_v2 = _http_api_v2.sa_http_client_websocket_connect_unix_v2;
pub const sa_http_client_req_websocket_connect_v2 = _http_api_v2.sa_http_client_req_websocket_connect_v2;
pub const sa_http_client_req_websocket_connect_unix_v2 = _http_api_v2.sa_http_client_req_websocket_connect_unix_v2;
pub const sa_http_websocket_poll_v2 = _http_api_v2.sa_http_websocket_poll_v2;
pub const sa_http_websocket_read_v2 = _http_api_v2.sa_http_websocket_read_v2;
pub const sa_http_websocket_write_v2 = _http_api_v2.sa_http_websocket_write_v2;
pub const sa_http_websocket_close_v2 = _http_api_v2.sa_http_websocket_close_v2;
pub const sa_http_websocket_free_v2 = _http_api_v2.sa_http_websocket_free_v2;

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "http client",
        .summary = "Outgoing HTTP and HTTPS requests for plugins and HubProxy",
        .items = &.{
            "http-client get <url>",
            "http-client post [--header name:value] <url> <body>",
            "http-client get --ca-bundle <path> <url>",
            "http-client stream <url>",
            "http-client stream --ca-bundle <path> <url>",
            "custom request headers with --header name:value",
            "loopback GET and body retrieval",
            "chunked SSE body streaming",
            "custom CA bundle loading",
            "v2 request deadlines, response limits, and async cancellation",
            "TCP, TLS, and Unix-domain WebSocket transports",
            "pollable WebSocket reads and writes with stable network statuses",
            "runtime descriptor and skills metadata",
        },
    },
};

const ClientArgs = struct {
    url: []const u8,
    ca_bundle_path: ?[]const u8 = null,
};

const RequestOptions = struct {
    method: std.http.Method = .GET,
    url: []const u8,
    ca_bundle_path: ?[]const u8 = null,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
};

const RequestArgs = struct {
    url: []const u8,
    ca_bundle_path: ?[]const u8 = null,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
};

pub fn parseRequestArgs(allocator: std.mem.Allocator, args: []const []const u8, allow_body: bool) !RequestArgs {
    var url: ?[]const u8 = null;
    var ca_bundle_path: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var header_list = std.array_list.Managed(std.http.Header).init(allocator);
    defer header_list.deinit();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--ca-bundle")) {
            if (i + 1 >= args.len) return error.MissingSourcePath;
            ca_bundle_path = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--header")) {
            if (i + 1 >= args.len) return error.MissingSourcePath;
            const raw = args[i + 1];
            const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return error.UnexpectedArgument;
            const name = std.mem.trim(u8, raw[0..colon], " \t");
            const value = std.mem.trim(u8, raw[colon + 1 ..], " \t");
            if (name.len == 0) return error.UnexpectedArgument;
            try header_list.append(.{ .name = name, .value = value });
            i += 1;
            continue;
        }
        if (url == null) {
            url = arg;
            continue;
        }
        if (allow_body and body == null) {
            body = arg;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return .{
        .url = url orelse return error.MissingSourcePath,
        .ca_bundle_path = ca_bundle_path,
        .body = body,
        .headers = try header_list.toOwnedSlice(),
    };
}

fn configureHttpsTrust(client: *std.http.Client, ctx: *const plugin_api.Context, ca_bundle_path: ?[]const u8) !void {
    if (std.http.Client.disable_tls) return;
    if (ca_bundle_path) |bundle_path| {
        const abs_path = try sio.cwd().realpathAlloc(ctx.allocator, bundle_path);
        defer ctx.allocator.free(abs_path);
        const io = sio.io();
        const now = std.Io.Clock.real.now(io);
        try client.ca_bundle.addCertsFromFilePathAbsolute(ctx.allocator, io, now, abs_path);
        // NOTE(Zig 0.17): fetch() rescans + swaps the bundle when now==null.
        client.now = now;
    }
}

fn runHttpRequest(
    ctx: *const plugin_api.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: RequestOptions,
) anyerror!?u8 {
    var client: std.http.Client = .{ .allocator = ctx.allocator, .io = sio.io() };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();

    try configureHttpsTrust(&client, ctx, options.ca_bundle_path);
    const result = client.fetch(.{
        .location = .{ .url = options.url },
        .method = options.method,
        .payload = options.body,
        .extra_headers = options.headers,
        .response_writer = &aw.writer,
        .keep_alive = false,
    }) catch |err| {
        try stderr.print("error: http request failed: {}\n", .{err});
        return 1;
    };

    try stdout.print("status: {d}\n", .{@intFromEnum(result.status)});
    const body = aw.written();
    if (body.len != 0) {
        try stdout.writeAll(body);
        if (body[body.len - 1] != '\n') try stdout.writeByte('\n');
    }
    return 0;
}

fn runHttpStreamRequest(
    ctx: *const plugin_api.Context,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: RequestOptions,
) anyerror!?u8 {
    // NOTE(Zig 0.17): Client.open/send/wait removed; fetch fully then emit
    // body only (no `status:` line) to preserve SSE streaming behavior.
    var client: std.http.Client = .{ .allocator = ctx.allocator, .io = sio.io() };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();

    try configureHttpsTrust(&client, ctx, options.ca_bundle_path);
    _ = client.fetch(.{
        .location = .{ .url = options.url },
        .method = options.method,
        .payload = options.body,
        .extra_headers = options.headers,
        .response_writer = &aw.writer,
        .keep_alive = false,
    }) catch |err| {
        try stderr.print("error: http request failed: {}\n", .{err});
        return 1;
    };

    const body = aw.written();
    if (body.len != 0) try stdout.writeAll(body);
    return 0;
}

pub fn runHttpClientCommand(ctx: *const plugin_api.Context, argv: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) anyerror!?u8 {
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "http-client")) return null;
    if (argv.len < 3) return error.MissingSourcePath;
    const sub = argv[2];
    if (std.mem.eql(u8, sub, "get")) {
        const parsed = try parseRequestArgs(ctx.allocator, argv[3..], false);
        defer ctx.allocator.free(parsed.headers);
        return try runHttpRequest(ctx, stdout, stderr, .{
            .method = .GET,
            .url = parsed.url,
            .ca_bundle_path = parsed.ca_bundle_path,
            .headers = parsed.headers,
        });
    }
    if (std.mem.eql(u8, sub, "post")) {
        const parsed = try parseRequestArgs(ctx.allocator, argv[3..], true);
        defer ctx.allocator.free(parsed.headers);
        return try runHttpRequest(ctx, stdout, stderr, .{
            .method = .POST,
            .url = parsed.url,
            .ca_bundle_path = parsed.ca_bundle_path,
            .body = parsed.body,
            .headers = parsed.headers,
        });
    }
    if (std.mem.eql(u8, sub, "stream")) {
        const parsed = try parseRequestArgs(ctx.allocator, argv[3..], true);
        defer ctx.allocator.free(parsed.headers);
        return try runHttpStreamRequest(ctx, stdout, stderr, .{
            .method = if (parsed.body != null) .POST else .GET,
            .url = parsed.url,
            .ca_bundle_path = parsed.ca_bundle_path,
            .body = parsed.body,
            .headers = parsed.headers,
        });
    }
    return error.UnknownCommand;
}

fn isHttpClientCliError(err: anyerror) bool {
    return switch (err) {
        error.MissingSourcePath,
        error.UnknownCommand,
        error.UnexpectedArgument,
        error.InvalidPath,
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        => true,
        else => false,
    };
}

fn httpClientCliHint(argv: []const []const u8, err: anyerror) []const u8 {
    const sub = if (argv.len >= 3) argv[2] else "";
    return switch (err) {
        error.MissingSourcePath => if (sub.len == 0)
            "usage: sa http-client <get|post|stream> <url>"
        else if (std.mem.eql(u8, sub, "get"))
            "usage: sa http-client get [--ca-bundle <path>] [--header name:value] <url>"
        else if (std.mem.eql(u8, sub, "post"))
            "usage: sa http-client post [--ca-bundle <path>] [--header name:value] <url> <body>"
        else if (std.mem.eql(u8, sub, "stream"))
            "usage: sa http-client stream [--ca-bundle <path>] [--header name:value] <url> [body]"
        else
            "usage: sa http-client <get|post|stream> <url>",
        error.UnknownCommand => "supported HTTP client subcommands are get, post, and stream",
        error.UnexpectedArgument => "remove the extra argument or pass headers as --header name:value",
        error.InvalidPath => "check the URL, CA bundle path, or filesystem path",
        error.FileNotFound, error.NotDir => "check that the CA bundle path exists and is a file",
        error.AccessDenied => "check filesystem permissions for the CA bundle path",
        else => "check HTTP client command arguments",
    };
}

fn writeHttpClientCliError(writer: *std.Io.Writer, argv: []const []const u8, err: anyerror) !void {
    const message = switch (err) {
        error.MissingSourcePath => "missing required HTTP client URL",
        error.UnknownCommand => "unknown HTTP client subcommand",
        error.UnexpectedArgument => "unexpected HTTP client argument",
        error.InvalidPath => "invalid HTTP client path",
        error.FileNotFound => "HTTP client file not found",
        error.NotDir => "HTTP client path is not a directory",
        error.AccessDenied => "HTTP client path access denied",
        else => @errorName(err),
    };
    try writer.print("error[SA-HTTP-CLIENT-CLI]: {s}\n", .{message});
    try writer.print("  help: {s}\n", .{httpClientCliHint(argv, err)});
}

pub fn runHttpClientCommandAbi(ctx: *const plugin_api.Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: plugin_api.HostStream, stderr: plugin_api.HostStream, out_code: *u8) callconv(.c) u32 {
    out_code.* = 0;
    if (argv_len < 2) return @intFromEnum(plugin_api.AbiStatus.unknown_command);
    if (!std.mem.eql(u8, std.mem.span(argv[1]), "http-client")) return @intFromEnum(plugin_api.AbiStatus.unknown_command);

    const args = plugin_helpers.cArgvToSlice(argv, argv_len, ctx.allocator) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer ctx.allocator.free(args);

    var stdout_storage: plugin_helpers.StreamWriterCtx = undefined;
    var stderr_storage: plugin_helpers.StreamWriterCtx = undefined;
    const stdout_writer = plugin_helpers.makeAnyWriter(stdout, &stdout_storage) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const stderr_writer = plugin_helpers.makeAnyWriter(stderr, &stderr_storage) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const result = runHttpClientCommand(ctx, args, stdout_writer, stderr_writer) catch |err| {
        if (!isHttpClientCliError(err)) return @intFromEnum(plugin_api.AbiStatus.failed);
        writeHttpClientCliError(stderr_writer, args, err) catch return @intFromEnum(plugin_api.AbiStatus.failed);
        stdout_writer.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
        stderr_writer.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
        out_code.* = 1;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    };
    stdout_writer.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
    stderr_writer.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

pub const plugin = plugin_api.Plugin{
    .name = "http-client",
    .handleCommand = runHttpClientCommand,
    .skills = &skills,
};

pub const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "http-client",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runHttpClientCommandAbi,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;

pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}
