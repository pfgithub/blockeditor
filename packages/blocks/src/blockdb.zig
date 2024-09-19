//! blockdb

const std = @import("std");
const bi = @import("blockinterface2.zig");
const util = @import("util.zig");

// TODO: you should be able to apply multiple operations at once by calling on the BlockDBInterface. The server should be able to send
// batches of multiple operations at once to apply all at the same time.
// If operations are submitted as batched, they should be sent to the server as batched.
// For now that is supported if the block supports multiple operations, but it's not supported across multiple blocks. We could support it
// across multiple blocks.
// - maybe we don't want this. two different blocks could be hosted on different servers and the app should still function.
//   - with single source of truth, when you request a block from the server it needs to lock and assign a server to manage it.
//     locking is impossible in a distributed system. so we should probably handle the case where two servers declare themselves the
//     source of truth for one block. in that case, when they figure it out they need to: pick one server as the true one. send over all
//     the operations that server 2 applied and server 1 will apply them. transfer server 2's clients to server 1. and then clients
//     need to go to a bit of effort to get the new blocks with the merged histories and overlay their unsent operations.
//   - we don't have to worry about this for a while which is good because it's complicated. with a crdt it would be simpler because
//     we can just have every client apply all of server 2's operations (or server 1 for server 2 clients) and not worry about order
//     at all

test BlockDB {
    const gpa = std.testing.allocator;

    var interface = BlockDB.init(gpa);
    defer interface.deinit();

    const my_block = interface.fetchBlock(@enumFromInt(1));
    defer my_block.unref();

    const my_created_block = interface.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    defer my_created_block.unref();

    var my_operation_al = bi.AlignedArrayList.init(gpa);
    defer my_operation_al.deinit();
    const my_operation = bi.CounterBlock.Operation{
        .add = 12,
    };
    my_operation.serialize(&my_operation_al);
    var my_undo_operation_al = bi.AlignedArrayList.init(gpa);
    defer my_undo_operation_al.deinit();
    my_created_block.applyOperation("", my_operation_al.items, &my_undo_operation_al);
}

pub const BlockDB = struct {
    gpa: std.mem.Allocator,

    path_to_blockref_map: std.AutoArrayHashMap(bi.BlockID, *BlockRef),

    send_queue: util.ThreadQueue(ThreadInstruction),
    recv_queue: util.ThreadQueue(ToApplyInstruction),

    const ToApplyInstruction = union(enum) {
        load_block: struct { block: bi.BlockID, value_owned: bi.AlignedByteSlice },
        apply_operation: struct { block: bi.BlockID, operation_owned: bi.AlignedByteSlice },

        fn deinit(self: ToApplyInstruction, dbi: *BlockDB) void {
            switch (self) {
                .load_block => |lb| {
                    dbi.gpa.free(lb.value_owned);
                },
                .apply_operation => |op| {
                    dbi.gpa.free(op.operation_owned);
                },
            }
        }
    };
    const ThreadInstruction = union(enum) {
        fetch: bi.BlockID,
        create_block: struct { block_id: bi.BlockID, initial_value_owned: bi.AlignedByteSlice },
        apply_operation: struct { block_id: bi.BlockID, operation_owned: bi.AlignedByteSlice },

        /// may be called from any thread
        pub fn deinit(self: ThreadInstruction, dbi: *BlockDB) void {
            switch (self) {
                .fetch => {},
                .create_block => |bl| {
                    dbi.gpa.free(bl.initial_value_owned);
                },
                .apply_operation => |op| {
                    dbi.gpa.free(op.operation_owned);
                },
            }
        }
    };

    pub fn init(gpa: std.mem.Allocator) BlockDB {
        return .{
            .gpa = gpa,

            .path_to_blockref_map = .init(gpa),

            .send_queue = .init(gpa),
            .recv_queue = .init(gpa),
        };
    }

    /// any other threads watching the thread queue must be joined before deinit is called
    pub fn deinit(self: *BlockDB) void {
        // clear send_queue
        for (self.send_queue._raw_queue.readableSlice(0)) |*item| {
            item.deinit(self);
        }
        self.send_queue.deinit();

        // clear recv_queue
        self.tick();
        self.recv_queue.deinit();

        // blockrefs have a reference to the block interface so they better be gone
        for (self.path_to_blockref_map.values()) |ref| {
            std.log.err("leaked block: {}", .{ref.id});
        }
        std.debug.assert(self.path_to_blockref_map.values().len == 0);
        self.path_to_blockref_map.deinit();
    }
    pub fn tick(self: *BlockDB) void {
        // apply any waiting changes on the main thread
        while (self.recv_queue.tryRead()) |item| {
            defer item.deinit(self);
            switch (item) {
                .apply_operation => |op| {
                    if (self.path_to_blockref_map.get(op.block)) |block_ref| {
                        if (block_ref.contents()) |contents| if (contents.server()) |server| {
                            server.vtable.applyOperation(server, op.operation_owned, null) catch {
                                // yikes
                                std.log.err("recieved invalid operation from server", .{});
                                continue;
                            };

                            const unapplied_operations_queue = block_ref.unapplied_operations_queue.readableSlice(0);
                            const first_unapplied_operation = if (unapplied_operations_queue.len == 0) "" else unapplied_operations_queue[0];
                            if (std.mem.eql(u8, op.operation_owned, first_unapplied_operation)) {
                                // operation is identical to our first local change (may be someone else's, that's ok)
                                const owned = block_ref.unapplied_operations_queue.readItem().?;
                                block_ref.unapplied_operations_queue.allocator.free(owned);
                            } else if (contents.vtable.is_crdt) {
                                // operation is someone else's, but block is a crdt so order does not matter
                                contents.client().vtable.applyOperation(contents.client(), op.operation_owned, null) catch @panic("server operation was valid once but not twice?");
                            } else if (unapplied_operations_queue.len > 0) {
                                // operation is someone else's and we have local changes
                                contents.client().vtable.deinit(contents.client());
                                contents.client_data = server.clone(self.gpa).data;
                                for (unapplied_operations_queue) |unapplied_operation| {
                                    contents.client().vtable.applyOperation(contents.client(), unapplied_operation, null) catch @panic("invalid client operation");
                                }
                            } else {
                                // operation is someone else's but we have no local changes
                                std.debug.assert(unapplied_operations_queue.len == 0);
                                contents.client().vtable.applyOperation(contents.client(), op.operation_owned, null) catch @panic("server operation was valid once but not twice?");
                            }
                        };
                    }
                },
                .load_block => |op| {
                    if (self.path_to_blockref_map.get(op.block)) |block_ref| {
                        if (block_ref.contents()) |contents| {
                            if (contents.server()) |_| {
                                std.log.info("discarded load_block operation as server is already filled for block {}", .{op.block});
                            } else {
                                const dsrlz = contents.vtable.deserialize(self.gpa, op.value_owned) catch {
                                    std.log.err("recieved invalid block from server", .{});
                                    continue;
                                };
                                contents.server_data = dsrlz.data;
                            }
                        } else {
                            @panic("TODO"); // we need to know what type the block is so we can deserialize with the right
                            // vtable. that information isn't in load_block yet.
                        }
                    }
                },
            }
        }
    }

    /// Takes ownership of the passed-in AnyBlock. Returns a referenced BlockRef - make sure to unref when you're done with it!
    pub fn createBlock(self: *BlockDB, initial_value: bi.AnyBlock) *BlockRef {
        const generated_id = bi.BlockID.fromRandom(std.crypto.random);

        const new_blockref = self.gpa.create(BlockRef) catch @panic("oom");
        new_blockref.* = .{
            .db = self,
            .id = generated_id,

            .ref_count = 1,
            .unapplied_operations_queue = .init(self.gpa),

            ._contents = .{
                .vtable = initial_value.vtable,
                .server_data = null,
                .client_data = initial_value.data,
            },
        };
        self.path_to_blockref_map.put(new_blockref.id, new_blockref) catch @panic("oom");

        var initial_value_owned_al = bi.AlignedArrayList.init(self.gpa);
        defer initial_value_owned_al.deinit();

        initial_value.vtable.serialize(initial_value, &initial_value_owned_al);

        self.send_queue.write(.{
            .create_block = .{
                .block_id = new_blockref.id,
                .initial_value_owned = initial_value_owned_al.toOwnedSlice() catch @panic("oom"),
            },
        });

        return new_blockref;
    }

    /// returns a ref'd BlockRef! make sure to unref it when you're done with it!
    fn fetchBlock(self: *BlockDB, id: bi.BlockID) *BlockRef {
        const new_blockref = self.gpa.create(BlockRef) catch @panic("oom");
        new_blockref.* = .{
            .db = self,
            .id = id,

            .ref_count = 1,
            .unapplied_operations_queue = .init(self.gpa),

            ._contents = null,
        };

        self.path_to_blockref_map.put(id, new_blockref) catch @panic("oom");

        self.send_queue.write(.{ .fetch = new_blockref.id });

        return new_blockref;
    }
    /// call this after the operation has been applied to client_value and added to the queue
    /// to save it.
    fn submitOperation(self: *BlockDB, block: *BlockRef, op_unowned: bi.AlignedByteSlice) void {
        const op_owned = self.gpa.alignedAlloc(u8, 16, op_unowned.len) catch @panic("oom");
        @memcpy(op_owned, op_unowned);

        self.send_queue.write(.{ .apply_operation = .{ .block_id = block.id, .operation_owned = op_owned } });
    }
    fn destroyBlock(self: *BlockDB, block: *BlockRef) void {
        std.debug.assert(block.ref_count == 0);

        if (block.contents()) |contents| {
            if (contents.server()) |server| server.vtable.deinit(server);
            contents.client().vtable.deinit(contents.client());
        }
        for (block.unapplied_operations_queue.readableSlice(0)) |str| {
            block.unapplied_operations_queue.allocator.free(str);
        }
        block.unapplied_operations_queue.deinit();

        if (!self.path_to_blockref_map.swapRemove(block.id)) @panic("block not found");

        self.gpa.destroy(block);
    }
};

fn AtomicMutexValue(comptime T: type) type {
    return struct {
        const Self = @This();
        mutex: std.Thread.Mutex,
        raw: T,

        fn lockAndUse(self: *Self) *T {
            self.mutex.lock();
            return self.raw;
        }
        fn unlock(self: *Self) void {
            self.mutex.unlock();
        }
    };
}

// a component is part of a block
pub fn TypedComponentRef(comptime ComponentType_arg: type) type {
    // most of this doesn't have to be comptime
    // only a few functions need to change based on the arg
    return struct {
        const Self = @This();
        block_ref: *BlockRef,
        prefix: bi.AlignedByteSlice,
        value: *ComponentType,

        pub const ComponentType = ComponentType_arg;

        pub fn ref(self: Self) void {
            self.block_ref.ref();
        }
        pub fn unref(self: Self) void {
            self.block_ref.unref();
        }

        // tells you about high level operations applied to this block
        // for text, that is replaceRange(start, len, new_value)
        pub fn addUpdateListener(self: Self, cb: util.Callback(ComponentType.SimpleOperation, void)) void {
            _ = self;
            _ = cb;
        }
        pub fn removeUpdateListener(self: Self, cb: util.Callback(ComponentType.SimpleOperation, void)) void {
            _ = self;
            _ = cb;
        }

        pub fn applyUndoOperation(self: Self, op: bi.AlignedByteSlice, undo_op: *bi.AlignedArrayList) void {
            self.block_ref.applyOperation("", op, undo_op);
        }
        pub fn applySimpleOperation(self: Self, op: ComponentType.SimpleOperation, undo_op: ?*bi.AlignedArrayList) void {
            // since the simple op may split into multiple or zero operations, the undo op needs to be able to contain multiple or zero operations
            if (undo_op != null) @panic("TODO undo op");

            var opgen_al = std.ArrayList(ComponentType.Operation).init(self.block_ref.db.gpa);
            defer opgen_al.deinit();
            self.value.genOperations(&opgen_al, op);

            var srlz_res = bi.AlignedArrayList.init(self.block_ref.db.gpa);
            defer srlz_res.deinit();

            for (opgen_al.items) |itm| {
                srlz_res.clearRetainingCapacity();
                itm.serialize(&srlz_res);

                self.block_ref.applyOperation(self.prefix, srlz_res.items, null);
            }
        }
    };
}

pub const BlockRef = struct {
    // we would like a way for updates to announce what changed:
    // - for text, this is (old_start, old_len, new_start, inserted_text)
    //   - tree_sitter needs this to update syntax highlighting

    db: *BlockDB,
    ref_count: u32,
    id: bi.BlockID,

    _contents: ?BlockRefContents, // null if the block has not yet been fetched

    unapplied_operations_queue: util.Queue(bi.AlignedByteSlice),

    const BlockRefContents = struct {
        vtable: *const bi.BlockVtable,
        server_data: ?*anyopaque, // null if the block has not yet been acknowledged by the server
        client_data: *anyopaque,

        pub fn server(self: BlockRefContents) ?bi.AnyBlock {
            if (self.server_data) |sv| return .{ .data = sv, .vtable = self.vtable };
            return null;
        }
        pub fn client(self: BlockRefContents) bi.AnyBlock {
            return .{ .data = self.client_data, .vtable = self.vtable };
        }
    };

    pub fn contents(self: *BlockRef) ?*BlockRefContents {
        return if (self._contents) |*v| v else null;
    }

    pub fn typedComponent(self: *BlockRef, comptime BlockT: type) ?TypedComponentRef(BlockT.Child) {
        if (self.contents()) |c| {
            self.ref();
            return .{
                .block_ref = self,
                .prefix = "",
                .value = &c.client().cast(BlockT).value,
            };
        } else return null;
    }

    pub fn applyOperation(self: *BlockRef, prefix: bi.AlignedByteSlice, op: bi.AlignedByteSlice, undo_op: ?*bi.AlignedArrayList) void {
        const content: *BlockRefContents = self.contents() orelse @panic("cannot apply operation on a block that has not yet loaded");

        // clone operation (can't use dupe because it has to stay aligned)
        std.debug.assert(prefix.len == std.mem.alignForward(usize, prefix.len, 16));
        const op_clone = self.unapplied_operations_queue.allocator.alignedAlloc(u8, 16, prefix.len + op.len) catch @panic("oom");
        @memcpy(op_clone[0..prefix.len], prefix);
        @memcpy(op_clone[prefix.len..], op);

        // apply it to client contents and tell owning BlockDBInterface about the operation to eventually get it into server value
        content.client().vtable.applyOperation(content.client(), op, undo_op) catch @panic("Deserialize error only allowed on network operations");
        self.unapplied_operations_queue.writeItem(op_clone) catch @panic("oom");
        self.db.submitOperation(self, op);
    }

    pub fn ref(self: *BlockRef) void {
        self.ref_count += 1;
    }
    pub fn unref(self: *BlockRef) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.db.destroyBlock(self);
        }
    }
};
