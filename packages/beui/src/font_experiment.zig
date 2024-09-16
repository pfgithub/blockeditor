const std = @import("std");
const hb = @import("harfbuzz");
const ft = @import("freetype");

test "font_experiment" {
    const buf = hb.Buffer.init() orelse return error.OutOfMemory;
    defer buf.deinit();

    // we're maybe supposed to split this up into two segments for the different scripts?
    // https://host-oman.github.io/libraqm/raqm-Raqm.html#raqm-layout <- raqm does this
    // https://harfbuzz.github.io/what-harfbuzz-doesnt-do.html <- icu or fribidi can also do this
    // we are definitely supposed to split into lines. harfbuzz is for one infinite line.
    buf.addUTF8("hello… мир", 0, null);

    // buf.setDirection(.ltr);
    // buf.setScript(.latin);
    // buf.setLanguage(.fromString("en"));

    buf.guessSegmentProps();

    const blob = hb.Blob.init(@constCast(@embedFile("NotoSans[wght].ttf")), .readonly) orelse return error.OutOfMemory;
    defer blob.deinit();

    const face = hb.Face.init(blob, 0);
    defer face.deinit();
    const font = hb.Font.init(face);
    defer font.deinit();

    font.shape(buf, null);

    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();

    const ft_face = try ft_lib.createFaceMemory(@embedFile("NotoSans[wght].ttf"), 0);
    defer ft_face.deinit();
    // try ft_face.setCharSize(60 * 48, 0, 50, 0);
    try ft_face.setPixelSizes(0, 16);

    var cursor_pos: @Vector(2, i32) = @splat(0);
    for (
        buf.getGlyphInfos(),
        buf.getGlyphPositions().?,
    ) |glyph_info, glyph_pos| {
        // for cursor positioning: if a character spans multiple bytes, divide it into segments
        const glyphid = glyph_info.codepoint; // 'codepoint' is misleading - this is an opaque integer specific to the target font

        try ft_face.loadGlyph(glyphid, .{ .render = true });
        const bitmap = ft_face.glyph().bitmap();

        const writer_unb = std.io.getStdErr().writer();
        var writer_buffered_backing = std.io.bufferedWriter(writer_unb);
        const writer_buffered = writer_buffered_backing.writer();
        try writer_buffered.print("\nbyte {d}: drawGlyph: {d} {d} {d}\n\n", .{ glyph_info.cluster, glyphid, cursor_pos[0] + glyph_pos.x_offset, cursor_pos[0] + glyph_pos.y_offset });
        for (0..bitmap.rows()) |y| {
            const w = bitmap.width();
            for (0..w) |x| {
                const value: u32 = bitmap.buffer().?[y * w + x];
                const reschar = value * (charseq.len - 1) / std.math.maxInt(u8);
                const char: u8 = charseq[charseq.len - reschar - 1];
                try writer_buffered.writeAll(&.{ char, char });
            }
            try writer_buffered.writeByte('\n');
        }
        try writer_buffered_backing.flush();

        cursor_pos += .{ glyph_pos.x_advance, glyph_pos.y_advance };
    }
}

const charseq = "$@B%8&WM#*oahkbdpqwmZO0QLCJUYXzcvunxrjft/\\|()1{}[]?-_+~<>i!lI;:,\"^`'. ";

// for text editor we will:
// - split by lines
// - split lines into runs using FriBiDi or SheenBidi
// - run harfbuzz on each run (bad for very long runs)
//   - cache the result
// - draw the harfbuzz result to the screen
//   - wrap if any part of a glyph goes over the edge of the screen
//
// if harfbuzz returns a '0' glyph id:
// - select the portion of the text that was '0'
// - run harfbuzz again with the fallback font
// - not sure if that's right
//
// eventually:
// - use a zig algorithm to determine good text break points for wrapping
//
// alternatively:
// - use libraqm. shouldn't be too hard to build, just depends on a bidi algo
// - https://github.com/HOST-Oman/libraqm
// - supports bidi and script itemization, which we would have to implement ourselves
//   - SheenBIDI might do itemization
// - doesn't support fallback fonts?

// future:
// - for large font sizes, render with a multi channel signed distance field at a fixed size,
//   then they can be rendered at any size
