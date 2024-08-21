const std = @import("std");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const gpa = gpa_alloc.allocator();

    const client = try std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3667));

    const client_reader = client.reader();
    const client_writer = client.writer();

    try client_writer.writeAll("ping!\n");

    _ = client_reader;
    _ = gpa;
}
