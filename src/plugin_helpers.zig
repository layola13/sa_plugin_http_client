const std = @import("std");
const plugin_api = @import("plugin_api");

pub const StreamWriterCtx = struct {
    stream: plugin_api.HostStream,
    io_writer: std.Io.Writer = .{ .buffer = &.{}, .end = 0, .vtable = &vtable },
    storage: [8192]u8 = std.mem.zeroes([8192]u8),

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamWriterCtx = @fieldParentPtr("io_writer", w);
        const write_all = self.stream.write_all orelse return error.WriteFailed;
        const ctx = self.stream.ctx;
        if (w.end != 0) {
            if (write_all(ctx, w.buffer[0..w.end].ptr, w.end) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
            w.end = 0;
        }
        var total: usize = 0;
        for (data, 0..) |slice, i| {
            const reps: usize = if (i == data.len - 1) splat else 1;
            var r: usize = 0;
            while (r < reps) : (r += 1) {
                if (slice.len == 0) continue;
                if (write_all(ctx, slice.ptr, slice.len) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
                total += slice.len;
            }
        }
        return total;
    }
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

pub fn makeAnyWriter(stream: plugin_api.HostStream, storage: *StreamWriterCtx) ?*std.Io.Writer {
    if (stream.write_all == null) return null;
    if (stream.ctx == null) return null;
    storage.* = .{ .stream = stream };
    storage.io_writer.buffer = &storage.storage;
    storage.io_writer.end = 0;
    return &storage.io_writer;
}
