const std = @import("std");
const ws = @import("websocket");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const log = std.log.scoped(.tcp_client);

pub const TcpSync = struct {
    gpa: std.mem.Allocator,
    db: *db_mod.BlockDB,

    client: ?ws.Client,
    client_available_to_close: std.Thread.Semaphore,
    client_ready_to_send: std.Thread.Semaphore,
    closed: std.atomic.Value(bool),
    kill_send_thread: std.atomic.Value(bool),
    write_mutex: std.Thread.Mutex,

    send_thread: std.Thread,
    recv_thread: std.Thread,

    pub fn init(self: *TcpSync, gpa: std.mem.Allocator, db: *db_mod.BlockDB) void {
        self.* = .{
            .gpa = gpa,
            .db = db,
            .client = undefined,
            .client_available_to_close = .{},
            .client_ready_to_send = .{},
            .closed = .{ .raw = false },
            .kill_send_thread = .{ .raw = false },
            .write_mutex = .{},
            .send_thread = undefined,
            .recv_thread = undefined,
        };

        self.recv_thread = std.Thread.spawn(.{}, recvThread, .{self}) catch @panic("spawn recv_thread fail");
        self.send_thread = std.Thread.spawn(.{}, sendThread, .{self}) catch @panic("spawn send_thread fail");
    }

    pub fn deinit(self: *TcpSync) void {
        log.info("deinit TcpSync", .{});

        self.kill_send_thread.store(true, .monotonic);
        self.db.send_queue.signal();

        log.info("-> wait for client ready", .{});
        self.client_available_to_close.wait();
        log.info("-> client ready, close stream", .{});
        self._close();
        log.info("-> stream closed, join recv thread", .{});
        self.recv_thread.join();

        log.info("-> recv thread closed, join send thread", .{});
        self.send_thread.join();

        if (self.client) |*client| {
            client.deinit();
        }
    }

    fn _close(self: *TcpSync) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        self.closed.store(true, .monotonic);
        // ok to call close twice
        if (self.client) |*client| {
            client.close(.{ .code = 4000, .reason = "bye" }) catch |e| switch (e) {
                error.ReasonTooLong => unreachable,
            };
        }
    }

    fn recvThread(self: *TcpSync) void {
        self.recvThread_error() catch |e| {
            log.err("recv thread fail: {s}", .{@errorName(e)});
            self._close();
            return;
        };
    }
    fn recvThread_error(self: *TcpSync) !void {
        {
            defer self.client_ready_to_send.post();
            {
                defer self.client_available_to_close.post();
                self.client = ws.Client.init(self.gpa, .{
                    .port = 9224,
                    .host = "localhost",
                }) catch |e| blk: {
                    log.err("init fail: {s}", .{@errorName(e)});
                    break :blk null;
                };
            }
            if (self.client == null) return;

            try self.client.?.handshake("/ws", .{
                .timeout_ms = 10_000,
                .headers = "Host: localhost:9224", // separate multiple headers with \r\n
            });
        }

        // self.client.?.readTimeout(1000) catch {};
        while (true) {
            const msg = self.client.?.read() catch |e| {
                log.err("read fail: {s}", .{@errorName(e)});
                self._close();
                return;
            } orelse continue; // no timeout = never null

            switch (msg.type) {
                .text, .binary => {
                    log.info("received: \"{}\"", .{std.zig.fmtEscapes(msg.data)});
                    // self.write_mutex.lock(); defer self.write_mutex.unlock(); try self.client.?.write(msg.data);
                },
                .ping => {
                    try self.client.?.writePong(msg.data);
                },
                .pong => {},
                .close => {
                    return error.ConnectionClosedByServer;
                },
            }
        }
    }
    fn sendThread(self: *TcpSync) void {
        self.client_ready_to_send.wait();
        if (self.client == null) return;
        if (self.closed.load(.monotonic)) return;

        while (self.db.send_queue.waitRead(&self.kill_send_thread)) |item| {
            defer item.deinit(self.db);

            switch (item) {
                .fetch => |op| {
                    log.info("TODO fetch block: {}", .{op});
                },
                .create_block => |op| {
                    log.info("TODO create block: {}/{d}", .{ op.block_id, op.initial_value_owned.len });
                },
                .apply_operation => |op| {
                    log.info("TODO apply operation: {}/{d}", .{ op.block_id, op.operation_owned.len });
                },
            }
        }
    }
};
