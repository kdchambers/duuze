//!
//! Multi-threaded clone of du -sh <dir_path>
//!

const std = @import("std");
const fs = std.fs;
const atomic = std.atomic;
const assert = std.debug.assert;
const io = std.io;

const ThreadPool = @import("thread.zig").SpecializedThreadPool;
const util = @import("util.zig");
const Stack = util.Stack;
const BufferedWriter = util.BufferedWriterConfig(4096);
const PathTree = @import("fs.zig").PathTree;

const AddNodePayload = struct {
    full_path: [*:0]const u8,
    path_len: usize,
    buffer_invalidate_event: std.Thread.ResetEvent = .{},
};

const SharedContext = struct {
    total_size: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    path_tree: PathTree = undefined,

    pub fn init(self: *@This()) !void {
        self.total_size = std.atomic.Value(usize).init(0);
        try self.path_tree.init();
    }

    pub fn deinit(self: *@This()) void {
        self.path_tree.deinit();
    }
};

const directory_size: usize = 4096;

pub fn main() u8 {
    var arg_iter = std.process.args();
    _ = arg_iter.skip();

    const root_path: [:0]const u8 = arg_iter.next() orelse ".";
    const size_bytes = calcDirSize(root_path) catch |err| {
        std.log.err("Failed to calculate size for given directory. Path: \"{s}\". Error: {}", .{ root_path, err });
        return 1;
    };

    var size_str_buffer: [32]u8 = undefined;
    const size_str = util.byteSizeToString(size_bytes, &size_str_buffer) catch |err| {
        std.log.err("Failed to convert {d} to string. Error: {}", .{ size_bytes, err });
        return 1;
    };

    var stdout: BufferedWriter = BufferedWriter.init(io.getStdOut());
    defer stdout.flush();

    stdout.write(size_str);
    stdout.write("\n");

    return 0;
}

///
/// Calculate the total size (recursively) of a given directory path
///
/// Goes breath first along the tree, off-loading directories to helper threads when available
/// The helper threads then use a depth-first algorithm to avoid using an obsurd amount of memory
/// and return to the thread pool when all sub-directories have been processed
///
fn calcDirSize(root_path: [:0]const u8) !usize {
    assert(root_path.len >= 1);

    var context: SharedContext = .{};
    try context.init();

    const open_options: fs.Dir.OpenDirOptions = .{
        .access_sub_paths = false,
        .iterate = true,
        .no_follow = true,
    };

    var path_buffer: [fs.MAX_PATH_BYTES]u8 = undefined;
    const full_root_path: []const u8 = try std.fs.realpath(root_path, &path_buffer);
    var parent_path_len: usize = full_root_path.len;

    var root_dir: fs.Dir = try fs.openDirAbsolute(full_root_path, open_options);

    var parent_index: PathTree.Index = try context.path_tree.addNode(full_root_path, PathTree.null_parent_index);

    const max_dir_count: usize = 512;

    var index_buffer: [max_dir_count]PathTree.Index = undefined;
    var index_count: usize = 0;

    var iter = root_dir.iterate();

    var total_size: usize = 0;

    const thread_count: usize = std.Thread.getCpuCount() catch 1;

    var thread_pool: ThreadPool(SharedContext, calcDirSizeWorker, *AddNodePayload) = .{};
    try thread_pool.init(std.heap.c_allocator, &context, thread_count);

    while (true) {
        while (try iter.next()) |entry| {
            const required_space: usize = parent_path_len + entry.name.len + 2;
            assert(path_buffer.len >= required_space);

            path_buffer[parent_path_len] = '/';

            {
                const dst_start: usize = parent_path_len + 1;
                const dst_end: usize = dst_start + entry.name.len;
                @memcpy(path_buffer[dst_start..dst_end], entry.name);
            }

            path_buffer[required_space - 1] = 0;

            const next_path: [:0]const u8 = path_buffer[0 .. required_space - 1 :0];
            switch (entry.kind) {
                .directory => {
                    if (thread_pool.freeThreadCount() > 0) {
                        var payload: AddNodePayload = .{
                            .full_path = next_path,
                            .buffer_invalidate_event = .{},
                            .path_len = parent_path_len + entry.name.len + 1,
                        };
                        try thread_pool.submitJob(&payload);
                        payload.buffer_invalidate_event.wait();
                    } else {
                        if (index_count == max_dir_count) {
                            std.log.err("No more space in index_buffer", .{});
                            return error.OutOfSpace;
                        }

                        index_buffer[index_count] = try context.path_tree.addNode(entry.name, parent_index);
                        index_count += 1;
                    }
                    total_size += directory_size;
                },
                .file => {
                    var stat: std.os.linux.Stat = undefined;
                    if (std.os.linux.stat(next_path.ptr, &stat) != 0) {
                        std.log.warn("Failed to stat file: {s}. Ignoring", .{next_path});
                    } else {
                        total_size += @as(usize, @intCast(stat.size));
                    }
                },
                else => {},
            }
        }

        if (index_count == 0) {
            break;
        }

        index_count -= 1;
        parent_index = index_buffer[index_count];

        root_dir.close();

        const full_path = context.path_tree.fullPathFromIndex(parent_index, &path_buffer) catch |err| {
            std.log.err("Failed to get full path from index. Error: {}", .{err});
            return err;
        };
        @memcpy(path_buffer[0..full_path.len], full_path);

        parent_path_len = full_path.len;

        root_dir = std.fs.openDirAbsolute(full_path, open_options) catch |err| {
            std.log.err("Failed to open path: {s}. Error: {}", .{ full_path, err });
            return err;
        };

        iter = root_dir.iterate();
    }

    const current_size = context.total_size.load(.Monotonic);
    context.total_size.store(total_size + current_size, .Monotonic);

    thread_pool.join();
    thread_pool.deinit();

    return context.total_size.load(.Monotonic);
}

fn calcDirSizeWorker(context: *SharedContext, payload: *AddNodePayload) !void {
    const path_len: usize = payload.path_len;

    var path_buffer: [fs.MAX_PATH_BYTES]u8 = undefined;
    @memcpy(path_buffer[0..path_len], payload.full_path);

    //
    // After this statement, `payload` will is invalid
    //
    payload.buffer_invalidate_event.set();

    const full_path: []const u8 = path_buffer[0..path_len];

    const open_options: fs.Dir.OpenDirOptions = .{
        .access_sub_paths = false,
        .iterate = true,
        .no_follow = true,
    };

    var root_dir = std.fs.openDirAbsolute(full_path, open_options) catch |err| {
        std.log.err("Failed to open given path in worker: {s}. Error: {}", .{ full_path, err });
        return err;
    };

    const IterContext = struct {
        iter: fs.Dir.Iterator,
        dir: fs.Dir,
        path_len: usize,
    };

    var iter_stack: Stack(IterContext, 32) = .{};

    iter_stack.push(.{
        .iter = root_dir.iterate(),
        .dir = root_dir,
        .path_len = full_path.len,
    });

    var total_size: usize = 0;

    while (iter_stack.size > 0) {
        while (try iter_stack.top().iter.next()) |entry| {
            const parent_path_len: usize = iter_stack.top().path_len;

            const required_space: usize = parent_path_len + entry.name.len + 2;
            assert(path_buffer.len >= required_space);

            path_buffer[parent_path_len] = '/';

            {
                const dst_start: usize = parent_path_len + 1;
                const dst_end: usize = dst_start + entry.name.len;
                @memcpy(path_buffer[dst_start..dst_end], entry.name);
            }

            path_buffer[required_space - 1] = 0;

            const next_path: [:0]const u8 = path_buffer[0 .. required_space - 1 :0];
            switch (entry.kind) {
                .directory => {
                    const next_dir = std.fs.openDirAbsolute(next_path, open_options) catch |err| {
                        std.log.err("Failed to open path: {s}", .{next_path});
                        return err;
                    };

                    iter_stack.push(.{
                        .iter = next_dir.iterate(),
                        .dir = next_dir,
                        .path_len = parent_path_len + entry.name.len + 1,
                    });
                },
                .file => {
                    var stat: std.os.linux.Stat = undefined;
                    if (std.os.linux.stat(next_path.ptr, &stat) != 0) {
                        return error.StatFailed;
                    }
                    total_size += @as(usize, @intCast(stat.size));
                },
                else => {},
            }
        }

        //
        // Close file for exhausted iterator
        //
        iter_stack.pop().dir.close();
    }

    const current_size = context.total_size.load(.Monotonic);
    context.total_size.store(total_size + current_size, .Monotonic);
}
