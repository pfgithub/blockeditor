const std = @import("std");
const ws = @import("websocket");

const App = struct { client: ws.Client };

pub fn main() !void {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();

    var app: App = .{
        .client = try ws.Client.init(gpa, .{
            .port = 9224,
            .host = "localhost",
        }),
    };
    defer app.client.deinit();

    try app.client.handshake("/ws", .{
        .timeout_ms = 10_000,
        .headers = "Host: localhost:9224", // separate multiple headers with \r\n
    });

    const recv_thread = try std.Thread.spawn(.{}, recvThread, .{&app});
    defer recv_thread.join();

    std.log.info("wsnc. enter to exit", .{});

    // wait for enter key to be pressed
    while (true) {
        const msg = try std.io.getStdIn().reader().readUntilDelimiterAlloc(gpa, '\n', std.math.maxInt(usize));
        defer gpa.free(msg);
        if (std.mem.eql(u8, msg, "") or std.mem.eql(u8, msg, "\r")) {
            // exit
            break;
        }
        std.log.info("sending \"{}\"...", .{std.zig.fmtEscapes(msg)});
        try app.client.writeBin(msg);
        std.log.info("-> sent", .{});
    }

    std.log.info("closing...", .{});
    try app.client.close(.{});
    std.log.info("-> closed", .{});
}

fn recvThread(self: *App) void {
    while (true) {
        const msg = (self.client.read() catch return) orelse unreachable;
        defer self.client.done(msg);

        std.log.info("received message: \"{}\"", .{std.zig.fmtEscapes(msg.data)});
    }
}
