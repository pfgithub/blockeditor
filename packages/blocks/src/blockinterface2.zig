const std = @import("std");

pub const AlignedArrayList = std.ArrayListAligned(u8, 16);
pub const AlignedByteSlice = []align(16) const u8;

const DeserializeError = error{DeserializeError};

pub const BlockID = enum(u128) {
    _,

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

    pub fn format(value: BlockID, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
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

pub const AnyBlock = struct {
    data: *anyopaque,
    vtable: *const BlockVtable,

    pub fn cast(self: AnyBlock, comptime T: type) *T {
        return @alignCast(@ptrCast(self.data));
    }

    pub fn from(comptime T: type, self: *T) AnyBlock {
        const vtable = BlockVtable{
            .applyOperation = T.applyOperation,
            .serialize = T.serialize,
            .deserialize = T.deserialize,
            .deinit = T.deinit,
            .clone = if (@hasDecl(T, "clone")) T.clone else null,
            .is_crdt = false,
        };
        return .{
            .data = @ptrCast(@alignCast(self)),
            .vtable = &vtable,
        };
    }

    pub fn clone(self: AnyBlock, gpa: std.mem.Allocator) AnyBlock {
        if (self.vtable.clone) |clone_fn| return clone_fn(self, gpa);

        var srlz_res = AlignedArrayList.init(gpa);
        defer srlz_res.deinit();

        self.vtable.serialize(self, &srlz_res);
        const cloned = self.vtable.deserialize(gpa, srlz_res.items) catch @panic("just-serialized block deserialize failed");

        return cloned;
    }
};
pub const BlockVtable = struct {
    /// must be deterministic. given an initial block state and a list of operations, applying the same operations in the same order
    /// must always yield a byte-for-byte identical serialized result.
    applyOperation: *const fn (block: AnyBlock, operation: AlignedByteSlice, undo_operation: ?*AlignedArrayList) DeserializeError!void,

    serialize: *const fn (block: AnyBlock, out: *AlignedArrayList) void,
    deserialize: *const fn (gpa: std.mem.Allocator, in: AlignedByteSlice) DeserializeError!AnyBlock,
    deinit: *const fn (block: AnyBlock) void,

    /// optional, if not provided will serialize and then deserialize to clone. use this to implement
    /// copy-on-write and ref-count deinit, or similar.
    clone: ?*const fn (block: AnyBlock, gpa: std.mem.Allocator) AnyBlock,

    /// if 'true', operations can be applied in any order (as long as dependencies are before dependants) and the serialized value
    /// of the block will be byte-for-byte identical regardless of the order operations were applied in. This halves memory usage
    /// for a block (only one copy needs to be kept in memory) and may improve performance
    is_crdt: bool,
};

pub const CounterComponent = struct {
    count: i32,

    const counterblock_serialized = extern struct {
        count: i32,
    };

    const default_aligned: [4]u8 align(16) = .{ 0, 0, 0, 0 };
    pub const default: AlignedByteSlice = &default_aligned;

    pub const Operation = union(enum) {
        add: i32,
        set: i32,

        const operation_serialized = extern struct {
            code: i32,
            value: i32,
        };

        pub fn serialize(self: Operation, out: *AlignedArrayList) void {
            const res: operation_serialized = switch (self) {
                .add => |v| .{ .code = 0, .value = v },
                .set => |v| .{ .code = 1, .value = v },
            };
            out.writer().writeStructEndian(res, .little) catch @panic("oom");
        }

        fn deserialize(value: AlignedByteSlice) DeserializeError!Operation {
            var fbs = std.io.fixedBufferStream(value);
            const values = fbs.reader().readStructEndian(operation_serialized, .little) catch return error.DeserializeError;
            if (fbs.pos != fbs.buffer.len) return error.DeserializeError;
            return switch (values.code) {
                0 => .{ .add = values.value },
                1 => .{ .set = values.value },
                else => error.DeserializeError,
            };
        }
    };
    pub fn applyOperation(self: *CounterComponent, operation_serialized: AlignedByteSlice, undo_operation: ?*AlignedArrayList) DeserializeError!void {
        const operation = try Operation.deserialize(operation_serialized);

        const undo_op: Operation = switch (operation) {
            .add => |num| .{ .add = -%num },
            .set => |_| .{ .set = self.count },
            // undo for 'set' isn't perfect. correct set undo would require keeping the values before set and
            // using a switch command to switch back to the previous counter. but it's fine enough for collaborative editing,
            // problematic for offline editing.
        };
        switch (operation) {
            .add => |num| self.count +%= num,
            .set => |num| self.count = num,
        }
        if (undo_operation) |undo| undo_op.serialize(undo);
    }

    pub fn serialize(self: CounterComponent, out: *AlignedArrayList) void {
        const res: counterblock_serialized = .{ .count = self.count };
        out.writer().writeStructEndian(res, .little) catch @panic("oom");
    }
    pub fn deserialize(_: std.mem.Allocator, fbs: *std.io.FixedBufferStream([]align(16) const u8)) DeserializeError!CounterComponent {
        const values = fbs.reader().readStructEndian(counterblock_serialized, .little) catch return error.DeserializeError;
        if (fbs.pos != fbs.buffer.len) return error.DeserializeError;

        return .{ .count = values.count };
    }

    pub fn deinit(self: *CounterComponent) void {
        _ = self;
    }
};

pub fn ComposedBlock(comptime ChildComponent: type) type {
    return struct {
        const Self = @This();
        gpa: std.mem.Allocator, // to free self on deinit
        value: ChildComponent,

        pub const default: AlignedByteSlice = ChildComponent.default;

        pub const Operation = ChildComponent.Operation;

        fn applyOperation(any: AnyBlock, operation_serialized: AlignedByteSlice, undo_operation: ?*AlignedArrayList) DeserializeError!void {
            const self = any.cast(Self);
            try self.value.applyOperation(operation_serialized, undo_operation);
        }

        fn serialize(any: AnyBlock, out: *AlignedArrayList) void {
            const self = any.cast(Self);
            self.value.serialize(out);
        }
        pub fn deserialize(gpa: std.mem.Allocator, in: AlignedByteSlice) DeserializeError!AnyBlock {
            var fbs = std.io.fixedBufferStream(in);
            const value = try ChildComponent.deserialize(gpa, &fbs);
            if (fbs.pos != fbs.buffer.len) return error.DeserializeError;

            const self = gpa.create(Self) catch @panic("oom");
            self.* = .{ .gpa = gpa, .value = value };

            return AnyBlock.from(Self, self);
        }
        fn deinit(any: AnyBlock) void {
            const self = any.cast(Self);
            self.value.deinit();
            const gpa = self.gpa;
            gpa.destroy(self);
        }
    };
}

pub const CounterBlock = ComposedBlock(CounterComponent);

test CounterBlock {
    const gpa = std.testing.allocator;
    const mycounter = try CounterBlock.deserialize(gpa, CounterBlock.default);
    defer mycounter.vtable.deinit(mycounter);

    try std.testing.expectEqual(@as(i32, 0), mycounter.cast(CounterBlock).value.count);

    var my_operation_al = AlignedArrayList.init(gpa);
    defer my_operation_al.deinit();
    const my_operation = CounterBlock.Operation{
        .add = 12,
    };
    my_operation.serialize(&my_operation_al);
    var my_undo_operation_al = AlignedArrayList.init(gpa);
    defer my_undo_operation_al.deinit();
    try mycounter.vtable.applyOperation(mycounter, my_operation_al.items, &my_undo_operation_al);

    try std.testing.expectEqual(@as(i32, 12), mycounter.cast(CounterBlock).value.count);
}
