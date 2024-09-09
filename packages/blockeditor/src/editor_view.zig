const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;
const draw_lists = @import("render_list.zig");
const zglfw = @import("zglfw");
const zgui = @import("zgui"); // zgui doesn't have everything! we should use cimgui + translate-c like we used to
const beui_mod = @import("beui.zig");

const editor_core = blocks_mod.text_editor_core;

pub const EditorView = struct {
    gpa: std.mem.Allocator,
    core: editor_core.EditorCore,
    selecting: bool = false,

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

    pub fn gui(self: *EditorView, beui: *beui_mod.Beui, content_region_size: @Vector(2, f32)) void {
        const arena = beui.arena();
        const draw_list = beui.draw();
        const block = self.core.document.value;

        // # hotkey dsl?
        //
        // $word = (alt | ctrl)
        // $select = shift
        // $reverse = shift
        // $hotkey = (ctrl | cmd)
        //
        // ?$word ?$select (left | right) => move_cursor_lr [
        //     .direction = $3(.left, .right),
        //     .stop = $1(.byte, .word),
        //     .mode = $2(.move, .select),
        // ]
        // ?$select (home | end) => move_cursor_lr [
        //     .direction = $2(.left, .right),
        //     .stop = .line,
        //     .mode = $1(.move, .select),
        // ]
        // ?$word (backspace | delete) => delete [
        //     .direction = $2(.left, .right),
        //     .stop = $1(.byte, .word),
        // ]
        // $word (down | up) => ts_select_node [
        //     .direction = $2(.down, .up),
        // ]
        // ?$select (down | up) => move_cursor_ud [
        //     .direction = $2(.down, .up),
        //     .metric = .raw,
        //     .mode = $1(.move, .select),
        // ]
        // enter => newline
        // ?$reverse tab => indent_selection [
        //     .direction = $1(.right, .left),
        // ]
        // $hotkey a => select_all
        // $hotkey ?$reverse z => $2(undo, redo)
        // $hotkey y => redo

        if (beui.hotkey(.{ .alt = .maybe, .shift = .maybe }, &.{ .left, .right })) |hk| {
            self.core.executeCommand(.{ .move_cursor_left_right = .{
                .direction = switch (hk.key) {
                    .left => .left,
                    .right => .right,
                },
                .stop = switch (hk.alt) {
                    false => .byte,
                    true => .word,
                },
                .mode = switch (hk.shift) {
                    false => .move,
                    true => .select,
                },
            } });
        }
        if (beui.hotkey(.{ .shift = .maybe }, &.{ .home, .end })) |hk| {
            // maybe should be .move_cursor_to_line_side
            self.core.executeCommand(.{ .move_cursor_left_right = .{
                .direction = switch (hk.key) {
                    .home => .left,
                    .end => .right,
                },
                .stop = .line,
                .mode = switch (hk.shift) {
                    false => .move,
                    true => .select,
                },
            } });
        }
        if (beui.hotkey(.{ .alt = .maybe }, &.{ .backspace, .delete })) |hk| {
            self.core.executeCommand(.{ .delete = .{
                .direction = switch (hk.key) {
                    .backspace => .left,
                    .delete => .right,
                },
                .stop = switch (hk.alt) {
                    false => .byte,
                    true => .word,
                },
            } });
        }
        if (beui.hotkey(.{ .alt = .yes }, &.{ .down, .up })) |hk| {
            self.core.executeCommand(.{ .ts_select_node = .{
                .direction = switch (hk.key) {
                    .down => .child,
                    .up => .parent,
                },
            } });
        }
        if (beui.hotkey(.{ .shift = .maybe }, &.{ .down, .up })) |hk| {
            self.core.executeCommand(.{ .move_cursor_up_down = .{
                .direction = switch (hk.key) {
                    .down => .down,
                    .up => .up,
                },
                .metric = .raw,
                .mode = switch (hk.shift) {
                    false => .move,
                    true => .select,
                },
            } });
        }
        if (beui.hotkey(.{}, &.{.enter})) |_| {
            self.core.executeCommand(.newline);
        }
        if (beui.hotkey(.{ .shift = .maybe }, &.{.tab})) |hk| {
            self.core.executeCommand(.{ .indent_selection = .{
                .direction = switch (hk.shift) {
                    false => .right,
                    true => .left,
                },
            } });
        }
        if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.a})) |_| {
            self.core.executeCommand(.select_all);
        }
        if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .maybe }, &.{.z})) |hk| {
            self.core.executeCommand(switch (hk.shift) {
                false => .undo,
                true => .redo,
            });
        }
        if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.y})) |_| {
            self.core.executeCommand(.redo);
        }

        if (beui.textInput()) |text| {
            self.core.executeCommand(.{ .insert_text = .{ .text = text } });
        }

        const window_pos: @Vector(2, f32) = .{ 10, 10 };
        const window_size: @Vector(2, f32) = content_region_size - @Vector(2, f32){ 20, 20 };

        const buffer = arena.alloc(u8, block.length() + 1) catch @panic("oom");
        defer arena.free(buffer);
        block.readSlice(block.positionFromDocbyte(0), buffer[0..block.length()]);
        // extra char to make handling events for and rendering the last cursor position easier
        buffer[buffer.len - 1] = '\x00';

        var cursor_positions = self.core.getCursorPositions();
        defer cursor_positions.deinit();

        var pos: @Vector(2, f32) = .{ 0, 0 };
        var prev_char_advance: f32 = 0;
        var click_target: ?usize = null;
        for (buffer, 0..) |char, i| {
            const cursor_info = cursor_positions.advanceAndRead(i);

            if (cursor_info.left_cursor == .focus) {
                draw_list.addRect(window_pos + pos + @Vector(2, f32){ -1, -1 }, .{
                    1, draw_list.getCharHeight() + 2,
                }, .{ .tint = .{ 1, 1, 1, 1 } });
            }
            const show_invisibles = cursor_info.selected;
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

            {
                const min = window_pos + pos + @Vector(2, f32){ -prev_char_advance / 2.0, 0 };
                if (@reduce(.And, beui.persistent.mouse_pos > min)) {
                    click_target = i;
                }
            }

            const char_advance: f32 = draw_list.getCharAdvance(char);
            prev_char_advance = char_advance;
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
                draw_list.addRect(window_pos + pos + @Vector(2, f32){ -1, -1 }, .{ char_advance, draw_list.getCharHeight() + 2 }, .{ .tint = hexToFloat(DefaultTheme.selection_color) });
            }
            if (pos[1] > window_size[1]) break;

            if (char == '\n') {
                pos = .{ 0, pos[1] + draw_list.getCharHeight() };
            } else {
                pos += .{ char_advance, 0 };
            }
        }

        if (click_target) |clicked_bufbyte| {
            const clicked_pos = block.positionFromDocbyte(clicked_bufbyte);

            if (beui.isKeyPressed(.mouse_left)) {
                self.core.onClick(clicked_pos, beui.leftMouseClickedCount(), beui.isKeyHeld(.left_shift));
                self.selecting = true;
            } else if (self.selecting and beui.isKeyHeld(.mouse_left)) {
                self.core.onDrag(clicked_pos);
            }
        }
        if (!beui.isKeyHeld(.mouse_left)) {
            self.selecting = false;
        }

        if (zgui.begin("Editor Debug", .{})) {
            zgui.text("draw_list items: {d} / {d}", .{ draw_list.vertices.items.len, draw_list.indices.items.len });
            zgui.text("click_target: {?d}", .{click_target});
            zgui.text("click_count: {d}", .{beui.leftMouseClickedCount()});
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
