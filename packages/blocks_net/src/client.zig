const std = @import("std");
const ws = @import("websocket");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;

pub const TcpSync = struct {
    target: *db_mod.BlockDB,

    pub fn init(self: *TcpSync, target: *db_mod.BlockDB) void {
        self.* = .{ .target = target };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // create the client
    var client = try ws.Client.init(allocator, .{
        .port = 9224,
        .host = "localhost",
    });
    defer client.deinit();

    // send the initial handshake request
    const request_path = "/ws";
    try client.handshake(request_path, .{
        .timeout_ms = 1000,
        // Raw headers to send, if any.
        // A lot of servers require a Host header.
        // Separate multiple headers using \r\n
        .headers = "Host: localhost:9224",
    });

    // optional, read will return null after 1 second
    try client.readTimeout(std.time.ms_per_s * 1);

    // echo messages back to the server until the connection is closed
    while (true) {
        // since we didn't set a timeout, client.read() will either
        // return a message or an error (i.e. it won't return null)
        const message = (try client.read()) orelse {
            // no message after our 1 second
            std.debug.print(".", .{});
            continue;
        };

        // must be called once you're done processing the request
        defer client.done(message);

        switch (message.type) {
            .text, .binary => {
                std.debug.print("received: {s}\n", .{message.data});
                try client.write(message.data);
            },
            .ping => try client.writePong(message.data),
            .pong => {},
            .close => {
                // can be called from another thread and will break a blocking read
                try client.close(.{});
                break;
            },
        }
    }
}
