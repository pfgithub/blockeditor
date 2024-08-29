const std = @import("std");
const loadimage = @import("loadimage");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_alloc.deinit() != .ok) @panic("leak");
    const gpa = gpa_alloc.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 3) return error.BadArgsLen;

    const src_img = try std.fs.cwd().readFileAlloc(gpa, args[1], std.math.maxInt(usize));
    defer gpa.free(src_img);

    const converted = try loadimage.loadImage(gpa, src_img);
    defer converted.deinit(gpa);

    // now, we will convert from black/white/blue to white/transparent (255 = white, 0 = transparent)

    const result = try gpa.alloc(u8, converted.w * converted.h);
    defer gpa.free(result);
    for (std.mem.bytesAsSlice(u32, converted.rgba), 0..) |byte, i| {
        switch (byte) {
            colors.black => {
                result[i] = 255; // white
            },
            colors.white, colors.blue => {
                result[i] = 0; // transparent
            },
            else => @panic("unexpected color"),
        }
    }

    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = result });
}

const colors = struct {
    const black = 0xff000000;
    const white = 0xffffffff;
    const blue = 0xfffcdbcb;
};
