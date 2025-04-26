const std = @import("std");

pub const EmitBlock = struct {
    pub const ZigVar = enum(u32) {
        _,
    };
    out: std.ArrayList(u8),
};
