const std = @import("std");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const gpa = gpa_alloc.allocator();

    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 3667);
    var server = try addr.listen(.{});

    std.log.info("Server listening on port 3667", .{});

    var client = try server.accept();
    defer client.stream.close();

    const client_reader = client.stream.reader();
    const client_writer = client.stream.writer();
    while (true) {
        const msg = try client_reader.readUntilDelimiterOrEofAlloc(gpa, '\n', 65536) orelse break;
        defer gpa.free(msg);

        std.log.info("Recieved message: \"{}\"", .{std.zig.fmtEscapes(msg)});

        try client_writer.writeAll(msg);
    }
}
