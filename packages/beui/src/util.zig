const std = @import("std");

pub fn typeValidForAnyToAny(comptime T: type, comptime V: type) bool {
    if (!std.meta.hasUniqueRepresentation(T)) return false;
    if (!std.meta.hasUniqueRepresentation(V)) return false;
    if (@sizeOf(T) > @sizeOf(V)) return false;
    return true;
}
pub fn anyToAny(comptime V: type, comptime T: type, value: T) V {
    comptime std.debug.assert(typeValidForAnyToAny(T, V));

    var result: V = undefined;
    var result_slice = std.mem.asBytes(&result);
    @memcpy(result_slice[0..@sizeOf(T)], std.mem.asBytes(&value));
    @memset(result_slice[@sizeOf(T)..], 0);
    return result;
}
