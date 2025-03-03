const std = @import("std");
const rvemu = @import("rvemu");

const EmitBlock = struct {
    // two pass:
    // - one: the instrs are made with references to other instrs
    //   and references to block jumps
    // - two: register allocation & emit
    //   - register allocation may require storing instructions to the stack
    //   - explicit registers can never be stored to the stack
    //     - (ie no saving the value in x10 before )
    const RvVar = enum(u32) {
        _,
        const lowest_int_reg = std.math.maxInt(u32) - 0b11111;
        fn fromIntReg(reg: u5) RvVar {
            return @enumFromInt(lowest_int_reg + @as(u32, reg));
        }
        fn isIntReg(rv: RvVar) ?u5 {
            const rvint = @intFromEnum(rv);
            if (rvint >= lowest_int_reg) return @intCast(rvint - (lowest_int_reg));
            return null;
        }
        pub fn format(value: RvVar, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            if (value.isIntReg()) |intreg| {
                try writer.print("x{d}", .{intreg});
            } else {
                try writer.print("%{d}", .{@intFromEnum(value)});
            }
        }
    };
    const RvInstr = union(enum) {
        instr: struct {
            op: rvemu.rvinstrs.InstrName,
            rs1: ?RvVar = null,
            rs2: ?RvVar = null,
            rs3: ?RvVar = null,
            rd: ?RvVar = null,
            imm_11_0: ?i12 = null,
        },
        fakeuser: struct {
            rs: ?RvVar = null,
            rd: ?RvVar = null,
        },
    };
    instructions: std.ArrayListUnmanaged(RvInstr),
};
