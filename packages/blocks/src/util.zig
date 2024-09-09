const std = @import("std");

pub fn DistinctUUID(comptime Distinct: type) type {
    return enum(u128) {
        const Self = @This();
        pub const _distinct = Distinct;
        _,

        /// must use crypto secure prng!
        pub fn fromRandom(csprng: std.Random) Self {
            return @enumFromInt(csprng.int(u128));
        }

        const chars = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz";
        const chars_bits = std.math.log2_int(usize, chars.len);
        comptime {
            std.debug.assert(chars_bits == std.math.log2_int_ceil(usize, chars.len));
            var prev: u8 = 0;
            for (chars) |char| {
                if (char <= prev) {
                    @compileLog(char);
                    @compileLog(prev);
                    @compileError("char <= prev. see compile logs below.");
                }
                prev = char;
            }
        }

        pub fn format(value: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            const value_u128: u128 = @intFromEnum(value);
            comptime std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
            const value_bytes = std.mem.sliceAsBytes(&[_]u128{value_u128});
            var reader_fbs = std.io.fixedBufferStream(value_bytes);
            var reader_bits = std.io.bitReader(.little, reader_fbs.reader());
            var result_buffer: [24]u8 = [_]u8{0} ** 24;
            result_buffer[0] = '-';
            result_buffer[23] = '-';
            for (1..23) |i| {
                var actual_bits: usize = 0;
                const read_bits = reader_bits.readBits(usize, chars_bits, &actual_bits) catch @panic("fbs error");
                result_buffer[i] = chars[read_bits];
            }

            // assert at end
            {
                var actual_bits: usize = 0;
                _ = reader_bits.readBits(u1, 1, &actual_bits) catch @panic("fbs error");
                std.debug.assert(actual_bits == 0);
            }

            try writer.writeAll(&result_buffer);
        }
    };
}

pub fn ThreadQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        _raw_queue: Queue(T),
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                ._raw_queue = .init(alloc),
                .mutex = .{},
                .condition = .{},
            };
        }
        pub fn deinit(self: *Self) void {
            if (!self.mutex.tryLock()) @panic("cannot deinit while another thread uses the queue");
            self._raw_queue.deinit();
        }

        pub fn write(self: *Self, value: T) void {
            self.writeMany(&.{value});
        }
        pub fn writeMany(self: *Self, value: []const T) void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self._raw_queue.write(value) catch @panic("oom");
            }
            self.signal();
        }
        pub fn kill(self: *Self) void {
            self.kill_thread.store(true, .monotonic);
            self.condition.signal();
        }
        /// returns null if there is no item available at this moment
        pub fn tryRead(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self._raw_queue.readItem();
        }
        /// returns null if should_kill is true (must signal())
        pub fn waitRead(self: *Self, should_kill: *std.atomic.Value(bool)) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (should_kill.load(.monotonic)) return null;
                if (self._raw_queue.readableLength() != 0) break;
                self.condition.wait(&self.mutex);
            }

            return self._raw_queue.readItem().?;
        }
        /// call this after changing should_kill
        pub fn signal(self: *Self) void {
            self.condition.signal();
        }
    };
}

pub fn Queue(comptime T: type) type {
    return std.fifo.LinearFifo(T, .Dynamic);
}

pub fn Callback(comptime Arg_: type, comptime Ret_: type) type {
    return struct {
        const Self = @This();
        cb: *const fn (data: usize, arg: Arg) Ret,
        data: usize,

        pub const Arg = Arg_;
        pub const Ret = Ret_;
        pub fn from(data: anytype, comptime cb: fn (data: @TypeOf(data), arg: Arg) Ret) Self {
            comptime std.debug.assert(@sizeOf(@TypeOf(data)) == @sizeOf(usize));
            const data_usz: usize = @intFromPtr(data);
            const update_fn = struct {
                fn update_fn(data_: usize, arg: Arg) Ret {
                    return cb(@ptrFromInt(data_), arg);
                }
            }.update_fn;
            return .{ .cb = &update_fn, .data = data_usz };
        }
        pub fn call(self: Self, arg: Arg) Ret {
            return self.cb(self.data, arg);
        }
        pub fn eql(self: Self, other: Self) bool {
            return self.cb == other.cb and self.data == other.data;
        }
    };
}

pub fn CallbackList(comptime cb_type: type) type {
    return struct {
        const Self = @This();
        callbacks: std.ArrayList(cb_type),
        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .callbacks = std.ArrayList(cb_type).init(alloc),
            };
        }
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.callbacks.items.len == 0);
            self.callbacks.deinit();
        }

        pub fn addListener(self: *Self, cb: cb_type) void {
            self.callbacks.append(cb) catch @panic("oom");
        }
        pub fn removeListener(self: *Self, cb: cb_type) void {
            const i = for (self.callbacks.items, 0..) |ufn, i| {
                if (ufn.eql(cb)) break i;
            } else return; // already removed
            _ = self.callbacks.swapRemove(i); // unordered should be okay
        }
        pub fn call(self: *Self, arg: cb_type.Arg) void {
            if (cb_type.Ret != void) @compileLog(cb_type.Ret);
            for (self.callbacks.items) |cb| {
                cb.call(arg);
            }
        }
    };
}
