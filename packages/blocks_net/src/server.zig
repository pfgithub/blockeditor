const std = @import("std");
const ws = @import("websocket");
const shared = @import("shared.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try ws.Server(Handler).init(allocator, .{
        .port = 9224,
        .address = "127.0.0.1",
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            // since we aren't using hanshake.headers
            // we can set this to 0 to save a few bytes.
            .max_headers = 0,
        },
    });

    // Arbitrary (application-specific) data to pass into each handler
    // Pass void ({}) into listen if you have none
    var app = App{};

    // this blocks
    try server.listen(&app);
}

// This is your application-specific wrapper around a websocket connection
const Handler = struct {
    app: *App,
    conn: *ws.Conn,

    // You must define a public init function which takes
    pub fn init(h: ws.Handshake, conn: *ws.Conn, app: *App) !Handler {
        // `h` contains the initial websocket "handshake" request
        // It can be used to apply application-specific logic to verify / allow
        // the connection (e.g. valid url, query string parameters, or headers)

        _ = h; // we're not using this in our simple case

        return .{
            .app = app,
            .conn = conn,
        };
    }

    // You must defined a public clientMessage method
    pub fn clientMessage(self: *Handler, data: []const u8, message_type: ws.MessageType) !void {
        if (message_type != .binary) return error.BadMessage;
        // simulate network latency
        // std.time.sleep(300 * std.time.ns_per_ms);
        // TODO better network latency sim

        var fbs_backing = std.io.fixedBufferStream(data);
        const fbs = fbs_backing.reader().any();

        while (fbs_backing.pos < fbs_backing.buffer.len) {
            const msg = try fbs.readStructEndian(shared.message_header_v1, .little);
            if (msg.remaining_length > std.math.maxInt(u32)) return error.BadMessage;
            if (fbs_backing.pos + msg.remaining_length > fbs_backing.buffer.len) break;
            const content = fbs_backing.buffer[fbs_backing.pos..][0..msg.remaining_length];
            fbs_backing.pos += msg.remaining_length;

            switch (msg.tag) {
                .create_block => {
                    std.log.info("TODO: create_block {d}", .{content.len});
                },
                .apply_operation => {
                    std.log.info("TODO: apply_operation {d}", .{content.len});
                },
                .fetch_and_watch_block => {
                    if (content.len != 0) return error.BadMessage;
                    std.log.info("TODO: fetch_and_watch_block {d}", .{content.len});
                },
                .unwatch_block => {
                    if (content.len != 0) return error.BadMessage;
                    std.log.info("TODO: unwatch_block {d}", .{content.len});
                },
                else => return error.BadMessage,
            }
        }

        _ = self;
        // try self.conn.write(data);
    }
};

// This is application-specific you want passed into your Handler's
// init function.
const App = struct {
    // maybe a db pool
    // maybe a list of rooms
};
