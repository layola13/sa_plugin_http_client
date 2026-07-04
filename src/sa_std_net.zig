const std = @import("std");
const sa_net = @import("sa_net_primitives");

pub const WebSocketFrame = struct {
    opcode: u8,
    payload: []u8,
};

const ParsedFrame = struct {
    fin: bool,
    opcode: u8,
    masked: bool,
    payload_offset: usize,
    payload_len: usize,
    frame_len: usize,
    mask: [4]u8,
};

pub fn websocketAccept(key: []const u8, out: *[28]u8) ![]const u8 {
    const accept = try sa_net.websocketAccept(key);
    @memcpy(out[0..], accept[0..]);
    return out[0..];
}

pub fn buildWebSocketFrame(out: []u8, opcode: u8, payload: []const u8, mask: ?*const [4]u8) !usize {
    return sa_net.buildWsFrame(opcode, true, payload, mask, out) catch |err| switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        else => error.InvalidWebSocketFrame,
    };
}

pub fn readWebSocketFrameAlloc(allocator: std.mem.Allocator, stream: std.net.Stream, max_len: u64, expect_masked: bool) !WebSocketFrame {
    var header: [14]u8 = undefined;
    try readExact(stream, header[0..2]);

    if ((header[0] & 0x70) != 0) return error.InvalidWebSocketFrame;
    const masked = (header[1] & 0x80) != 0;
    if (masked != expect_masked) return error.InvalidWebSocketFrame;

    var payload_len: u64 = header[1] & 0x7f;
    var header_len: usize = 2;
    if (payload_len == 126) {
        try readExact(stream, header[2..4]);
        payload_len = std.mem.readInt(u16, header[2..4], .big);
        header_len = 4;
    } else if (payload_len == 127) {
        try readExact(stream, header[2..10]);
        payload_len = std.mem.readInt(u64, header[2..10], .big);
        header_len = 10;
    }

    if (payload_len > max_len or payload_len > std.math.maxInt(usize)) return error.InvalidWebSocketFrame;
    if (masked) {
        try readExact(stream, header[header_len .. header_len + 4]);
        header_len += 4;
    }

    const payload_len_usize: usize = @intCast(payload_len);
    const frame_len = std.math.add(usize, header_len, payload_len_usize) catch return error.InvalidWebSocketFrame;
    const frame = try allocator.alloc(u8, frame_len);
    defer allocator.free(frame);
    @memcpy(frame[0..header_len], header[0..header_len]);
    if (payload_len_usize > 0) try readExact(stream, frame[header_len..frame_len]);

    const parsed = try parseWebSocketFrame(frame);
    if (!parsed.fin or parsed.masked != expect_masked or parsed.frame_len != frame_len) return error.InvalidWebSocketFrame;

    var payload: []u8 = &.{};
    if (parsed.payload_len > 0) {
        payload = try allocator.alloc(u8, parsed.payload_len);
        errdefer allocator.free(payload);
        @memcpy(payload, frame[parsed.payload_offset .. parsed.payload_offset + parsed.payload_len]);
        if (parsed.masked) try unmaskWebSocketPayload(payload, parsed.mask);
    }

    return .{ .opcode = parsed.opcode, .payload = payload };
}

fn parseWebSocketFrame(frame: []const u8) !ParsedFrame {
    const parsed = sa_net.parseWsFrame(frame) catch |err| switch (err) {
        error.Incomplete => return error.EndOfStream,
        error.Invalid => return error.InvalidWebSocketFrame,
    };
    return .{
        .fin = parsed.fin,
        .opcode = parsed.opcode,
        .masked = parsed.masked,
        .payload_offset = parsed.payload_start,
        .payload_len = parsed.payload_len,
        .frame_len = parsed.frame_len,
        .mask = parsed.mask,
    };
}

fn unmaskWebSocketPayload(payload: []u8, mask: [4]u8) !void {
    if (payload.len == 0) return;
    sa_net.unmaskFrame(payload, mask);
}

fn readExact(stream: std.net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const read_n = stream.read(buffer[offset..]) catch return error.EndOfStream;
        if (read_n == 0) return error.EndOfStream;
        offset += read_n;
    }
}
