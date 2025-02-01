const std = @import("std");
const rvemu = @import("rvemu");

pub fn main() !void {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}).init;
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var rem = args[1..];
    const itms = @divFloor(rem.len, 2);
    var progress = std.Progress.start(.{ .root_name = "rv tests", .estimated_total_items = itms });
    defer progress.end();

    std.log.info("running tests", .{});
    for (rem) |itm| {
        std.log.info("  {s}", .{itm});
    }

    while (rem.len > 1) {
        const src = rem[0];
        const dst = rem[1];
        rem = rem[2..];

        const mem_ptr = try gpa.alignedAlloc(u8, @alignOf(u128), 2097152); // 2mb
        errdefer gpa.free(mem_ptr);
        for (mem_ptr) |*b| b.* = 0;

        var node = progress.start(std.fs.path.basename(dst), 0);
        defer node.end();

        const disk = try std.fs.cwd().readFileAllocOptions(gpa, src, 1000000000, null, @alignOf(u128), null);
        defer gpa.free(disk);

        var emu: rvemu.Emulator = .{ .memory = mem_ptr };
        try emu.loadElf(disk);

        // start emu-lating
        while (true) {
            emu.run() catch |e| switch (e) {
                error.Ecall => {
                    @panic("TODO ecall");
                },
                else => return e,
            };
        }
    }
    if (rem.len != 0) return error.BadArgs;
}
