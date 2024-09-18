const std = @import("std");
const ws = @import("websocket");

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
    pub fn clientMessage(self: *Handler, data: []const u8) !void {
        try self.conn.write(data); // echo the message back
    }
};

// This is application-specific you want passed into your Handler's
// init function.
const App = struct {
    // maybe a db pool
    // maybe a list of rooms
};
