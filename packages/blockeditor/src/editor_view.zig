const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;
const draw_lists = @import("render_list.zig");
const zglfw = @import("zglfw");
const zgui = @import("zgui"); // zgui doesn't have everything! we should use cimgui + translate-c like we used to

const editor_core = blocks_mod.text_editor_core;

pub const EditorView = struct {
    gpa: std.mem.Allocator,
    core: editor_core.EditorCore,

    pub fn initFromDoc(self: *EditorView, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
        self.* = .{
            .gpa = gpa,
            .core = undefined,
        };
        self.core.initFromDoc(gpa, document);
    }
    pub fn deinit(self: *EditorView) void {
        self.core.deinit();
    }

    // if we add an event listener for changes to the component:
    // - we could maintain our own list of every character and its size, and modify
    //   it when the component is edited
    // - this will let us quickly go from bufbyte -> screen position
    // - or from screen position -> bufbyte
    // - and it will always give us access to total scroll height

    pub fn event(self: *EditorView, window: *zglfw.Window, arena: std.mem.Allocator, allow_kbd: bool, allow_mouse: bool) void {
        if (allow_kbd) {
            // if(chord: .right_arrow) => .right, .unicode_grapheme, .move
            // if(chord: .right_arrow, .shift) => .right, .unicode_grapheme, .select
            // if(chord: .rigth_arrow, .ctrl|.alt) => .right, .word, .move
            // if(chord: .rigth_arrow, .shift, .ctrl|.alt) => .right, .word, .select
            // handle this in beui.zig by setting callbacks on the window
            // for everything we need
            if (window.getKey(.left) == .press) {
                self.core.executeCommand(.{
                    .move_cursor_left_right = .{
                        .direction = .left,
                        .stop = .byte,
                        .mode = .move,
                    },
                });
            }
            if (window.getKey(.right) == .press) {
                self.core.executeCommand(.{
                    .move_cursor_left_right = .{
                        .direction = .right,
                        .stop = .byte,
                        .mode = .move,
                    },
                });
            }
        }
        _ = arena;
        _ = allow_mouse;
    }

    pub fn gui(self: *EditorView, arena: std.mem.Allocator, draw_list: *draw_lists.RenderList, content_region_size: @Vector(2, f32)) void {
        const window_pos: @Vector(2, f32) = .{ 10, 10 };
        const window_size: @Vector(2, f32) = content_region_size - @Vector(2, f32){ 20, 20 };

        const block = self.core.document.value;

        const buffer = arena.alloc(u8, block.length() + 1) catch @panic("oom");
        defer arena.free(buffer);
        block.readSlice(block.positionFromDocbyte(0), buffer[0..block.length()]);
        // extra char to make handling events for and rendering the last cursor position easier
        buffer[buffer.len - 1] = '\x00';

        var cursor_positions = self.core.getCursorPositions();
        defer cursor_positions.deinit();

        var pos: @Vector(2, f32) = .{ 0, 0 };
        for (buffer, 0..) |char, i| {
            const cursor_info = cursor_positions.advanceAndRead(i);

            if (cursor_info.left_cursor == .focus) {
                draw_list.addRect(window_pos + pos + @Vector(2, f32){ -1, -1 }, .{
                    1, draw_list.getCharHeight() + 2,
                }, .{ .tint = .{ 1, 1, 1, 1 } });
            }

            const in_selection = cursor_info.selected;
            const show_invisibles = in_selection;
            const is_invisible: ?u8 = switch (char) {
                '\x00' => '\x00',
                ' ' => '_', // '·'
                '\n' => '\n', // '⏎'
                '\t' => '\t', // '⇥'
                else => null,
            };
            var char_or_invisible = char;
            if (show_invisibles and is_invisible != null) {
                char_or_invisible = is_invisible.?;
            }

            const char_advance: f32 = draw_list.getCharAdvance(char);
            const invisible_advance: f32 = draw_list.getCharAdvance(char_or_invisible);

            if (pos[0] + char_advance > window_size[0]) {
                pos = .{ 0, pos[1] + draw_list.getCharHeight() };
            }

            const char_offset = @Vector(2, f32){ (invisible_advance - char_advance) / 2.0, 0.0 };

            if (is_invisible == null and pos[0] <= window_size[0] and pos[1] <= window_size[1] and pos[0] >= 0 and pos[1] >= 0) {
                draw_list.addChar(char_or_invisible, window_pos + pos + char_offset, hexToFloat(DefaultTheme.synHlColor(switch (is_invisible != null) {
                    true => .invisible,
                    false => .variable_mutable,
                })));
            }
            if (cursor_info.selected) {
                draw_list.addRect(window_pos + pos, .{ char_advance + 1, draw_list.getCharHeight() + 1 }, .{ .tint = hexToFloat(DefaultTheme.selection_color) });
            }
            if (pos[1] > window_size[1]) break;

            if (char == '\n') {
                pos = .{ 0, pos[1] + draw_list.getCharHeight() };
            } else {
                pos += .{ char_advance, 0 };
            }
        }

        if (zgui.begin("Editor Debug", .{})) {
            zgui.text("draw_list items: {d} / {d}", .{ draw_list.vertices.items.len, draw_list.indices.items.len });
        }
        zgui.end();

        // background
        draw_list.addRect(.{ 0, 0 }, content_region_size, .{ .tint = hexToFloat(DefaultTheme.editor_bg) });
    }
};

pub const SynHlColorScope = enum {
    //! sample containing all color scopes. syn hl colors are postfix in brackets
    //! ```ts
    //!     //<punctuation> The main function<comment>
    //!     export<keyword> function<keyword_storage> main<variable_function>(<punctuation>
    //!         argv<variable_parameter>:<punctuation_important> string<keyword_primitive_type>,<punctuation>
    //!     ) {<punctuation>
    //!         const<keyword_storage> res<variable_constant> =<keyword> argv<variable>.<punctuation>map<variable_function>(<punctuation>translate<variable>);<punctuation>
    //!         return<keyword> res<variable>;<punctuation>
    //!     }<punctuation>
    //!
    //!     let<keyword_storage> res<variable_mutable> =<keyword> main<variable_function>(["\<punctuation>\usr<literal_string>\<punctuation>"(MAIN)<literal_string>\<punctuation>x<keyword_storage>00<literal>"]);<punctuation>
    //!     #<invalid>
    //! ```

    // notes:
    // - punctuation_important has the same style as variable_mutable?
    // - 'keyword_storage' is used in string escapes? '\x55' the 'x' is keyword_storage for some reason.

    /// syntax error
    invalid,

    /// more important punctuation. also used for mutable variables? unclear
    punctuation_important,
    /// less important punctuation
    punctuation,

    /// variable defined as a function or called
    variable_function,
    /// variable defined as a paremeter
    variable_parameter,
    /// variable defined (or used?) as a constant
    variable_constant,
    /// variable defined (*maybe: or used?) as mutable
    variable_mutable,
    /// other variable
    variable,

    /// string literal (within the quotes only)
    literal_string,
    /// other types of literals (actual value portion only)
    literal,

    /// storage keywords, ie `var` / `const` / `function`
    keyword_storage,
    /// primitive type keywords, ie `void` / `string` / `i32`
    keyword_primitive_type,
    /// other keywords
    keyword,

    /// comment body text, excluding '//'
    comment,

    /// editor color - your syntax highlighter never needs to output this
    invisible,
};

fn hexToFloat(hex: u32) @Vector(4, f32) {
    const conv_f: @Vector(4, f32) = .{
        @floatFromInt((hex >> 16) & 0xFF),
        @floatFromInt((hex >> 8) & 0xFF),
        @floatFromInt((hex >> 0) & 0xFF),
        255.0,
    };
    return conv_f / @as(@Vector(4, f32), @splat(255.0));
}

const DefaultTheme = struct {
    pub const editor_bg: u32 = 0x1F252B;
    pub const selection_color: u32 = 0x2A3239;

    pub fn synHlColor(syn_hl_color: SynHlColorScope) u32 {
        return switch (syn_hl_color) {
            .invalid => 0xFF0000,

            .keyword_storage => 0x008B94,
            .literal => 0xe27e8d,
            .variable_function => 0x70e1e8,
            .punctuation_important => 0xb7c5d3,
            .variable => 0x718ca1,
            .variable_parameter => 0xEBBF83,
            .literal_string => 0x68a1f0,
            .keyword_primitive_type => 0x70e1e8,
            .punctuation => 0x718ca1,
            .keyword => 0x5ec4ff,
            .variable_constant => 0x8BD49C,
            .variable_mutable => 0xB7C5D3,
            .comment => 0xff9d1c,

            .invisible => 0x2e3c47,
        };
    }
};
