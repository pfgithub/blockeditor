const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        offset_from_start: usize,
        offset_to_end: usize,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .items = &[_]T{},
                .offset_from_start = 0,
                .offset_to_end = 0,
                .gpa = gpa,
            };
        }
        pub fn deinit(self: *Self) void {
            self.gpa.free(self.internalFullSlice());
            self.* = undefined;
        }
        fn internalFullSlice(self: *const Self) []T {
            const ptr: [*]T = self.items.ptr;
            return (ptr - self.offset_from_start)[0 .. self.offset_from_start + self.items.len + self.offset_to_end];
        }

        pub fn ensureUnusedCapacity(self: *Self, unused_capacity: usize) !void {
            // we could implement prepend if we kept some offset from start on realloc
            if (unused_capacity > self.offset_to_end) {
                const prev_len = self.items.len;
                const current_capacity = self.items.len + self.offset_to_end;
                const target_capacity = growCapacity(current_capacity, self.items.len + unused_capacity);
                const new_alloc = try self.gpa.alloc(T, target_capacity);
                @memcpy(new_alloc[0..self.items.len], self.items);
                self.gpa.free(self.internalFullSlice());
                self.items = new_alloc[0..prev_len];
                self.offset_from_start = 0;
                self.offset_to_end = new_alloc.len - prev_len;
            }
        }

        pub fn append(self: *Self, child: T) !void {
            try self.ensureUnusedCapacity(1);
            self.offset_to_end -= 1;
            const target_index = self.items.len;
            self.items.len += 1;
            self.items[target_index] = child;
        }
        pub fn dequeue(self: *Self) ?T {
            if (self.items.len == 0) return null;
            const res = self.items[0];
            self.items = self.items[1..];
            self.offset_from_start += 1;
            return res;
        }
    };
}

fn growCapacity(current: usize, minimum: usize) usize {
    var new = current;
    while (true) {
        new +|= new / 2 + 8;
        if (new >= minimum)
            return new;
    }
}

test Queue {
    var my_queue = Queue(u8).init(std.testing.allocator);
    defer my_queue.deinit();

    try std.testing.expectEqualSlices(u8, "", my_queue.items);
    try my_queue.append('H');
    try std.testing.expectEqualSlices(u8, "H", my_queue.items);
    for ("ello, World!") |char| try my_queue.append(char);
    try std.testing.expectEqualSlices(u8, "Hello, World!", my_queue.items);
    try std.testing.expectEqual('H', my_queue.dequeue());
    for ("ello, World!") |char| try std.testing.expectEqual(char, my_queue.dequeue());
    try std.testing.expectEqual(null, my_queue.dequeue());
    for ("Test increasing the queue size again! Amazing, brilliant!") |char| try my_queue.append(char);
    for ("Test increasing the queue size again! Amazing, brilliant!") |char| try std.testing.expectEqual(char, my_queue.dequeue());
    try std.testing.expectEqual(null, my_queue.dequeue());
}

test "linearfifo" {
    var my_queue = std.fifo.LinearFifo(u8, .Dynamic).init(std.testing.allocator);
    defer my_queue.deinit();

    try std.testing.expectEqualSlices(u8, "", my_queue.readableSlice(0));
    try my_queue.writeItem('H');
    try std.testing.expectEqualSlices(u8, "H", my_queue.readableSlice(0));
    for ("ello, World!") |char| try my_queue.writeItem(char);
    try std.testing.expectEqualSlices(u8, "Hello, World!", my_queue.readableSlice(0));
    try std.testing.expectEqual('H', my_queue.readItem());
    for ("ello, World!") |char| try std.testing.expectEqual(char, my_queue.readItem());
    try std.testing.expectEqual(null, my_queue.readItem());
    for ("Test increasing the queue size again! Amazing, brilliant!") |char| try my_queue.writeItem(char);
    for ("Test increasing the queue size again! Amazing, brilliant!") |char| try std.testing.expectEqual(char, my_queue.readItem());
    try std.testing.expectEqual(null, my_queue.readItem());
}
