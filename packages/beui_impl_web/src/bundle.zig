const std = @import("std");

pub fn main() !void {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();
    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    const arena = arena_backing.allocator();
    const args = try std.process.argsAlloc(arena);

    if (args.len < 4) return error.BadArgs;

    const wasm_file = args[1];
    const html_file = args[2];
    const output_dir = args[3];

    _ = try std.fs.cwd().updateFile(wasm_file, std.fs.cwd(), try std.fs.path.join(arena, &.{ output_dir, "wasm_part.wasm" }), .{});
    _ = try std.fs.cwd().updateFile(html_file, std.fs.cwd(), try std.fs.path.join(arena, &.{ output_dir, "index.html" }), .{});
}
