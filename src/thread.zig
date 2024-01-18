const std = @import("std");
const assert = std.debug.assert;
const RingBuffer = @import("util.zig").RingBuffer;

pub fn SpecializedThreadPool(comptime Context: type, comptime func: anytype, comptime Payload: anytype) type {
    return struct {
        allocator: std.mem.Allocator = undefined,
        context: *Context = undefined,
        threads: []std.Thread = undefined,
        job_buffer: RingBuffer(Payload, 64) = .{},
        cond: std.Thread.Condition = .{},
        mutex: std.Thread.Mutex = .{},
        active_thread_count: usize = 0,
        is_running: bool = true,

        pub fn init(self: *@This(), allocator: std.mem.Allocator, context: *Context, thread_count: usize) !void {
            self.threads = try allocator.alloc(std.Thread, thread_count);
            self.context = context;
            self.allocator = allocator;
            for (self.threads, 0..) |*thread, worker_id| {
                thread.* = try std.Thread.spawn(.{}, workerLoop, .{ self, worker_id });
            }
        }

        pub fn freeThreadCount(self: *@This()) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.threads.len - self.active_thread_count;
        }

        fn workerLoop(self: *@This(), worker_id: usize) void {
            _ = worker_id;
            self.mutex.lock();
            while (true) {
                while (self.job_buffer.pop()) |job| {
                    self.active_thread_count += 1;
                    self.mutex.unlock();
                    @call(.auto, func, .{ self.context, job }) catch return;
                    self.mutex.lock();

                    self.active_thread_count -= 1;
                }

                if (self.is_running) {
                    //
                    // Mutex must be locked
                    //
                    self.cond.wait(&self.mutex);
                    //
                    // Mutex is required
                    //
                } else {
                    self.mutex.unlock();
                    break;
                }
            }
        }

        pub fn join(self: *@This()) void {
            self.is_running = false;
            self.cond.broadcast();
            for (self.threads) |thread| {
                thread.join();
            }
        }

        pub fn deinit(self: *@This()) void {
            assert(!self.is_running);
            self.allocator.free(self.threads);
        }

        pub fn submitJob(self: *@This(), job: Payload) !void {
            self.mutex.lock();
            try self.job_buffer.push(job);
            self.mutex.unlock();
            self.cond.signal();
        }
    };
}
