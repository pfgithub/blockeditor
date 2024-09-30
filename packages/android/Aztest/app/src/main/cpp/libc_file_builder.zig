const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var output = std.io.getStdOut();

    const valid_keys = .{ "include_dir", "sys_include_dir", "crt_dir", "msvc_lib_dir", "kernel32_lib_dir", "gcc_dir" };

    for (args[1..]) |arg| {
        const eql_pos = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidOrMissingKey;
        const key = arg[0..eql_pos];
        const value = arg[eql_pos..];

        inline for (valid_keys) |valid_key| {
            if (std.mem.eql(u8, valid_key, key)) {
                try output.writeAll(valid_key ++ "=");
                try output.writeAll(value);
                try output.writeAll("\n");
            }
        }
    }
}