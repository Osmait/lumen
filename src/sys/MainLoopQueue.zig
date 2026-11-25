//! Thread-safe worker-to-GTK-main-loop delivery queue backed by `g_idle_add`.
//! Workers post payloads for asynchronous delivery on the GTK main loop;
//! shutdown drains any remaining idle sources and destroys pending payloads.

const std = @import("std");
const c = @import("c");

pub fn MainLoopQueue(comptime T: type) type {
    return struct {
        const Queue = @This();

        const Node = struct {
            queue: *Queue,
            value: T,
            source_id: c_uint = 0,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        gpa: std.mem.Allocator,
        io: std.Io,
        stop: *const std.atomic.Value(bool),
        context: *anyopaque,
        deliver_fn: *const fn (*anyopaque, T) void,
        destroy_fn: *const fn (std.mem.Allocator, T) void,
        lock: std.Io.Mutex = .init,
        head: ?*Node = null,

        pub fn post(queue: *Queue, value: T) bool {
            if (queue.stop.load(.acquire)) {
                queue.destroy_fn(queue.gpa, value);
                return false;
            }
            const node = queue.gpa.create(Node) catch {
                queue.destroy_fn(queue.gpa, value);
                return false;
            };
            node.* = .{ .queue = queue, .value = value };
            queue.lock.lockUncancelable(queue.io);
            if (queue.stop.load(.acquire)) {
                queue.lock.unlock(queue.io);
                queue.destroy_fn(queue.gpa, value);
                queue.gpa.destroy(node);
                return false;
            }
            node.next = queue.head;
            if (queue.head) |head| head.prev = node;
            queue.head = node;
            const source_id = c.g_idle_add(&idleCallback, node);
            node.source_id = source_id;
            if (source_id == 0) {
                queue.unlink(node);
                queue.lock.unlock(queue.io);
                queue.destroy_fn(queue.gpa, value);
                queue.gpa.destroy(node);
                return false;
            }
            queue.lock.unlock(queue.io);
            return true;
        }

        pub fn drain(queue: *Queue) void {
            queue.lock.lockUncancelable(queue.io);
            var cursor = queue.head;
            queue.head = null;
            queue.lock.unlock(queue.io);
            while (cursor) |node| {
                const next = node.next;
                if (node.source_id != 0) _ = c.g_source_remove(node.source_id);
                queue.destroy_fn(queue.gpa, node.value);
                queue.gpa.destroy(node);
                cursor = next;
            }
        }

        /// Removes every node matching `matchFn` and returns the first
        /// matching value, destroying any older matches.
        pub fn takeNewest(queue: *Queue, comptime matchFn: fn (T) bool) ?T {
            queue.lock.lockUncancelable(queue.io);
            defer queue.lock.unlock(queue.io);
            var cursor = queue.head;
            var found: ?T = null;
            while (cursor) |node| {
                const next = node.next;
                if (matchFn(node.value)) {
                    queue.unlink(node);
                    if (node.source_id != 0) _ = c.g_source_remove(node.source_id);
                    if (found == null) {
                        found = node.value;
                    } else {
                        queue.destroy_fn(queue.gpa, node.value);
                    }
                    queue.gpa.destroy(node);
                }
                cursor = next;
            }
            return found;
        }

        fn unlink(queue: *Queue, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else if (queue.head == node) {
                queue.head = node.next;
            }
            if (node.next) |next| next.prev = node.prev;
            node.prev = null;
            node.next = null;
        }

        fn idleCallback(data: ?*anyopaque) callconv(.c) c.gboolean {
            const node: *Node = @ptrCast(@alignCast(data.?));
            const queue = node.queue;
            queue.lock.lockUncancelable(queue.io);
            queue.unlink(node);
            const stopped = queue.stop.load(.acquire);
            queue.lock.unlock(queue.io);
            const value = node.value;
            queue.gpa.destroy(node);
            if (stopped) {
                queue.destroy_fn(queue.gpa, value);
                return 0;
            }
            queue.deliver_fn(queue.context, value);
            return 0;
        }
    };
}
