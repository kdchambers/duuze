const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;

pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        head: u16 = 0,
        len: u16 = 0,

        pub const init = @This(){
            .head = 0,
            .len = 0,
            .buffer = undefined,
        };

        pub fn peek(self: @This()) ?T {
            if (self.len == 0)
                return null;

            return self.buffer[self.head];
        }

        pub fn push(self: *@This(), value: T) !void {
            if (self.len == capacity) {
                return error.Full;
            }

            const dst_index: usize = @intCast(@mod(self.head + self.len, capacity));
            self.buffer[dst_index] = value;
            self.len += 1;
        }

        pub fn pop(self: *@This()) ?T {
            if (self.len == 0)
                return null;

            const index = self.head;
            self.head = @intCast(@mod(self.head + 1, capacity));
            self.len -= 1;
            return self.buffer[index];
        }
    };
}

pub fn Stack(comptime T: type, comptime buffer_capacity: usize) type {
    return struct {
        const capacity: usize = buffer_capacity;

        buffer: [capacity]T = undefined,
        size: usize = 0,

        pub inline fn push(self: *@This(), item: T) void {
            assert(self.size < self.buffer.len);
            self.buffer[self.size] = item;
            self.size += 1;
        }

        pub inline fn pop(self: *@This()) *T {
            assert(self.size > 0);
            self.size -= 1;
            return &self.buffer[self.size];
        }

        pub inline fn top(self: *@This()) *T {
            assert(self.size > 0);
            return &self.buffer[self.size - 1];
        }
    };
}

pub fn BufferedWriterConfig(comptime buffer_size: usize) type {
    return struct {
        buffer: [buffer_size]u8 = undefined,
        used: usize = 0,
        out: fs.File,

        pub fn init(out: fs.File) @This() {
            return .{
                .buffer = undefined,
                .used = 0,
                .out = out,
            };
        }

        pub fn write(self: *@This(), bytes: []const u8) void {
            assert(bytes.len <= buffer_size);
            const space_remaining: usize = buffer_size - self.used;
            if (bytes.len > space_remaining) {
                self.flush();
                assert(self.used == 0);
            }
            @memcpy(self.buffer[self.used .. self.used + bytes.len], bytes);
            self.used += bytes.len;
        }

        pub fn flush(self: *@This()) void {
            self.out.writeAll(self.buffer[0..self.used]) catch return;
            self.used = 0;
        }
    };
}

pub inline fn digitCount(value: usize) usize {
    const base: usize = 10;
    var digit_mask: usize = 10;
    var digit_count: usize = 1;
    while (@divTrunc(value, digit_mask) > 0) {
        digit_count += 1;
        digit_mask *= base;
    }

    return digit_count;
}

pub fn byteSizeToString(byte_count: usize, buffer: []u8) ![]const u8 {
    const base: usize = 10;
    var remaining: usize = byte_count;

    const FormatParams = struct {
        divider: usize,
        label: []const u8,
    };

    const format_params: FormatParams = blk: {
        if (byte_count <= 1000) {
            break :blk .{ .divider = 1, .label = "" };
        } else if (byte_count <= 1_000_000) {
            break :blk .{ .divider = 1000, .label = "K" };
        } else if (byte_count <= 1_000_000_000) {
            break :blk .{ .divider = 1000_000, .label = "M" };
        } else if (byte_count <= 1_000_000_000_000) {
            break :blk .{ .divider = 1000_000_000, .label = "G" };
        } else {
            break :blk .{ .divider = 1000_000_000_000, .label = "T" };
        }
        unreachable;
    };

    remaining = @divTrunc(byte_count, format_params.divider);
    const digit_count: usize = digitCount(remaining);
    const required_size: usize = digit_count + format_params.label.len;
    for (digit_count..required_size, 0..) |dst_i, src_i| {
        buffer[dst_i] = format_params.label[src_i];
    }

    var dst_index: usize = required_size - (format_params.label.len + 1);
    var base_mask: usize = base;
    while (true) {
        const digit: usize = remaining % base_mask / (base_mask / base);
        base_mask *= base;
        remaining -= digit;

        buffer[dst_index] = '0' + @as(u8, @intCast(digit));

        if (dst_index == 0) {
            break;
        }

        dst_index -= 1;
    }

    return buffer[0..required_size];
}

test "digitCount" {
    const expect = std.testing.expect;
    try expect(1 == digitCount(5));
    try expect(2 == digitCount(52));
    try expect(3 == digitCount(535));
    try expect(4 == digitCount(5567));
    try expect(5 == digitCount(57542));
    try expect(6 == digitCount(558432));
    try expect(7 == digitCount(5578843));
}

test "byteSizeToString" {
    const expectEql = std.testing.expectEqualStrings;

    var buffer: [32]u8 = undefined;
    try expectEql("123", try byteSizeToString(123, &buffer));
    try expectEql("7K", try byteSizeToString(7489, &buffer));
    try expectEql("10K", try byteSizeToString(10_000, &buffer));
    try expectEql("456K", try byteSizeToString(456_232, &buffer));
    try expectEql("85M", try byteSizeToString(85_456_232, &buffer));
}
