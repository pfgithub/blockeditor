const std = @import("std");
const loadimage = @import("loadimage");

export fn loadimage_wasm__file__alloc(len: usize) ?[*]u8 {
    const res = std.heap.wasm_allocator.alloc(u8, len) catch return null;
    return res.ptr;
}
export fn loadimage_wasm__file__free(ptr: [*]u8, len: usize) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}
export fn loadimage_wasm__image__load(ptr: [*]const u8, len: usize) ?*loadimage.LoadedImage {
    const image = std.heap.wasm_allocator.create(loadimage.LoadedImage) catch return null;
    errdefer std.heap.wasm_allocator.destroy(image);
    image.* = loadimage.loadImage(std.heap.wasm_allocator, ptr[0..len]) catch return null;
    return image;
}
export fn loadimage_wasm__image__destroy(image: *loadimage.LoadedImage) void {
    image.deinit(std.heap.wasm_allocator);
    std.heap.wasm_allocator.destroy(image);
}

export fn loadimage_wasm__image__getWidth(image: *loadimage.LoadedImage) u32 {
    return image.w;
}
export fn loadimage_wasm__image__getHeight(image: *loadimage.LoadedImage) u32 {
    return image.h;
}
export fn loadimage_wasm__image__getRgba(image: *loadimage.LoadedImage) [*]align(4) const u8 {
    return image.rgba.ptr;
}

pub fn main() !void {}
