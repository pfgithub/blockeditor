const std = @import("std");

pub const EmitBlock = struct {
    pub const ZigVar = enum(u32) {
        _,
    };
    out: std.ArrayListUnmanaged(u8),
    indent_level: usize = 0,
};
