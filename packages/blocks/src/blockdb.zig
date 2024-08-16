//! blockdb

const std = @import("std");
const bi = @import("blockinterface2.zig");

fn Queue(comptime T: type) type {
    return std.fifo.LinearFifo(T, .Dynamic);
}

const AnyBlockDB = struct {
    data: *anyopaque,
    vtable: *const BlockDBInterface,

    pub fn cast(self: AnyBlockDB, comptime T: type) *T {
        return @ptrCast(@alignCast(self.data));
    }

    pub fn from(comptime T: type, self: *T) AnyBlockDB {
        const vtable = BlockDBInterface{
            .createBlock = T.createBlock,
            .fetchBlock = T.fetchBlock,
            .destroyBlock = T.destroyBlock,
            .deinit = T.deinit,
        };
        return .{
            .data = @ptrCast(@alignCast(self)),
            .vtable = &vtable,
        };
    }
};
const BlockDBInterface = struct {
    createBlock: *const fn (self: AnyBlockDB, initial_value: bi.AnyBlock) *BlockRef, // does not have a parent. After creating the block, you should link it.
    fetchBlock: *const fn (self: AnyBlockDB, path: []const u8) *BlockRef,

    destroyBlock: *const fn (self: AnyBlockDB, block_ref: *BlockRef) void,

    deinit: *const fn (self: AnyBlockDB) void,
};

test FSBlockDBInterface {
    const gpa = std.testing.allocator;

    const interface = FSBlockDBInterface.init(gpa);
    defer interface.vtable.deinit(interface);

    const my_block = interface.vtable.fetchBlock(interface, "packages/blockeditor/src/entrypoint.zig");
    defer my_block.unref();

    // const my_created_block = interface.vtable.createBlock(interface, bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    // defer my_created_block.unref();

    // my_created_block.applyOperation()
}

const FSBlockDBInterface = struct {
    gpa: std.mem.Allocator,

    path_to_blockref_map: std.StringArrayHashMap(*BlockRef),

    _fetch_thread: ?std.Thread,
    _thread_queue: Queue(ThreadInstruction), // only touch with locked mutex
    _thread_queue_mutex: std.Thread.Mutex,
    _thread_queue_condition: std.Thread.Condition, // trigger this whenever an item is added to the ArrayList

    const ThreadInstruction = union(enum) {
        kill,
        fetch: *BlockRef,
        // TODO: this thread can also save
        // we add apply_operation: {*BlockRef, Operation}
        // whenever an operation is applied, it is added to the queue

        // consider using TCPBlockDBInterface instead of FSBlockDBInterface to start.
        // - thread 1 can send out the TCP request saying 'download current version & watch for updates'
        // - thread 2 can listen for TCP responses including 'here is current version' 'here is an update'
        // that way we can test multi client
    };

    fn init(gpa: std.mem.Allocator) AnyBlockDB {
        if (@inComptime()) @compileError("comptime");
        const self = gpa.create(FSBlockDBInterface) catch @panic("oom");
        self.* = .{
            .gpa = gpa,

            .path_to_blockref_map = std.StringArrayHashMap(*BlockRef).init(gpa),

            ._fetch_thread = null,
            ._thread_queue = Queue(ThreadInstruction).init(gpa),
            ._thread_queue_mutex = .{},
            ._thread_queue_condition = .{},
        };

        self._fetch_thread = std.Thread.spawn(.{}, workerThread, .{self}) catch @panic("thread spawn error");

        return AnyBlockDB.from(FSBlockDBInterface, self);
    }
    fn deinit(any: AnyBlockDB) void {
        const self = any.cast(FSBlockDBInterface);

        const thread = self._fetch_thread.?;
        // clear job queue and append kill command
        // * maybe rather than clearing the job queue, we should try to allow it to drain? you could lose data
        {
            self._thread_queue_mutex.lock();
            defer self._thread_queue_mutex.unlock();

            for (self._thread_queue.readableSlice(0)) |item| {
                switch (item) {
                    .kill => unreachable,
                    .fetch => |fetch_block| {
                        fetch_block.unref();
                    },
                }
            }
            self._thread_queue.discard(self._thread_queue.readableLength());
            self._thread_queue.writeItem(.kill) catch @panic("oom");
        }
        self._thread_queue_condition.signal();

        // join thread
        thread.join();

        self._thread_queue.deinit(); // don't have to worry about the mutex anymore, the thread is gone

        // blockrefs have a reference to the block interface so they better be gone
        std.debug.assert(self.path_to_blockref_map.values().len == 0);
        self.path_to_blockref_map.deinit();

        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn workerThread(self: *FSBlockDBInterface) void {
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
                    std.log.info("TODO fetch & watch: '{}'", .{std.zig.fmtEscapes(block.path)});
                    std.time.sleep(300 * std.time.ns_per_ms); // simulate network latency
                    std.log.info("-> fetched", .{});

                    // block._contents_or_undefined = ...;
                    // block.loaded.store(true, .acquire); // acquire to make sure the previous store is in the right order
                    block.unref();
                },
            }
        }
    }

    /// Takes ownership of the passed-in AnyBlock. Returns a referenced BlockRef - make sure to unref when you're done with it!
    fn createBlock(any: AnyBlockDB, initial_value: bi.AnyBlock) *BlockRef {
        const self = any.cast(FSBlockDBInterface);

        // TODO:
        // - Create the BlockRef with:
        //   - loaded is true
        //   - server_value is initial_value
        //   - client_value is initial_value cloned
        //   - path is (????) we need to generate a uuid or something
        // - Submit a request to the queue holding this BlockRef (& ref it) containing:
        //   - create_block(path, initial_value)
        //   - if we generate a properly random path, the server should not respond with an error
        // - Done

        _ = self;
        _ = initial_value;

        @panic("TODO createBlock");
    }

    /// returns a ref'd BlockRef! make sure to unref it when you're done with it!
    fn fetchBlock(any: AnyBlockDB, path: []const u8) *BlockRef {
        const self = any.cast(FSBlockDBInterface);

        const path_copy = self.gpa.dupe(u8, path) catch @panic("oom");
        errdefer self.gpa.free(path_copy);

        const new_blockref = self.gpa.create(BlockRef) catch @panic("oom");
        new_blockref.* = .{
            .db = any,
            .path = path_copy,

            .ref_count = .{ .raw = 1 },
            .unapplied_operations_queue = Queue(bi.AlignedByteSlice).init(self.gpa),
        };

        self.path_to_blockref_map.put(path, new_blockref) catch @panic("oom");

        {
            self._thread_queue_mutex.lock();
            defer self._thread_queue_mutex.unlock();

            new_blockref.ref(); // to make sure it doesn't get deleted until after it has loaded
            self._thread_queue.writeItem(.{ .fetch = new_blockref }) catch @panic("oom");
        }
        self._thread_queue_condition.signal();

        return new_blockref;
    }
    fn destroyBlock(any: AnyBlockDB, block: *BlockRef) void {
        std.debug.assert(block.ref_count.load(.acquire) == 0);

        if (block.contents()) |contents| {
            contents.server_value.vtable.deinit(contents.server_value);
            contents.client_value.vtable.deinit(contents.client_value);
        }
        block.unapplied_operations_queue.deinit();

        const self = any.cast(FSBlockDBInterface);

        if (!self.path_to_blockref_map.swapRemove(block.path)) @panic("block not found");

        self.gpa.free(block.path);
        self.gpa.destroy(block);
    }
};

const BlockRef = struct {
    db: AnyBlockDB,
    ref_count: std.atomic.Value(u32),
    path: []const u8,

    loaded: std.atomic.Value(bool) = .{ .raw = false }, // once this is true it will never turn false again.
    _contents_or_undefined: BlockRefContents = undefined,

    unapplied_operations_queue: Queue(bi.AlignedByteSlice),

    const BlockRefContents = struct {
        server_value: bi.AnyBlock,
        client_value: bi.AnyBlock,
    };

    pub fn contents(self: *BlockRef) ?*BlockRefContents {
        if (!self.loaded.load(.acquire)) return null;
        return &self._contents_or_undefined;
    }

    pub fn applyOperation(self: *BlockRef, op: bi.AlignedByteSlice, undo_op: *bi.AlignedArrayList) void {
        const content: *BlockRefContents = self.contents() orelse @panic("cannot apply operation on a block that has not yet loaded");

        // clone operation (can't use dupe because it has to stay aligned)
        const op_clone = self.unapplied_operations_queue.allocator.alignedAlloc(u8, 16, op.len) catch @panic("oom");
        @memcpy(op_clone, op);
        self.unapplied_operations_queue.append(op_clone);

        // apply it to contents and tell owning BlockDBInterface about the operation
        content.client_value.vtable.applyOperation(content.client_value, op, undo_op) catch @panic("Deserialize error only allowed on network operations");
        self.unapplied_operations_queue.append(op_clone);
        self.db.vtable.submitOperation(self.db, op);
    }

    pub fn ref(self: *BlockRef) void {
        _ = self.ref_count.rmw(.Add, 1, .acq_rel);
    }
    pub fn unref(self: *BlockRef) void {
        const prev_val = self.ref_count.rmw(.Sub, 1, .acq_rel);
        if (prev_val == 1) {
            self.db.vtable.destroyBlock(self.db, self);
        }
    }
};
