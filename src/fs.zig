const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

///
/// Represents a directory structure in a memory efficient way
///
/// Each node that is added is represented by an Index, this can then be used
/// to add children (sub directories) to that node.
///
pub const PathTree = struct {
    pub const Index = packed struct {
        index: u16,
        heap_index: u16,

        pub fn isNull(self: *@This()) bool {
            return self.index == math.maxInt(u16) and self.heap_index == math.maxInt(u16);
        }
    };

    const EntryHeader = extern struct {
        len: u16,
        parent: u16,
        heap_index: u16,
        parent_heap_index: u16,

        pub inline fn isRoot(self: *const @This()) bool {
            return self.parent == math.maxInt(u16) and self.parent_heap_index == math.maxInt(u16);
        }

        pub inline fn path(self: *const @This()) []const u8 {
            const bytes: [*]const u8 = @ptrCast(self);
            return bytes[@sizeOf(@This()) .. @sizeOf(@This()) + self.len];
        }
    };

    const required_str_alignment: usize = @alignOf(EntryHeader);
    const max_heaps: usize = 128;
    pub const null_parent_index: Index = .{ .index = std.math.maxInt(u16), .heap_index = std.math.maxInt(u16) };

    heap_count: usize = 0,
    heap_indices: [max_heaps]u32 = undefined,
    heaps: [max_heaps][]u8 = undefined,

    pub fn init(self: *@This()) !void {
        self.heap_count = 1;
        self.heap_indices = [1]u32{0} ** max_heaps;
        self.heaps[0] = try std.heap.page_allocator.alignedAlloc(u8, 8, std.mem.page_size);
    }

    pub fn deinit(self: *@This()) void {
        for (self.heaps[0..self.heap_count]) |*heap| {
            std.heap.page_allocator.free(heap);
        }
    }

    inline fn headerFromIndex(self: *const @This(), index: Index) *EntryHeader {
        return @ptrCast(@alignCast(&self.heaps[index.heap_index][index.index]));
    }

    pub fn fullPathFromIndex(self: *const @This(), terminal_index: Index, buffer: []u8) ![]const u8 {
        var rindex: usize = buffer.len;

        var index: Index = terminal_index;

        while (true) {
            const header: *EntryHeader = self.headerFromIndex(index);

            const remaining_space: usize = rindex;
            if (header.len >= remaining_space) {
                std.log.err("Passed buffer not large enough to construct full path", .{});
                return error.OutOfSpace;
            }

            rindex -= header.len;

            @memcpy(buffer[rindex .. rindex + header.len], header.path());

            if (header.isRoot()) {
                break;
            }

            rindex -= 1;
            buffer[rindex] = '/';

            index = .{ .index = header.parent, .heap_index = header.parent_heap_index };
        }

        return buffer[rindex..];
    }

    pub fn fullFilePathFromIndex(self: *const @This(), terminal_index: Index, filename: []const u8, buffer: []u8) ![]const u8 {
        assert(buffer.len > filename.len);
        const len: usize = filename.len;
        const dst_index: usize = buffer.len - filename.len;
        @memcpy(buffer[dst_index .. dst_index + len], filename);
        buffer[dst_index - 1] = '/';
        const dir_path = try self.fullPathFromIndex(terminal_index, buffer[0 .. buffer.len - len - 1]);
        const total_len: usize = filename.len + dir_path.len + 1;
        return buffer[buffer.len - total_len ..];
    }

    pub fn fullFilePathFromIndexZ(self: *const @This(), terminal_index: Index, filename: []const u8, buffer: [:0]u8) ![:0]const u8 {
        assert(buffer.len > filename.len);
        assert(buffer[buffer.len] == 0);
        const len: usize = filename.len;
        const dst_index: usize = buffer.len - filename.len;
        @memcpy(buffer[dst_index .. dst_index + len], filename);
        buffer[dst_index - 1] = '/';
        const dir_path = try self.fullPathFromIndex(terminal_index, buffer[0 .. buffer.len - len - 1]);
        const total_len: usize = filename.len + dir_path.len + 1;
        return buffer[buffer.len - total_len ..];
    }

    fn getRootPath(self: *@This()) ![]const u8 {
        const root_index = try self.findRootIndex();
        return self.headerFromIndex(root_index).path();
    }

    fn findRootIndex(self: *@This()) !Index {
        var current_index: usize = 0;
        var current_heap: usize = 0;
        var entry: *const EntryHeader = undefined;

        while (true) {
            entry = @ptrCast(@alignCast(&self.heaps[current_heap][current_index]));
            if (entry.isRoot()) {
                return Index{ .index = @intCast(current_index), .heap_index = @intCast(current_heap) };
            }
            const padding: usize = blk: {
                const overshoot: usize = entry.len % required_str_alignment;
                break :blk if (overshoot == 0) 0 else required_str_alignment - overshoot;
            };

            current_index += @sizeOf(EntryHeader) + entry.len + padding;

            if (current_index == self.heap_indices[current_heap]) {
                current_heap += 1;
                current_index = 0;
            }

            if (current_heap >= self.heap_count) {
                assert(false);
                return error.Unknown;
            }
        }
        unreachable;
    }

    pub fn addNode(self: *@This(), string: []const u8, parent: Index) !Index {
        const required_space: usize = string.len + @sizeOf(EntryHeader);
        var heap_index: usize = self.heap_count - 1;
        var space_in_heap: usize = self.heaps[heap_index].len - self.heap_indices[heap_index];

        if (required_space > space_in_heap) {
            if (self.heap_count >= max_heaps) {
                std.log.err("Allocated all {d} heaps.", .{max_heaps});
                return error.OutOfSpace;
            }
            self.heap_count += 1;
            heap_index += 1;

            self.heaps[heap_index] = try std.heap.page_allocator.alignedAlloc(u8, 8, std.mem.page_size);

            self.heap_indices[heap_index] = 0;
            space_in_heap = self.heaps[heap_index].len;
        }

        const header: *EntryHeader = @ptrCast(@alignCast(&self.heaps[heap_index][self.heap_indices[heap_index]]));
        header.len = @intCast(string.len);
        header.heap_index = @intCast(heap_index);
        header.parent = parent.index;
        header.parent_heap_index = @intCast(parent.heap_index);

        const string_index: usize = self.heap_indices[heap_index] + @sizeOf(EntryHeader);
        @memcpy(self.heaps[heap_index][string_index .. string_index + string.len], string);

        const required_padding: usize = blk: {
            const overflow: usize = string.len % required_str_alignment;
            break :blk if (overflow == 0) 0 else required_str_alignment - overflow;
        };
        const result_index: usize = self.heap_indices[heap_index];

        const index_increment: usize = @sizeOf(EntryHeader) + string.len + required_padding;
        self.heap_indices[heap_index] += @intCast(index_increment);

        assert(self.heap_indices[heap_index] <= self.heaps[heap_index].len);

        return Index{
            .index = @intCast(result_index),
            .heap_index = @intCast(heap_index),
        };
    }
};
