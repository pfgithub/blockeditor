const std = @import("std");
const wuffs = @import("wuffs");
const log = std.log.scoped(.loadimage);

const LoadedImage = struct {
    w: usize,
    h: usize,
    rgba: []align(@alignOf(u32)) const u8,

    pub fn deinit(self: *const LoadedImage, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
    }
};
pub fn loadImage(gpa: std.mem.Allocator, file_cont: []const u8) !LoadedImage {
    // wuffs may be a single file c library with almost no dependencies
    // so it's easy to compile into a program
    // (doesn't even call malloc!)
    // but
    // it is definitely not easy to use

    var g_src = wuffs.wuffs_base__ptr_u8__reader(@constCast(file_cont.ptr), file_cont.len, true);

    const g_fourcc = wuffs.wuffs_base__magic_number_guess_fourcc(
        wuffs.wuffs_base__io_buffer__reader_slice(&g_src),
        g_src.meta.closed,
    );
    if (g_fourcc < 0) return error.CouldNotGuessFileFormat;

    // can't stack allocate the decoder because it requires #define WUFFS_IMPLEMENTATION
    const decoder_raw, const g_image_decoder = switch (g_fourcc) {
        wuffs.WUFFS_BASE__FOURCC__PNG => blk: {
            const decoder_raw = wuffs.wuffs_png__decoder__alloc() orelse return error.OutOfMemory;
            break :blk .{
                decoder_raw,
                wuffs.wuffs_png__decoder__upcast_as__wuffs_base__image_decoder(decoder_raw),
            };
        },
        else => {
            return error.UnsupportedImageFormat;
        },
    };
    defer wuffs.free(decoder_raw);

    var g_image_config = std.mem.zeroes(wuffs.wuffs_base__image_config);
    try wrapErr(wuffs.wuffs_base__image_decoder__decode_image_config(
        g_image_decoder,
        &g_image_config,
        &g_src,
    ));

    const g_width = wuffs.wuffs_base__pixel_config__width(&g_image_config.pixcfg);
    const g_height = wuffs.wuffs_base__pixel_config__height(&g_image_config.pixcfg);

    // Override the image's native pixel format to be RGBA_NONPREMUL
    wuffs.wuffs_base__pixel_config__set(
        &g_image_config.pixcfg,
        wuffs.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
        wuffs.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
        g_width,
        g_height,
    );

    const workbuf_len = wuffs.wuffs_base__image_decoder__workbuf_len(g_image_decoder).max_incl;
    const workbuf_data = try gpa.alloc(u8, workbuf_len);
    for (workbuf_data) |*itm| itm.* = 0;
    defer gpa.free(workbuf_data);
    const g_workbuf_slice = wuffs.wuffs_base__make_slice_u8(workbuf_data.ptr, workbuf_data.len);

    const num_pixels = @as(usize, g_width) * @as(usize, g_height);
    const pixbuf_data = try gpa.alignedAlloc(u8, @alignOf(u32), num_pixels * 4);
    errdefer gpa.free(pixbuf_data);
    for (pixbuf_data) |*itm| itm.* = 0;
    const g_pixbuf_slice = wuffs.wuffs_base__make_slice_u8(pixbuf_data.ptr, pixbuf_data.len);

    var g_pixbuf = std.mem.zeroes(wuffs.wuffs_base__pixel_buffer);
    try wrapErr(wuffs.wuffs_base__pixel_buffer__set_from_slice(&g_pixbuf, &g_image_config.pixcfg, g_pixbuf_slice));

    const tab = wuffs.wuffs_base__pixel_buffer__plane(&g_pixbuf, 0);
    if (tab.width != g_width * 4 or tab.height != g_height) {
        return error.InconsistentPixelBufferDimensions;
    }

    var g_frame_config = std.mem.zeroes(wuffs.wuffs_base__frame_config);
    try wrapErr(wuffs.wuffs_base__image_decoder__decode_frame_config(
        g_image_decoder,
        &g_frame_config,
        &g_src,
    ));

    try wrapErr(wuffs.wuffs_base__image_decoder__decode_frame(
        g_image_decoder,
        &g_pixbuf,
        &g_src,
        switch (wuffs.wuffs_base__frame_config__overwrite_instead_of_blend(&g_frame_config)) {
            true => wuffs.WUFFS_BASE__PIXEL_BLEND__SRC,
            false => wuffs.WUFFS_BASE__PIXEL_BLEND__SRC_OVER,
        },
        g_workbuf_slice,
        null,
    ));

    return .{
        .w = g_width,
        .h = g_height,
        .rgba = pixbuf_data,
    };
}

fn wrapErr(status: wuffs.wuffs_base__status) !void {
    if (wuffs.wuffs_base__status__message(&status)) |emsg| {
        log.err("image load error: {s}", .{emsg});
        return error.WuffsError;
    }
}

test loadImage {
    const gpa = std.testing.allocator;

    const loaded = try loadImage(gpa, @embedFile("test_image.png"));
    defer loaded.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), loaded.w);
    try std.testing.expectEqual(@as(usize, 1), loaded.h);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, loaded.rgba);
}
