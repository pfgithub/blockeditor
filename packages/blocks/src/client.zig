const std = @import("std");
const db_mod = @import("blockdb.zig");
const log = std.log.scoped(.tcp_client);

fn simulateNetworkLatency() void {
    std.time.sleep(300 * std.time.ns_per_ms);
}

pub const TcpSync = struct {
    gpa: std.mem.Allocator,
    db: *db_mod.BlockDB,
    send_thread: std.Thread,
    recv_thread: std.Thread,
    should_kill: std.atomic.Value(bool),
    host_name_clone: []const u8,
    port: u16,

    conn_2: ?std.net.Stream,
    conn_2_ready: std.Thread.Semaphore,

    pub fn create(gpa: std.mem.Allocator, db: *db_mod.BlockDB, host_name: []const u8, port: u16) *TcpSync {
        const self = gpa.create(TcpSync) catch @panic("oom");
        self.* = .{
            .gpa = gpa,
            .db = db,
            .should_kill = .{ .raw = false },
            .send_thread = undefined,
            .recv_thread = undefined,
            .host_name_clone = gpa.dupe(u8, host_name) catch @panic("oom"),
            .port = port,
            .conn_2 = null,
            .conn_2_ready = .{},
        };
        self.recv_thread = std.Thread.spawn(.{}, recvThread, .{self}) catch @panic("thread spawn error");
        self.send_thread = std.Thread.spawn(.{}, sendThread, .{self}) catch @panic("thread spawn error");
        return self;
    }
    pub fn destroy(self: *TcpSync) void {
        log.info("beginning to kill threads", .{});
        {
            self.conn_2_ready.wait();
            if (self.conn_2) |conn| {
                std.log.err("closing conn", .{});
                std.posix.shutdown(conn.handle, .recv) catch @panic("shutdown error");
            }
        }
        log.err("-> signaled recvThread to die", .{});
        self.should_kill.store(true, .monotonic);
        self.db.send_queue.signal();
        log.err("-> signaled sendThread to die", .{});
        self.recv_thread.join();
        log.err("-> recv thread joined", .{});
        self.send_thread.join();
        log.err("-> send thread joined", .{});

        self.gpa.free(self.host_name_clone);

        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn recvThread(self: *TcpSync) void {
        {
            defer for (0..2) |_| self.conn_2_ready.post();

            self.conn_2 = std.net.tcpConnectToHost(self.gpa, "localhost", self.port) catch |e| {
                log.err("tcp recv error: {s}", .{@errorName(e)});
                return;
            };
            std.log.err("conn available", .{});
        }

        while (true) {
            var buf: [1024]u8 = undefined;
            log.err("waiting on read...", .{});
            const len = self.conn_2.?.read(&buf) catch |e| {
                log.err("tcp read error: {s}", .{@errorName(e)});
                // don't do this, we don't wrap conn with a mutex in other accesses
                // self.conn_available.lock();
                // self.conn = null;
                // self.conn_available.unlock();
                return;
            };
            if (len == 0) return;
            log.err("read success: {d}: \"{}\"", .{ len, std.zig.fmtEscapes(buf[0..len]) });
        }

        self.conn_2.?.close();
    }
    fn sendThread(self: *TcpSync) void {
        // wait for connection to become available
        self.conn_2_ready.wait();

        // don't run if connection fails
        if (self.conn_2 == null) return;

        while (true) {
            // take job
            const job = self.db.send_queue.waitRead(&self.should_kill) orelse return;
            // free job resources
            defer self.db.recv_queue.write(.{ .deinit_instruction = job });

            // execute job
            switch (job) {
                .fetch => |block| {
                    log.info("TODO fetch & watch: '{}'", .{block.id});
                    simulateNetworkLatency();
                    log.info("-> fetched", .{});

                    // block._contents_or_undefined = ...;
                    // block.loaded.store(true, .acquire); // acquire to make sure the previous store is in the right order
                },
                .create_block => |block| {
                    simulateNetworkLatency();

                    const op_owned_2 = self.gpa.alignedAlloc(u8, 16, block.initial_value_owned.len) catch @panic("oom");
                    @memcpy(op_owned_2, block.initial_value_owned);

                    self.db.recv_queue.write(.{ .load_block = .{ .block = block.block.id, .value_owned = op_owned_2 } });
                },
                .apply_operation => |block| {
                    simulateNetworkLatency();

                    const op_owned_2 = self.gpa.alignedAlloc(u8, 16, block.operation_owned.len) catch @panic("oom");
                    @memcpy(op_owned_2, block.operation_owned);

                    self.db.recv_queue.write(.{ .apply_operation = .{ .block = block.block.id, .operation_owned = op_owned_2 } });
                },
            }
        }
    }
};

// test "create failure" {
//     const gpa = std.testing.allocator;

//     var db = db_mod.BlockDB.init(gpa);
//     defer db.deinit();

//     var sync = TcpSync.create(gpa, &db, "localhost", 12388);
//     defer sync.destroy();
// }

// test "create success" {
//     const gpa = std.testing.allocator;

//     var server_exe = std.process.Child.init(&.{"zig-out/bin/server"}, gpa);
//     server_exe.stdout_behavior = .Pipe;
//     server_exe.stderr_behavior = .Inherit;
//     try server_exe.spawn();
//     defer blk: {
//         const term = server_exe.kill() catch break :blk;
//         _ = term;
//     }
//     log.info("Waiting for msg", .{});
//     var read_buf: [16]u8 = undefined;
//     const read_len = try server_exe.stdout.?.read(&read_buf);
//     try std.testing.expectEqualStrings("Started.\n", read_buf[0..read_len]);
//     log.info("Got msg, init", .{});

//     var db = db_mod.BlockDB.init(gpa);
//     defer db.deinit();
//     log.info("Got init, cont.d", .{});

//     var sync = TcpSync.create(gpa, &db, "localhost", 8499);
//     defer sync.destroy();
//     log.info("Got init, cont.d2", .{});
// }
