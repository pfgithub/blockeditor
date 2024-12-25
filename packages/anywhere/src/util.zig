const std = @import("std");

pub const AnyPtr = struct {
    id: [*]const u8,
    val: *anyopaque,
    pub fn from(comptime T: type, value: *const T) AnyPtr {
        return .{ .id = @typeName(T), .val = @ptrCast(@constCast(value)) };
    }
    pub fn to(self: AnyPtr, comptime T: type) *T {
        std.debug.assert(self.id == @typeName(T));
        return @ptrCast(@alignCast(self.val));
    }
};

pub const build = struct {
    fn arbitraryName(b: *std.Build, name: []const u8, comptime ty: type) []const u8 {
        return b.fmt("__exposearbitrary_{d}_{s}_{d}", .{ @intFromPtr(b), name, @intFromPtr(@typeName(ty)) });
    }
    pub fn expose(b: *std.Build, name: []const u8, comptime ty: type, val: ty) void {
        const valdupe = b.allocator.create(ty) catch @panic("oom");
        valdupe.* = val;
        const valv = b.allocator.create(AnyPtr) catch @panic("oom");
        valv.* = .from(ty, valdupe);
        const name_fmt = arbitraryName(b, name, ty);
        b.named_lazy_paths.putNoClobber(name_fmt, .{ .cwd_relative = @as([*]u8, @ptrCast(valv))[0..1] }) catch @panic("oom");
    }
    pub fn find(dep: *std.Build.Dependency, comptime ty: type, name: []const u8) ty {
        const name_fmt = arbitraryName(dep.builder, name, ty);
        const modv = dep.builder.named_lazy_paths.get(name_fmt).?;
        const anyptr: *const AnyPtr = @alignCast(@ptrCast(modv.cwd_relative.ptr));
        std.debug.assert(anyptr.id == @typeName(ty));
        return anyptr.to(ty).*;
    }

    pub const LibcFileOptions = struct {
        /// The directory that contains `stdlib.h`.
        /// On POSIX-like systems, include directories be found with: `cc -E -Wp,-v -xc /dev/null`
        include_dir: ?std.Build.LazyPath,
        /// The system-specific include directory. May be the same as `include_dir`.
        /// On Windows it's the directory that includes `vcruntime.h`.
        /// On POSIX it's the directory that includes `sys/errno.h`.
        sys_include_dir: ?std.Build.LazyPath,
        /// The directory that contains `crt1.o` or `crt2.o`.
        /// On POSIX, can be found with `cc -print-file-name=crt1.o`.
        /// Not needed when targeting MacOS.
        crt_dir: ?std.Build.LazyPath,
        /// The directory that contains `vcruntime.lib`.
        /// Only needed when targeting MSVC on Windows.
        msvc_lib_dir: ?std.Build.LazyPath,
        /// The directory that contains `kernel32.lib`.
        /// Only needed when targeting MSVC on Windows.
        kernel32_lib_dir: ?std.Build.LazyPath,
        /// The directory that contains `crtbeginS.o` and `crtendS.o`
        /// Only needed when targeting Haiku.
        gcc_dir: ?std.Build.LazyPath,
    };
    pub fn genLibCFile(b: *std.Build, anywhere_dep: *std.Build.Dependency, libc_file_options: LibcFileOptions) std.Build.LazyPath {
        const make_libc_file = b.addRunArtifact(anywhere_dep.artifact("libc_file_builder"));
        inline for (@typeInfo(LibcFileOptions).@"struct".fields) |field| {
            if (@field(libc_file_options, field.name)) |val| {
                make_libc_file.addPrefixedDirectoryArg(field.name ++ "=", val);
            } else {
                make_libc_file.addArg(field.name ++ "=");
            }
        }
        const make_libc_stdout = make_libc_file.captureStdOut();
        return make_libc_stdout;
    }
};

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
                var actual_bits: u16 = 0;
                const read_bits = reader_bits.readBits(usize, chars_bits, &actual_bits) catch @panic("fbs error");
                result_buffer[i] = chars[read_bits];
            }

            // assert at end
            {
                var actual_bits: u16 = 0;
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
        pub fn emit(self: *Self, arg: cb_type.Arg) void {
            if (cb_type.Ret != void) @compileLog(cb_type.Ret);
            for (self.callbacks.items) |cb| {
                cb.call(arg);
            }
        }
    };
}

// is Align necessary? can we skip it and make asPtr return *align(4) T?
pub fn AnySized(comptime Size: comptime_int, comptime Align: comptime_int) type {
    return struct {
        data: [Size]u8 align(Align),
        ty: if (std.debug.runtime_safety) [*:0]const u8 else void,

        pub fn from(comptime T: type, value: T) @This() {
            comptime {
                std.debug.assert(@sizeOf(T) <= Size);
                std.debug.assert(@alignOf(T) <= Align);
            }
            var result_bytes: [Size]u8 = [_]u8{0} ** Size;
            const bytes = std.mem.asBytes(&value);
            @memcpy(result_bytes[0..bytes.len], bytes);
            return .{
                .data = result_bytes,
                .ty = if (std.debug.runtime_safety) @typeName(T) else void,
            };
        }
        pub fn asPtr(self: *@This(), comptime T: type) *T {
            if (std.debug.runtime_safety) std.debug.assert(self.ty == @typeName(T));
            return std.mem.bytesAsValue(T, &self.data);
        }
        pub fn as(self: @This(), comptime T: type) T {
            if (std.debug.runtime_safety) std.debug.assert(self.ty == @typeName(T));
            return std.mem.bytesAsValue(T, &self.data).*;
        }
    };
}
test AnySized {
    const Any = AnySized(16, 16);

    var my_any = Any.from(u32, 25);
    try std.testing.expectEqual(@as(u32, 25), my_any.as(u32));
    my_any.asPtr(u32).* += 12;
    try std.testing.expectEqual(@as(u32, 25 + 12), my_any.as(u32));
}

pub fn fpsToMspf(fps: f64) f64 {
    return (1.0 / fps) * 1000.0;
}
pub const FixedTimestep = struct {
    start_ms: f64,
    last_update_ms: f64,
    total_updates_applied: usize,
    /// to change this, do fixed_timestep = .init(new_mspf);
    target_mspf: f64,
    pub fn init(target_mspf: f64) FixedTimestep {
        return .{ .start_ms = 0, .last_update_ms = 0, .total_updates_applied = 0, .target_mspf = target_mspf };
    }
    fn reset(self: *FixedTimestep, now_ms: f64) void {
        self.start_ms = now_ms;
        self.last_update_ms = now_ms;
        self.total_updates_applied = 0;
    }
    pub fn advance(self: *FixedTimestep, now_ms: f64) usize {
        self.last_update_ms = now_ms;

        const expected_update_count = @floor((self.last_update_ms - self.start_ms) / self.target_mspf);
        const actual_update_count: f64 = @floatFromInt(self.total_updates_applied);

        const expected_vs_actual_diff = expected_update_count - actual_update_count;

        if (expected_vs_actual_diff < 0) {
            // went backwards in time
            self.reset(now_ms);
            return 1;
        }
        if (expected_vs_actual_diff > 4) {
            // lagging or behind for more than four frames
            self.reset(now_ms);
            return 1;
        }
        const result: usize = @intFromFloat(expected_vs_actual_diff);
        self.total_updates_applied += result;
        return result;
    }
};
