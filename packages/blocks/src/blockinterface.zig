const std = @import("std");

// we may want to run blocks in wasm or rvemu

pub const BlockID = enum(u128) {
    _,
};

pub const AnyBlock = struct {
    data: *const anyopaque,
    vtable: BlockInterface,
    parent: BlockID,
    refs: []BlockID,
};
pub const AnyOperation = struct {
    data: *const anyopaque,
};
pub const AnyUndoToken = struct {
    data: *const anyopaque,
};

pub const BlockInterface = struct {
    deinit: fn (self: AnyBlock) void,
    deinitOperation: fn (operation: AnyOperation) void,

    // returns an operation to undo the applied operation
    applyOperation: fn (self: AnyBlock, operation: AnyOperation) AnyOperation,

    // TODO: all blocks have:
    // - parent
    // - references
    // we need to be able to track this
};

pub fn CreateBlockFromComponent(comptime Component: type) void {
    _ = Component;
}

pub const components = struct {
    pub const Counter = struct {
        pub const Operation = struct {
            change_by: i32,
            fn deinit(_: *Operation) void {
                // nothing to do
            }
        };
        value: i32,

        fn deinit(_: *Counter) void {
            // nothing to do
        }

        fn applyOperation(self: *Counter, operation: Operation) Operation {
            self.value +%= operation.change_by;
        }
    };
    pub fn List(comptime Child: type) type {
        return struct {
            // essentially: each array of items we insert gets an ItemIdx
            // an array of items can be moved. if this happens, the previous items are tombstoned
            // and new items are created at the target location. but this is one operation so we can make
            // sure that if it happens again
            pub const Operation = union(enum) {
                insert_after: struct {},
            };
            const ItemIdx = enum(u64) {};
            indices: std.ArrayList(ItemIdx),
            items: std.ArrayList(Child),
        };
    }
};
