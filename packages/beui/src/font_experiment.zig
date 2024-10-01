const std = @import("std");
pub const hb = @import("harfbuzz");
pub const ft = @import("freetype");
pub const sb = @import("sheen_bidi");
pub const NotoSans_wght = @embedFile("NotoSans[wght].ttf");
pub const NotoSansMono_wght = @embedFile("NotoSansMono[wght].ttf");

var global_ft_lib: ?ft.Library = null;
pub fn getFtLib() ft.Library {
    if (global_ft_lib == null) {
        global_ft_lib = ft.Library.init() catch |err| {
            std.log.err("Freetype library init fail: {s}", .{@errorName(err)});
            @panic("error");
        };
    }
    return global_ft_lib.?;
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

// alternative:
// - for now, skip bidi and shaping and render using freetype. it will work
//   fine for english for now, and we can migrate to using shaping later.
//   - https://learnopengl.com/In-Practice/Text-Rendering

// future:
// - for large font sizes, render with a multi channel signed distance field at a fixed size,
//   then they can be rendered at any size
