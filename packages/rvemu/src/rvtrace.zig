const rvemu = @import("rvemu.zig");
const std = @import("std");

const ReadRegion = struct {
    offset: u32,
    len: u32,
};
const WriteRegion = struct {
    offset: u32,
    len: u32,
    value: []const u8,
};
// this assumes all syscalls use only the standard x17 x10 x11 x12 x13 x14 x15 and write result to x10
// we can update it in the future to store all regs or all reg changes or something
const TraceEntry = struct {
    args: []const u32,
    ret_v: u32,
    read_memory: []const ReadRegion,
    write_memory: []const WriteRegion,
};

const DemoEmu = struct {
    const Syscalls = struct {
        pub fn log(self: *DemoEmu, emu: *rvemu.Emulator, level: u32, ptr: u32, len: u32) rvemu.ExecError!u32 {
            _ = self;
            try emu.addCost(len);
            const msg = try emu.readSlice(ptr, len);
            switch (level) {
                0 => std.log.debug("{s}", .{msg}),
                1 => std.log.info("{s}", .{msg}),
                2 => std.log.warn("{s}", .{msg}),
                3 => std.log.err("{s}", .{msg}),
                else => return error.Ecall_BadArgs,
            }
            return 0;
        }
    };
};
