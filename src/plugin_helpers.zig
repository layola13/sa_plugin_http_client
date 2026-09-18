const std = @import("std");
const plugin_api = @import("plugin_api.zig");

pub const StreamWriterCtx = struct {
    stream: plugin_api.HostStream,
};

pub fn cArgvToSlice(argv: [*]const [*:0]const u8, argv_len: usize, allocator: std.mem.Allocator) ![]const []const u8 {
    const slice = argv[0..argv_len];
    var out = try allocator.alloc([]const u8, slice.len);
    errdefer allocator.free(out);
    for (slice, 0..) |arg, idx| {
        out[idx] = std.mem.span(arg);
    }
    return out;
}

pub fn streamWriteFn(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
    const self = @as(*const StreamWriterCtx, @ptrCast(@alignCast(ctx)));
    const write_all = self.stream.write_all orelse return error.WriteFailed;
    if (write_all(self.stream.ctx, bytes.ptr, bytes.len) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
    return bytes.len;
}

pub fn makeAnyWriter(stream: plugin_api.HostStream, storage: *StreamWriterCtx) ?std.io.AnyWriter {
    if (stream.write_all == null) return null;
    if (stream.ctx == null) return null;
    storage.* = .{ .stream = stream };
    return .{ .context = storage, .writeFn = streamWriteFn };
}
