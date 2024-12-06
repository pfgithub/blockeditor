const std = @import("std");
const util = @import("anywhere").util;
pub const text_component = @import("text_component.zig");

pub const Alignment = 16;
pub const AlignedArrayList = std.ArrayListAligned(u8, Alignment);
pub const AlignedFbsReader = std.io.FixedBufferStream([]align(Alignment) const u8);
pub const AlignedByteSlice = []align(Alignment) const u8;

const BaseOperationWriter = struct {
    prefix: AlignedArrayList,
    al: *AlignedArrayList,
};
pub fn OperationWriter(comptime T: type) type {
    return struct {
        base: BaseOperationWriter,

        pub fn appendOperation(self: *@This(), op: T) void {
            appendPrefixedOperation(self.base.al, self.base.prefix.items, op);
        }
    };
}
pub const OperationIterator = struct {
    content: AlignedByteSlice,
    pub fn next(self: *OperationIterator) DeserializeError!?AlignedByteSlice {
        if (self.content.len == 0) return null;
        if (self.content.len < Alignment) return error.DeserializeError;

        std.debug.assert(Alignment >= 8);
        const itm_len = std.mem.readInt(u64, self.content[0..8], .little);
        const itm_len_aligned = std.mem.alignForward(u64, itm_len, Alignment);

        self.content = self.content[Alignment..];

        if (self.content.len < itm_len_aligned) return error.DeserializeError;

        const res = self.content[0..text_component.usi(itm_len)];
        self.content = @alignCast(self.content[text_component.usi(itm_len_aligned)..]);
        return res;
    }
};

pub fn safeAlignForwards(al: *AlignedArrayList) void {
    const target_len = std.mem.alignForward(usize, al.items.len, Alignment);
    const diff = target_len - al.items.len;
    al.appendNTimes(0, diff) catch @panic("oom");
}
pub fn reserveLength(al: *AlignedArrayList) usize {
    const orig_len = al.items.len;
    al.appendNTimes(0, Alignment) catch @panic("oom");
    assertAligned(al);
    return orig_len;
}
pub fn fillLengthAndAlignForwards(al: *AlignedArrayList, len_start: usize) void {
    std.debug.assert(al.items.len >= len_start);
    std.mem.writeInt(u64, al.items[len_start..][0..8], al.items.len - len_start - Alignment, .little);
    safeAlignForwards(al);
}
pub fn assertAligned(al: *AlignedArrayList) void {
    std.debug.assert(al.items.len == std.mem.alignForward(usize, al.items.len, Alignment));
}
pub fn appendPrefixedOperation(al: *AlignedArrayList, prefix: AlignedByteSlice, op: anytype) void {
    const reserved = reserveLength(al);
    al.appendSlice(prefix) catch @panic("oom");
    assertAligned(al);
    op.serialize(al);
    fillLengthAndAlignForwards(al, reserved);
}

pub const DeserializeError = error{DeserializeError};

pub const BlockID = util.DistinctUUID(opaque {});

pub const AnyBlock = struct {
    data: *anyopaque,
    vtable: *const BlockVtable,

    pub fn cast(self: AnyBlock, comptime T: type) *T {
        if (std.debug.runtime_safety) {
            std.debug.assert(self.vtable.type_id == @typeName(T));
        }
        return @alignCast(@ptrCast(self.data));
    }

    pub fn from(comptime T: type, self: *T) AnyBlock {
        const vtable = BlockVtable{
            .applyOperations = T.applyOperations,
            .serialize = T.serialize,
            .deserialize = T.deserialize,
            .deinit = T.deinit,
            .clone = if (@hasDecl(T, "clone")) T.clone else null,
            .is_crdt = false,
            .type_id = @typeName(T),
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
    applyOperations: *const fn (block: AnyBlock, operation: AlignedByteSlice, undo_operation: ?*AlignedArrayList) DeserializeError!void,

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

    type_id: [*:0]const u8,
};

pub const CounterComponent = struct {
    count: i32,

    const counterblock_serialized = extern struct {
        count: i32,
    };

    pub const default = "\x00\x00\x00\x00";

    pub const SimpleOperation = union(enum) {
        add: i32,
        set: i32,
    };
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
    pub fn applyOperation(self: *CounterComponent, arena: std.mem.Allocator, operation_serialized: AlignedByteSlice, undo_operation: ?*OperationWriter(Operation)) DeserializeError!void {
        _ = arena;
        const operation = try Operation.deserialize(operation_serialized);

        if (undo_operation) |undo| undo.appendOperation(switch (operation) {
            .add => |num| .{ .add = -%num },
            .set => |_| .{ .set = self.count },
            // undo for 'set' isn't perfect. correct set undo would require keeping the values before set and
            // using a switch command to switch back to the previous counter. but it's fine enough for collaborative editing,
            // problematic for offline editing.
        });
        switch (operation) {
            .add => |num| self.count +%= num,
            .set => |num| self.count = num,
        }
    }

    pub fn serialize(self: CounterComponent, out: *AlignedArrayList) void {
        const res: counterblock_serialized = .{ .count = self.count };
        out.writer().writeStructEndian(res, .little) catch @panic("oom");
    }
    pub fn deserialize(_: std.mem.Allocator, fbs: *AlignedFbsReader) DeserializeError!CounterComponent {
        const values = fbs.reader().readStructEndian(counterblock_serialized, .little) catch return error.DeserializeError;
        if (fbs.pos != fbs.buffer.len) return error.DeserializeError;

        return .{ .count = values.count };
    }

    pub fn genOperations(_: *CounterComponent, res: *OperationWriter(Operation), simple: SimpleOperation) void {
        res.appendOperation(switch (simple) {
            .add => |v| .{ .add = v },
            .set => |v| .{ .set = v },
        });
    }

    pub fn deinit(self: *CounterComponent) void {
        _ = self;
    }
};

pub fn ComposedBlock(comptime ChildComponent: type) type {
    return struct {
        const Self = @This();
        pub const Child = ChildComponent;
        gpa: std.mem.Allocator, // to free self on deinit
        value: ChildComponent,

        const default_aligned: [ChildComponent.default.len]u8 align(16) = ChildComponent.default[0..ChildComponent.default.len].*;
        pub const default: []align(16) const u8 = &default_aligned;

        pub const Operation = ChildComponent.Operation;

        fn applyOperations(any: AnyBlock, operations_serialized: AlignedByteSlice, undo_operation: ?*AlignedArrayList) DeserializeError!void {
            const self = any.cast(Self);

            // make a whole arena just for this operation for no good reason :/
            var arena_backing = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_backing.deinit();
            const arena = arena_backing.allocator();

            // TODO: must reverse order of undo operations. each applyOperation call will generate one or more undo operations.
            // These should stay in the same order, but whenever loop iteration, the next undo operations should go to the front of the array
            var undo_helper: ?OperationWriter(ChildComponent.Operation) = if (undo_operation) |uo| .{ .base = .{ .al = uo, .prefix = .init(arena) } } else null;

            var iter: OperationIterator = .{ .content = operations_serialized };
            while (try iter.next()) |op| {
                try self.value.applyOperation(arena, op, if (undo_helper) |*uo| uo else null);
            }
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
pub const TextDocumentBlock = ComposedBlock(text_component.TextDocument);
