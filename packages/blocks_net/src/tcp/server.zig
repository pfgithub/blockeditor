const std = @import("std");

// TODO: secure
// and we need to support websockets for web site
// and ideally we use udp/webrtc over tcp/websockets so we don't
// have to wait on outdated presence information getting sent to clients

// choose between:
// - uwebsockets
//   - too complicated to build. no.
// - libxev / zig-aio / iofthetiger

const State = struct {
    // clientToSubscriptionsMap

    global_lock: std.Thread.Mutex = .{},
    gpa: std.mem.Allocator, // thread safe
};

fn clientRecieveThreadMayError(state: *State, conn: std.net.Server.Connection, client_id: u128) !void {
    // accepts messages from clients
    const reader = conn.stream.reader();

    // 1. add the client to the clients map
    _ = client_id;

    // 2. wait on read()
    while (true) {
        const msg_len = try reader.readInt(u64, .little);
        const msg_buf = try state.gpa.alloc(u8, msg_len);
        defer state.gpa.free(msg_buf);
        try reader.readNoEof(msg_buf);

        // 1. determine message type
        // 2. act on message
    }
}
fn clientRecieveThread(state: *State, conn: std.net.Server.Connection, client_id: u128) !void {
    std.log.info("Client connected: {x}", .{client_id});
    clientRecieveThreadMayError(state, conn, client_id) catch |e| {
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

        const client_id = std.crypto.random.int(u128);

        const thread = try std.Thread.spawn(.{}, clientRecieveThread, .{ &state, conn, client_id });
        errdefer thread.join();
        try recieve_threads.append(thread);
    }
}
