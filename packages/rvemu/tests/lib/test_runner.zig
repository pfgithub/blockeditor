const std = @import("std");
const rvemu = @import("rvemu");

pub fn main() !u8 {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}).init;
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var rem = args[1..];

    var update_snapshots = false;
    if (rem.len >= 1 and std.mem.eql(u8, rem[0], "-u")) {
        update_snapshots = true;
        rem = rem[1..];
    }

    const itms = @divFloor(rem.len, 2);
    var progress = std.Progress.start(.{ .root_name = "rv tests", .estimated_total_items = itms });
    defer progress.end();

    std.log.info("running tests", .{});
    for (rem) |itm| {
        std.log.info("  {s}", .{itm});
    }

    var success: bool = true;

    while (rem.len > 1) {
        const src = rem[0];
        const dst = rem[1];
        const name = std.fs.path.basename(src);
        rem = rem[2..];

        var node = progress.start(name, 0);
        defer node.end();

        const mem_ptr = try gpa.alignedAlloc(u8, @alignOf(u128), 2097152); // 2mb
        defer gpa.free(mem_ptr);
        for (mem_ptr) |*b| b.* = 0;

        const disk = try std.fs.cwd().readFileAllocOptions(gpa, src, 2097152, null, @alignOf(u128), null);
        defer gpa.free(disk);

        var disk_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        disk_hasher.update(disk);
        const disk_hash = disk_hasher.finalResult();

        const snapshot = std.fs.cwd().readFileAlloc(gpa, dst, 2097152) catch "";
        defer gpa.free(snapshot); // if the file read failed, it won't free. so that's ok.

        var emu: rvemu.Emulator = .{ .memory = mem_ptr };
        try emu.loadElf(disk);

        var snapshot_result = std.ArrayList(u8).init(gpa);
        defer snapshot_result.deinit();

        // should go in a seperate file because it will change with zig updates
        // maybe once we're ready, we can keep around old hashes to make sure they continue to execute the same
        // (store them in cdn lfs)
        try snapshot_result.writer().print("src hash: {s}\n", .{std.fmt.fmtSliceHexLower(&disk_hash)});

        // start emu-lating
        var env: Env = .{
            .emu = &emu,
            .snapshot_result = &snapshot_result,
            .exit_code = 1,
        };
        emu.run(&env, handleSyscall) catch |e| switch (e) {
            error.Ecall_Exit => {},
            else => return e,
        };

        // these should go in a seperate file because they will change with zig updates
        try snapshot_result.writer().print("exited with code {d} in {d} cost\n", .{ env.exit_code, emu.cost });

        if (!std.mem.eql(u8, snapshot_result.items, snapshot)) {
            std.log.err("{s}:\n=== EXPECTED ===\n{s}\n=== GOT ===\n{s}\n=== ===", .{ name, snapshot, snapshot_result.items });
            success = false;
            if (update_snapshots) {
                try std.fs.cwd().writeFile(.{ .sub_path = dst, .data = snapshot_result.items });
            }
        }
    }
    if (rem.len != 0) return error.BadArgs;

    if (!success) {
        if (!update_snapshots) {
            std.log.info("use -u to update snapshots.", .{});
        } else {
            std.log.info("snapshots updated. re-run tests without -u to confirm.", .{});
        }
        return 1;
    }
    return 0;
}
const Env = struct {
    emu: *rvemu.Emulator,
    snapshot_result: *std.ArrayList(u8),
    exit_code: i32,
};
pub fn handleSyscall(env: *Env, kind: i32, args: [6]i32) !i32 {
    switch (kind) {
        1 => {
            env.exit_code = args[0];
            return error.Ecall_Exit;
        },
        3 => {
            const ptr: u32 = @bitCast(args[0]);
            const len: u32 = @bitCast(args[1]);
            try env.emu.addCost(len);
            try env.snapshot_result.appendSlice("[LOG] ");
            try env.snapshot_result.appendSlice(try env.emu.readSlice(ptr, len));
            try env.snapshot_result.appendSlice("\n");
            return 0;
        },
        else => @panic("bad ecall"),
    }
}

// test "fuzz"
