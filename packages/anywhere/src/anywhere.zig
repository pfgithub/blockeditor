const std = @import("std");

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
