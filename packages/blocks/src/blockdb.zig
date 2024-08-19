//! blockdb

const std = @import("std");
const bi = @import("blockinterface2.zig");

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

fn Queue(comptime T: type) type {
    return std.fifo.LinearFifo(T, .Dynamic);
}

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
    my_created_block.applyOperation(my_operation_al.items, &my_undo_operation_al);
}

fn simulateNetworkLatency() void {
    std.time.sleep(300 * std.time.ns_per_ms);
}

const BlockDBInterfaceUnused = struct {
    _fetch_thread: ?std.Thread, // handled by user
    fn workerThread(self: *BlockDB) void {
        while (true) {
            // take job
            const job = blk: {
                self._thread_queue_mutex.lock();
                defer self._thread_queue_mutex.unlock();

                while (self._thread_queue.readableSlice(0).len == 0) {
                    self._thread_queue_condition.wait(&self._thread_queue_mutex);
                }

                break :blk self._thread_queue.readItem() orelse unreachable;
            };

            // execute job
            switch (job) {
                .kill => {
                    return;
                },
                .fetch => |block| {
                    std.log.info("TODO fetch & watch: '{}'", .{block.id});
                    simulateNetworkLatency();
                    std.log.info("-> fetched", .{});

                    // block._contents_or_undefined = ...;
                    // block.loaded.store(true, .acquire); // acquire to make sure the previous store is in the right order
                },
                .create_block => |block| {
                    std.log.info("TODO create_block: '{}'", .{block.block.id});
                    simulateNetworkLatency();
                    std.log.info("-> created", .{});
                },
                .apply_operation => |block| {
                    std.log.info("TODO apply operation to block: '{}'", .{block.block.id});
                    simulateNetworkLatency();
                    std.log.info("-> applied", .{});

                    // TODO:
                    // - we'll need a mutex or something:
                    //   - apply operation to ServerValue
                    //   - if std.mem.eql(unapplied_operations_queue[0], operation):
                    //     - queue.readItem()
                    //   - else:
                    //     - client_value = clone ServerValue
                    //     - for(unapplied_operations_queue.readableSlice(0)) |operation|
                    //       - client_value.applyOperation(operation)

                    // instead of locking, we could also have this happen on the main thread?
                    // like each tick call the fsblockdbinterface.update()
                    // when we get a server response we put it in a queue for the main thread to
                    // pick up and handle
                    // that's possible. that's an option.
                },
            }

            // free job resources
            job.deinit(self);
        }
    }
};
pub const BlockDB = struct {
    gpa: std.mem.Allocator,

    path_to_blockref_map: std.AutoArrayHashMap(bi.BlockID, *BlockRef),

    _thread_queue: Queue(ThreadInstruction), // only touch with locked mutex
    _thread_queue_mutex: std.Thread.Mutex,
    _thread_queue_condition: std.Thread.Condition, // trigger this whenever an item is added to the ArrayList

    const ThreadInstruction = union(enum) {
        kill,
        fetch: *BlockRef,
        create_block: struct { block: *BlockRef, initial_value_owned: bi.AlignedByteSlice },
        apply_operation: struct { block: *BlockRef, operation_owned: bi.AlignedByteSlice },

        fn deinit(self: ThreadInstruction, dbi: *BlockDB) void {
            switch (self) {
                .kill => {},
                .fetch => |ref| {
                    ref.unref();
                },
                .create_block => |bl| {
                    bl.block.unref();
                    dbi.gpa.free(bl.initial_value_owned);
                },
                .apply_operation => |op| {
                    op.block.unref();
                    dbi.gpa.free(op.operation_owned);
                },
            }
        }
    };

    pub fn init(gpa: std.mem.Allocator) BlockDB {
        return .{
            .gpa = gpa,

            .path_to_blockref_map = std.AutoArrayHashMap(bi.BlockID, *BlockRef).init(gpa),

            // ._fetch_thread = std.Thread.spawn(.{}, workerThread, .{self}) catch @panic("thread spawn error"),
            ._thread_queue = Queue(ThreadInstruction).init(gpa),
            ._thread_queue_mutex = .{},
            ._thread_queue_condition = .{},
        };
    }

    /// any other threads watching the thread queue must be joined before deinit is called
    pub fn deinit(self: *BlockDB) void {
        for (self._thread_queue.readableSlice(0)) |*item| {
            item.deinit(self);
        }
        self._thread_queue.deinit();

        // blockrefs have a reference to the block interface so they better be gone
        std.debug.assert(self.path_to_blockref_map.values().len == 0);
        self.path_to_blockref_map.deinit();
    }

    fn appendJobs(self: *BlockDB, jobs: []const ThreadInstruction) void {
        {
            self._thread_queue_mutex.lock();
            defer self._thread_queue_mutex.unlock();

            self._thread_queue.write(jobs) catch @panic("oom");
        }
        self._thread_queue_condition.signal();
    }

    /// Takes ownership of the passed-in AnyBlock. Returns a referenced BlockRef - make sure to unref when you're done with it!
    pub fn createBlock(self: *BlockDB, initial_value: bi.AnyBlock) *BlockRef {
        const generated_id = std.crypto.random.int(u128);

        const new_blockref = self.gpa.create(BlockRef) catch @panic("oom");
        new_blockref.* = .{
            .db = self,
            .id = @enumFromInt(generated_id),

            .ref_count = .{ .raw = 1 },
            .unapplied_operations_queue = Queue(bi.AlignedByteSlice).init(self.gpa),

            .loaded = .{ .raw = true },
            ._contents_or_undefined = .{
                .server_value = initial_value,
                .client_value = initial_value.clone(self.gpa),
            },
        };
        self.path_to_blockref_map.put(new_blockref.id, new_blockref) catch @panic("oom");

        var initial_value_owned_al = bi.AlignedArrayList.init(self.gpa);
        defer initial_value_owned_al.deinit();

        initial_value.vtable.serialize(initial_value, &initial_value_owned_al);

        new_blockref.ref();
        self.appendJobs(&.{.{
            .create_block = .{
                .block = new_blockref,
                .initial_value_owned = initial_value_owned_al.toOwnedSlice() catch @panic("oom"),
            },
        }});

        return new_blockref;
    }

    /// returns a ref'd BlockRef! make sure to unref it when you're done with it!
    fn fetchBlock(self: *BlockDB, id: bi.BlockID) *BlockRef {
        const new_blockref = self.gpa.create(BlockRef) catch @panic("oom");
        new_blockref.* = .{
            .db = self,
            .id = id,

            .ref_count = .{ .raw = 1 },
            .unapplied_operations_queue = Queue(bi.AlignedByteSlice).init(self.gpa),

            .loaded = .{ .raw = false },
            ._contents_or_undefined = undefined,
        };

        self.path_to_blockref_map.put(id, new_blockref) catch @panic("oom");

        new_blockref.ref();
        self.appendJobs(&.{.{ .fetch = new_blockref }});

        return new_blockref;
    }
    /// call this after the operation has been applied to client_value and added to the queue
    /// to save it.
    fn submitOperation(self: *BlockDB, block: *BlockRef, op_unowned: bi.AlignedByteSlice) void {
        const op_owned = self.gpa.alignedAlloc(u8, 16, op_unowned.len) catch @panic("oom");
        @memcpy(op_owned, op_unowned);

        block.ref();
        self.appendJobs(&.{.{ .apply_operation = .{ .block = block, .operation_owned = op_owned } }});
    }
    fn destroyBlock(self: *BlockDB, block: *BlockRef) void {
        std.debug.assert(block.ref_count.load(.acquire) == 0);

        if (block.contents()) |contents| {
            contents.server_value.vtable.deinit(contents.server_value);
            contents.client_value.vtable.deinit(contents.client_value);
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

pub const BlockRef = struct {
    // we would like a way for updates to announce what changed:
    // - for text, this is (old_start, old_len, new_start, inserted_text)
    //   - tree_sitter needs this to update syntax highlighting

    // we would like this structure to only be accessed from a single thread
    // - update FSBlockDBInterface to only apply changes on one thread, otherwise we
    //   need a mutex surrounding the whole BlockRef
    // - reference counting and 'loaded' no longer needs to be atomic

    db: *BlockDB,
    ref_count: std.atomic.Value(u32),
    id: bi.BlockID,

    loaded: std.atomic.Value(bool), // once this is true it will never turn false again.
    _contents_or_undefined: BlockRefContents,

    unapplied_operations_queue: Queue(bi.AlignedByteSlice),

    const BlockRefContents = struct {
        server_value: bi.AnyBlock,
        client_value: bi.AnyBlock,
    };

    pub fn contents(self: *BlockRef) ?*BlockRefContents {
        if (!self.loaded.load(.acquire)) return null;
        return &self._contents_or_undefined;
    }
    pub fn clientValue(self: *BlockRef) ?bi.AnyBlock {
        if (self.contents()) |c| return c.client_value;
        return null;
    }

    pub fn applyOperation(self: *BlockRef, op: bi.AlignedByteSlice, undo_op: *bi.AlignedArrayList) void {
        const content: *BlockRefContents = self.contents() orelse @panic("cannot apply operation on a block that has not yet loaded");

        // clone operation (can't use dupe because it has to stay aligned)
        const op_clone = self.unapplied_operations_queue.allocator.alignedAlloc(u8, 16, op.len) catch @panic("oom");
        @memcpy(op_clone, op);

        // apply it to client contents and tell owning BlockDBInterface about the operation to eventually get it into server value
        content.client_value.vtable.applyOperation(content.client_value, op, undo_op) catch @panic("Deserialize error only allowed on network operations");
        self.unapplied_operations_queue.writeItem(op_clone) catch @panic("oom");
        self.db.submitOperation(self, op);
    }

    pub fn ref(self: *BlockRef) void {
        _ = self.ref_count.rmw(.Add, 1, .acq_rel);
    }
    pub fn unref(self: *BlockRef) void {
        const prev_val = self.ref_count.rmw(.Sub, 1, .acq_rel);
        if (prev_val == 1) {
            self.db.destroyBlock(self);
        }
    }
};
