const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var output = std.io.getStdOut();

    for (args[1..]) |arg| {
        const eql_pos = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidOrMissingKey;
        const key = arg[0..eql_pos];
        const value = arg[eql_pos + 1 ..];

        try output.writeAll(key);
        try output.writeAll("=");
        try output.writeAll(value);
        try output.writeAll("\n");
    }
}
