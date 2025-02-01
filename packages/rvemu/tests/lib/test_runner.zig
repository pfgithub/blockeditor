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

        var node = progress.start(std.fs.path.basename(dst), 0);
        defer node.end();

        const mem_ptr = try gpa.alignedAlloc(u8, @alignOf(u128), 2097152); // 2mb
        defer gpa.free(mem_ptr);
        for (mem_ptr) |*b| b.* = 0;

        const disk = try std.fs.cwd().readFileAllocOptions(gpa, src, 1000000000, null, @alignOf(u128), null);
        defer gpa.free(disk);

        var emu: rvemu.Emulator = .{ .memory = mem_ptr };
        try emu.loadElf(disk);

        var snapshot_result = std.ArrayList(u8).init(gpa);
        defer snapshot_result.deinit();

        // start emu-lating
        const exit_code: i32 = while (true) {
            emu.run() catch |e| switch (e) {
                error.Ecall => {
                    const syscall_tag: i43 = emu.readIntReg(17);
                    const syscall_args = [_]i32{
                        emu.readIntReg(10),
                        emu.readIntReg(11),
                        emu.readIntReg(12),
                        emu.readIntReg(13),
                        emu.readIntReg(14),
                        emu.readIntReg(15),
                    };
                    const res: i32 = switch (syscall_tag) {
                        1 => break syscall_args[1],
                        3 => blk: {
                            const ptr: u32 = @bitCast(syscall_args[0]);
                            const len: u32 = @bitCast(syscall_args[1]);
                            try emu.addCost(len);
                            try snapshot_result.appendSlice("[LOG] ");
                            try snapshot_result.appendSlice(try emu.readSlice(ptr, len));
                            try snapshot_result.appendSlice("\n");
                            break :blk 0;
                        },
                        else => @panic("bad ecall"),
                    };
                    emu.writeIntReg(10, res);
                    emu.pc += 4;
                },
                else => return e,
            };
        };

        try snapshot_result.writer().print("[EXIT] {d}\n", .{exit_code});

        std.log.info("RESULT:\n{s}\n", .{snapshot_result.items});
    }
    if (rem.len != 0) return error.BadArgs;
}
