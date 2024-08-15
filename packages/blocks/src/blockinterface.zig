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
    deinit: *const fn (self: AnyBlock) void,
    deinitOperation: *const fn (operation: AnyOperation) void,

    // returns an operation to undo the applied operation
    applyOperation: *const fn (self: AnyBlock, operation: AnyOperation) AnyOperation,

    // TODO: all blocks have:
    // - parent
    // - references
    // we need to be able to track this
};

pub fn CreateBlockFromComponent(comptime Component: type) void {
    _ = Component;
}

/// a Component is part of a Block. Operations are applied to components:
/// - A B C D
/// a Component should preserve user intent if a new operation is inserted earlier in the history, ie:
/// - A B [E] C D
/// to insert early in the history:
/// - D is physically undone. C is physically undone. E is applied. C is applied. D is applied
///   - it is not enough to just apply D's undo operation. it needs to be fully undone as if it was never applied in the first place
/// alternatively, we can require applyOperation to be a CRDT. This means these two are equivalent:
/// - A B E C D is the same as A B C D E
/// - This takes a bit of effort.
///   - NewestWins is pretty easy to make into a CRDT, but AppendOnlyList? Should be alright if we introduce one layer of indirection
pub const components = struct {
    pub const Sample = struct {
        pub const Operation = struct {
            /// does not need to be called if it was applied
            fn deinit(_: *Operation) void {}
        };

        fn deinit(_: *Sample) void {}

        /// operation is consumed and no longer needs to be deinitialized. returns
        /// an inverse operation which when applied undoes the operation.
        fn applyOperation(_: *Sample, _: Operation) Operation {
            return .{};
        }
    };

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
            return .{ .change_by = -operation.change_by };
        }
    };
    test Counter {
        var my_counter = Counter{ .value = 0 };
        defer my_counter.deinit();

        var undo_1 = my_counter.applyOperation(.{ .change_by = 25 });
        errdefer undo_1.deinit();
        try std.testing.expectEqual(@as(i32, 25), my_counter.value);

        var undo_2 = my_counter.applyOperation(undo_1);
        errdefer undo_2.deinit();
        try std.testing.expectEqual(@as(i32, 0), my_counter.value);

        var undo_3 = my_counter.applyOperation(undo_2);
        undo_3.deinit();
        try std.testing.expectEqual(@as(i32, 25), my_counter.value);
    }

    /// Child must have 'fn deinit()'
    pub fn NewestWinsValue(comptime Child: type) type {
        return struct {
            const Self = @This();
            pub const Operation = union(enum) {
                set: struct {
                    value: Child,
                },

                pub fn deinit(operation: *Operation) void {
                    switch (operation) {
                        .set => |*set_op| {
                            set_op.value.deinit();
                        },
                    }
                }
            };

            value: Child,

            fn deinit(self: *Self) void {
                self.value.deinit();
            }
            fn applyOperation(self: *Self, operation: Operation) Operation {
                switch (operation) {
                    .set => |set_op| {
                        const prev_val = self.value;
                        self.value = set_op.value;
                        return .{ .set = .{ .value = prev_val } };
                    },
                }
            }
        };
    }

    /// Child must be a component
    pub fn AppendOnlyList(comptime Child: type) type {
        return struct {
            const Self = @This();
            pub const Operation = union(enum) {
                append: struct {
                    new_child: Child,
                },
                set_deleted: struct {
                    index: usize,
                    deleted: bool,
                },
                mutate_child: struct {
                    index: usize,
                    operation: Child.Operation,
                },

                fn deinit(operation: *Operation) void {
                    switch (operation) {
                        .append => |*append_op| {
                            append_op.new_child.deinit();
                        },
                        .set_deleted => |_| {},
                        .mutate_child => |*mutate_child_op| {
                            mutate_child_op.operation.deinit();
                        },
                    }
                }
            };
            const Item = struct {
                value: Child,
                deleted: bool,
            };
            items: std.ArrayList(Item),

            fn deinit(self: *Self) Operation {
                for (self.items.items) |*item| item.value.deinit();
                self.items.deinit();
            }

            fn applyOperation(self: *Self, operation: Operation) Operation {
                switch (operation) {
                    .append => |append_op| {
                        const index = self.items.items.len;
                        self.items.append(.{ .value = append_op.new_child, .deleted = false }) catch @panic("oom");
                        return .{ .set_deleted = .{ .index = index, .deleted = true } };
                    },
                    .set_deleted => |set_deleted_op| {
                        self.items.items[set_deleted_op.index].deleted = set_deleted_op.deleted;
                        return .{ .set_deleted = .{ .index = set_deleted_op.index, .deleted = !set_deleted_op.deleted } };
                    },
                    .mutate_child => |mutate_child_op| {
                        const res = self.items.item[mutate_child_op.index].value.applyOperation(mutate_child_op.operation);
                        return .{ .mutate_child = .{ .index = mutate_child_op.index, .operation = res } };
                    },
                }
            }
        };
    }
};

const blocks = struct {
    pub const IntegratedTodoListBlock = struct {
        pub const Component = components.AppendOnlyList(components.NewestWinsValue(std.ArrayList(u8)));
        // this should provide a default editor
    };
    pub const SeperateTodoListBlock = struct {
        pub const Component = components.AppendOnlyList(components.BlockRef);
        // provide a default editor
    };
    pub const SeperateTodoItem = struct {
        pub const Component = components.NewestWinsValue(std.ArrayList(u8));
        // provide a default editor
    };
};

test {
    _ = components;
}
