const std = @import("std");
const plugin_api = @import("plugin_api");
const plugin_helpers = @import("plugin_helpers.zig");
pub usingnamespace @import("http_saasm_api.zig");

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
    var header_list = std.ArrayList(std.http.Header).init(allocator);
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
        const abs_path = try std.fs.cwd().realpathAlloc(ctx.allocator, bundle_path);
        defer ctx.allocator.free(abs_path);
        try client.ca_bundle.addCertsFromFilePathAbsolute(ctx.allocator, abs_path);
        client.next_https_rescan_certs = false;
    }
}

fn runHttpRequest(
    ctx: *const plugin_api.Context,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
    options: RequestOptions,
) anyerror!?u8 {
    var client: std.http.Client = .{ .allocator = ctx.allocator };
    defer client.deinit();

    var response_buf = std.ArrayList(u8).init(ctx.allocator);
    defer response_buf.deinit();

    try configureHttpsTrust(&client, ctx, options.ca_bundle_path);
    const result = client.fetch(.{
        .location = .{ .url = options.url },
        .method = options.method,
        .payload = options.body,
        .headers = .{},
        .extra_headers = options.headers,
        .response_storage = .{ .dynamic = &response_buf },
        .max_append_size = 2 * 1024 * 1024,
        .keep_alive = false,
    }) catch |err| {
        try stderr.print("error: http request failed: {}\n", .{err});
        return 1;
    };

    try stdout.print("status: {d}\n", .{@intFromEnum(result.status)});
    if (response_buf.items.len != 0) {
        try stdout.writeAll(response_buf.items);
        if (response_buf.items[response_buf.items.len - 1] != '\n') try stdout.writeByte('\n');
    }
    return 0;
}

fn runHttpStreamRequest(
    ctx: *const plugin_api.Context,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
    options: RequestOptions,
) anyerror!?u8 {
    var client: std.http.Client = .{ .allocator = ctx.allocator };
    defer client.deinit();

    try configureHttpsTrust(&client, ctx, options.ca_bundle_path);
    const uri = try std.Uri.parse(options.url);
    var header_buf: [16 * 1024]u8 = undefined;
    var req = client.open(options.method, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .headers = .{},
        .extra_headers = options.headers,
    }) catch |err| {
        try stderr.print("error: http stream open failed: {}\n", .{err});
        return 1;
    };
    defer req.deinit();

    req.transfer_encoding = if (options.body) |body| .{ .content_length = body.len } else .none;

    try req.send();
    if (options.body) |body| try req.writeAll(body);
    try req.finish();
    try req.wait();

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = req.read(&buf) catch |err| {
            try stderr.print("error: http stream read failed: {}\n", .{err});
            return 1;
        };
        if (n == 0) break;
        try stdout.writeAll(buf[0..n]);
    }
    return 0;
}

pub fn runHttpClientCommand(ctx: *const plugin_api.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
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

fn writeHttpClientCliError(writer: std.io.AnyWriter, argv: []const []const u8, err: anyerror) !void {
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
    const args = plugin_helpers.cArgvToSlice(argv, argv_len, ctx.allocator) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer ctx.allocator.free(args);

    var stdout_storage: plugin_helpers.StreamWriterCtx = undefined;
    var stderr_storage: plugin_helpers.StreamWriterCtx = undefined;
    const stdout_writer = plugin_helpers.makeAnyWriter(stdout, &stdout_storage) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const stderr_writer = plugin_helpers.makeAnyWriter(stderr, &stderr_storage) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const result = runHttpClientCommand(ctx, args, stdout_writer, stderr_writer) catch |err| {
        if (!isHttpClientCliError(err)) return @intFromEnum(plugin_api.AbiStatus.failed);
        writeHttpClientCliError(stderr_writer, args, err) catch return @intFromEnum(plugin_api.AbiStatus.failed);
        out_code.* = 1;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    };
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
