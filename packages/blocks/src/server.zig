const std = @import("std");
const util = @import("util.zig");

// TODO: secure
// and we need to support websockets for web site
// and ideally we use udp/webrtc over tcp/websockets so we don't
// have to wait on outdated presence information getting sent to clients

// choose between:
// - uwebsockets
//   - too complicated to build. usockets is ok but then it depends on boringssl
//     which is cmake.
//     - openssl can be used instead, and there exists a build.zig script for it
// - libxev
//   - doesn't build in latest master zig, would take a bunch of edits
// - zig-aio / iofthetiger
//
// or just keep using std.net for now, one thread per client

const Client = struct {
    conn: std.net.Server.Connection,
};
const State = struct {
    // clientToSubscriptionsMap

    global_lock: std.Thread.Mutex = .{},
    gpa: std.mem.Allocator, // thread safe

    client_id_to_connection_map: std.AutoArrayHashMap(ClientID, Client),

    msg_queue: util.Queue(Msg),
};
const Msg = union(enum) {
    recieved_message: struct {
        msg_owned: []const u8,
        from_client: ClientID,
    },
};

const ClientID = util.DistinctUUID(opaque {});

const server_data = struct {
    const msg_type = enum(u64) {
        apply_operation,
        _,
    };
    const msg_header = extern struct {
        msg_len: u64,
        msg_type: msg_type,
    };

    const apply_operation_header = extern struct {
        block_id: u128,
    };
};

fn clientRecieveThreadMayError(state: *State, client_id: ClientID) !void {
    const conn = blk: {
        state.global_lock.lock();
        defer state.global_lock.unlock();

        break :blk state.client_id_to_connection_map.get(client_id) orelse return error.ClientNotFound;
    };

    // accepts messages from clients
    const reader = conn.conn.stream.reader();

    // wait on read()
    while (true) {
        const msg_header = try reader.readStructEndian(server_data.msg_header, .little);
        const msg_buf = try state.gpa.alloc(u8, msg_header.len);
        defer state.gpa.free(msg_buf);
        try reader.readNoEof(msg_buf);
        const msg_fbs = std.io.fixedBufferStream(msg_buf);
        const msg_reader = msg_fbs.reader();

        switch (msg_header.msg_type) {
            .apply_operation => {
                const header = try msg_reader.readStructEndian(server_data.apply_operation_header, .little);
                const block_id = header.block_id;

                const operation = msg_fbs.buffer[msg_fbs.pos..];

                // 1. enter operation into database
                // 2. send operation to all connected clients observing this block
                // note: remember to ask for a savestate on occasion

                _ = block_id;
                _ = operation;
                @panic("TODO apply_operation");
            },
            else => return error.UnsupportedMessageType,
        }

        // 1. determine message type
        // 2. act on message

        // or just add them to a queue for the main thread to handle
    }
}
fn clientRecieveThread(state: *State, client_id: ClientID) !void {
    std.log.info("Client connected: {x}", .{client_id});
    clientRecieveThreadMayError(state, client_id) catch |e| {
        std.log.info("Client {x} disconnected due to error: {s}", .{ client_id, @errorName(e) });
    };
    std.log.info("Client {x} disconnected.", .{client_id});

    // TODO: try to send the client a kick message. it will fail if the client
    // has already disconnected

    std.log.warn("Thread leaked because of disconnect. TODO reuse or join the thread.", .{});
}
fn clientBroadcastThread(state: *State) void {
    // broadcasts messages to clients

    _ = state;
}

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const gpa = gpa_alloc.allocator();

    var env = try std.process.getEnvMap(gpa);
    defer env.deinit();
    const portstr = env.get("PORT") orelse "8499";

    const port = try std.fmt.parseInt(u16, portstr, 10);

    var state: State = .{
        .gpa = gpa,
        .client_id_to_connection_map = std.AutoArrayHashMap(ClientID, Client).init(gpa),

        .msg_queue = util.Queue(Msg).init(gpa),
    };

    const listen_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);

    var server = try listen_addr.listen(.{});
    defer server.deinit();

    std.log.info("Server listening on port {d}", .{listen_addr.getPort()});

    // one thread per client for now
    // later we can be fancy and std.io.poll
    // or use xev or something

    const broadcast_thread = try std.Thread.spawn(.{}, clientBroadcastThread, .{&state});
    defer broadcast_thread.join();

    var recieve_threads = std.ArrayList(std.Thread).init(gpa);
    defer recieve_threads.deinit();
    defer for (recieve_threads.items) |thread| thread.join();

    while (true) {
        const conn = try server.accept();

        const client_id = ClientID.fromRandom(std.crypto.random);

        // add client to map
        {
            state.global_lock.lock();
            defer state.global_lock.unlock();

            try state.client_id_to_connection_map.put(client_id, .{ .conn = conn });
        }

        const thread = try std.Thread.spawn(.{}, clientRecieveThread, .{ &state, client_id });
        errdefer thread.join();
        try recieve_threads.append(thread);
    }
}
