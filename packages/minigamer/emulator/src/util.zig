const std = @import("std");

pub fn safeAlignCast(comptime alignment: u29, slice: []const u8) ![]align(alignment) const u8 {
    const ptr_casted = try std.math.alignCast(alignment, slice.ptr);
    return ptr_casted[0..slice.len];
}
pub fn safeAlignCastMut(comptime alignment: u29, slice: []u8) ![]align(alignment) u8 {
    const ptr_casted = try std.math.alignCast(alignment, slice.ptr);
    return ptr_casted[0..slice.len];
}
pub fn safePtrCast(comptime T: type, slice: []const u8) !*const T {
    // 1. aligncast
    const aligned = try safeAlignCast(@alignOf(T), slice);
    // 2. check size
    if (aligned.len != @sizeOf(T)) return error.BadSize;
    // 3. ok
    return @ptrCast(aligned);
}
pub fn safePtrCastMut(comptime T: type, slice: []u8) !*T {
    // 1. aligncast
    const aligned = try safeAlignCastMut(@alignOf(T), slice);
    // 2. check size
    if (aligned.len != @sizeOf(T)) return error.BadSize;
    // 3. ok
    return @ptrCast(aligned);
}
pub fn safeSliceCast(comptime T: type, slice: []const u8) ![]const T {
    // 1. aligncast
    const aligned = try safeAlignCast(@alignOf(T), slice);
    // 2. check size
    if (@rem(aligned.len, @sizeOf(T)) != 0) return error.BadSize;
    // 3. ok
    return std.mem.bytesAsSlice(T, aligned);
}
pub fn safeStarSliceCast(comptime T: type, slice: []const u8) ![]const T {
    // 1. aligncast
    const aligned = try safeAlignCast(@alignOf(T), slice);
    // 2. fit size
    const new_size = @divFloor(aligned.len, @sizeOf(T)) * @sizeOf(T);
    // 3. ok
    return std.mem.bytesAsSlice(T, aligned[0..new_size]);
}
