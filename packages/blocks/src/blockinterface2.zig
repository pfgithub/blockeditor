const std = @import("std");

pub const AlignedArrayList = std.ArrayListAligned(u8, 16);
pub const AlignedByteSlice = []align(16) const u8;

const DeserializeError = error{DeserializeError};

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
        };
        return .{
            .data = @ptrCast(@alignCast(self)),
            .vtable = &vtable,
        };
    }
};
const BlockVtable = struct {
    applyOperation: *const fn (block: AnyBlock, operation: AlignedByteSlice) DeserializeError!void,

    serialize: *const fn (block: AnyBlock, out: *AlignedArrayList) void,
    deserialize: *const fn (gpa: std.mem.Allocator, in: AlignedByteSlice) DeserializeError!AnyBlock,
    deinit: *const fn (block: AnyBlock) void,

    /// optional, if not provided will serialize and then deserialize to clone. use this to implement
    /// copy-on-write and ref-count deinit, or similar.
    clone: ?*const fn (block: AnyBlock) AnyBlock,
};

const CounterBlock = struct {
    // typically instead of making blocks, you make composable components. this is just an example.

    gpa: std.mem.Allocator, // to free self on deinit
    count: i32,
    const counterblock_serialized = extern struct {
        count: i32,
    };

    const default_aligned: [4]u8 align(16) = .{ 0, 0, 0, 0 };
    pub const default: AlignedByteSlice = &default_aligned;

    const Operation = union(enum) {
        add: i32,
        set: i32,

        const operation_serialized = extern struct {
            code: i32,
            value: i32,
        };

        fn serialize(self: Operation, out: *AlignedArrayList) void {
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

    fn applyOperation(any: AnyBlock, operation_serialized: AlignedByteSlice) DeserializeError!void {
        const self = any.cast(CounterBlock);
        const operation = try Operation.deserialize(operation_serialized);

        switch (operation) {
            .add => |num| self.count +%= num,
            .set => |num| self.count = num,
        }
    }

    fn serialize(any: AnyBlock, out: *AlignedArrayList) void {
        const self = any.cast(CounterBlock);
        const res: counterblock_serialized = .{ .count = self.count };
        out.writer().writeStructEndian(res, .little) catch @panic("oom");
    }
    fn deserialize(gpa: std.mem.Allocator, in: AlignedByteSlice) DeserializeError!AnyBlock {
        var fbs = std.io.fixedBufferStream(in);
        const values = fbs.reader().readStructEndian(counterblock_serialized, .little) catch return error.DeserializeError;
        if (fbs.pos != fbs.buffer.len) return error.DeserializeError;

        const self = gpa.create(CounterBlock) catch @panic("oom");
        self.* = .{ .gpa = gpa, .count = values.count };

        return AnyBlock.from(CounterBlock, self);
    }
    fn deinit(any: AnyBlock) void {
        const self = any.cast(CounterBlock);
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

test CounterBlock {
    const gpa = std.testing.allocator;
    const mycounter = try CounterBlock.deserialize(gpa, CounterBlock.default);
    defer mycounter.vtable.deinit(mycounter);

    try std.testing.expectEqual(@as(i32, 0), mycounter.cast(CounterBlock).count);

    var my_operation_al = AlignedArrayList.init(gpa);
    defer my_operation_al.deinit();
    const my_operation = CounterBlock.Operation{
        .add = 12,
    };
    my_operation.serialize(&my_operation_al);
    try mycounter.vtable.applyOperation(mycounter, my_operation_al.items);

    try std.testing.expectEqual(@as(i32, 12), mycounter.cast(CounterBlock).count);
}
