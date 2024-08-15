//! blockdb

const std = @import("std");
const bi = @import("blockinterface.zig");

const AnyBlockDB = struct {
    data: *anyopaque,
    vtable: *const BlockDBInterface,

    pub fn cast(self: AnyBlockDB, comptime T: type) *T {
        return @ptrCast(@alignCast(self.data));
    }

    pub fn from(comptime T: type, self: *T) AnyBlockDB {
        const vtable = BlockDBInterface{
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
}

const FSBlockDBInterface = struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread,

    path_to_blockref_map: std.StringArrayHashMap(*BlockRef),

    _thread_queue: std.ArrayList(ThreadInstruction), // only touch with locked mutex
    _thread_queue_mutex: std.Thread.Mutex,
    _thread_queue_condition: std.Thread.Condition, // trigger this whenever an item is added to the ArrayList

    const ThreadInstruction = union(enum) {
        kill,
        fetch: *BlockRef,
    };

    fn init(gpa: std.mem.Allocator) AnyBlockDB {
        if (@inComptime()) @compileError("comptime");
        const self = gpa.create(FSBlockDBInterface) catch @panic("oom");
        self.* = .{
            .gpa = gpa,
            .thread = null,

            .path_to_blockref_map = std.StringArrayHashMap(*BlockRef).init(gpa),

            ._thread_queue = std.ArrayList(ThreadInstruction).init(gpa),
            ._thread_queue_mutex = .{},
            ._thread_queue_condition = .{},
        };

        self.thread = std.Thread.spawn(.{}, workerThread, .{self}) catch @panic("thread spawn error");

        return AnyBlockDB.from(FSBlockDBInterface, self);
    }
    fn deinit(any: AnyBlockDB) void {
        const self = any.cast(FSBlockDBInterface);

        if (self.thread) |thread| {
            // clear job queue and append kill command
            {
                self._thread_queue_mutex.lock();
                defer self._thread_queue_mutex.unlock();

                for (self._thread_queue.items) |item| {
                    switch (item) {
                        .kill => unreachable,
                        .fetch => |fetch_block| {
                            fetch_block.unref();
                        },
                    }
                }
                self._thread_queue.clearRetainingCapacity();
                self._thread_queue.append(.kill) catch @panic("oom");
            }
            self._thread_queue_condition.signal();

            // join thread
            thread.join();

            self._thread_queue.deinit(); // don't have to worry about the mutex anymore, the thread is gone
        }

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

                while (self._thread_queue.items.len == 0) {
                    self._thread_queue_condition.wait(&self._thread_queue_mutex);
                }

                break :blk self._thread_queue.orderedRemove(0);
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
                    block.unref();
                },
            }
        }
    }

    // returns a ref'd BlockRef! make sure to unref it when you're done with it!
    fn fetchBlock(any: AnyBlockDB, path: []const u8) *BlockRef {
        const self = any.cast(FSBlockDBInterface);

        const path_copy = self.gpa.dupe(u8, path) catch @panic("oom");
        errdefer self.gpa.free(path_copy);

        const new_blockref = self.gpa.create(BlockRef) catch @panic("oom");
        new_blockref.* = .{
            .db = any,
            .path = path_copy,

            .ref_count = .{ .raw = 1 },
        };

        self.path_to_blockref_map.put(path, new_blockref) catch @panic("oom");

        {
            self._thread_queue_mutex.lock();
            defer self._thread_queue_mutex.unlock();

            new_blockref.ref(); // to make sure it doesn't get deleted until after it has loaded
            self._thread_queue.append(.{ .fetch = new_blockref }) catch @panic("oom");
        }
        self._thread_queue_condition.signal();

        return new_blockref;
    }
    fn destroyBlock(any: AnyBlockDB, block: *BlockRef) void {
        std.debug.assert(block.ref_count.load(.monotonic) == 0);

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

    loaded: std.atomic.Value(bool) = .{ .raw = false },
    _contents_or_undefined: bi.AnyBlock = undefined,

    pub fn contents(self: BlockRef) ?bi.AnyBlock {
        if (!self.loaded.load(.monotonic)) return null;
        return self._contents_or_undefined;
    }

    pub fn applyOperation(self: *BlockRef, op: bi.AnyOperation) void {
        if (self.contents == null) @panic("cannot apply operation until BlockRef has loaded");
        // apply it to contents and tell owning BlockDBInterface about the operation

        _ = op;
        @panic("TODO impl applyOperation");
    }

    pub fn ref(self: *BlockRef) void {
        _ = self.ref_count.rmw(.Add, 1, .monotonic);
    }
    pub fn unref(self: *BlockRef) void {
        const prev_val = self.ref_count.rmw(.Sub, 1, .monotonic);
        if (prev_val == 1) {
            self.db.vtable.destroyBlock(self.db, self);
        }
    }
};
