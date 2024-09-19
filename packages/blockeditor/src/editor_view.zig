const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;
const draw_lists = beui_mod.draw_lists;
const zglfw = @import("zglfw");
const zgui = @import("zgui"); // zgui doesn't have everything! we should use cimgui + translate-c like we used to
const beui_mod = @import("beui");

const ft = beui_mod.font_experiment.ft;

const editor_core = @import("texteditor").core;

pub const EditorView = struct {
    gpa: std.mem.Allocator,
    core: editor_core.EditorCore,
    selecting: bool = false,
    scroll_position: f64 = 0.0,

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
        _ = arena;
        const draw_list = beui.draw();
        const block = self.core.document.value;

        if (beui.hotkey(.{ .alt = .maybe, .ctrl_or_cmd = .maybe, .shift = .maybe }, &.{ .left, .right })) |hk| {
            self.core.executeCommand(.{ .move_cursor_left_right = .{
                .direction = switch (hk.key) {
                    .left => .left,
                    .right => .right,
                },
                .stop = switch (hk.alt or hk.ctrl_or_cmd) {
                    false => .unicode_grapheme_cluster,
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
        if (beui.hotkey(.{ .alt = .maybe, .ctrl_or_cmd = .maybe }, &.{ .backspace, .delete })) |hk| {
            self.core.executeCommand(.{ .delete = .{
                .direction = switch (hk.key) {
                    .backspace => .left,
                    .delete => .right,
                },
                .stop = switch (hk.alt or hk.ctrl_or_cmd) {
                    false => .unicode_grapheme_cluster,
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
                .metric = .byte,
                .mode = switch (hk.shift) {
                    false => .move,
                    true => .select,
                },
            } });
        }
        if (beui.hotkey(.{ .alt = .yes, .ctrl_or_cmd = .yes }, &.{ .down, .up })) |hk| {
            self.core.executeCommand(.{ .move_cursor_up_down = .{
                .direction = switch (hk.key) {
                    .down => .down,
                    .up => .up,
                },
                .metric = .byte,
                .mode = .duplicate,
            } });
        }
        if (beui.hotkey(.{}, &.{.enter})) |_| {
            self.core.executeCommand(.newline);
        }
        if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .maybe }, &.{.enter})) |hk| {
            self.core.executeCommand(.{ .insert_line = .{
                .direction = switch (hk.shift) {
                    false => .down,
                    true => .up,
                },
            } });
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
        if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .yes }, &.{.d})) |_| {
            self.core.executeCommand(.{ .duplicate_line = .{ .direction = .down } });
        }
        if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{ .x, .c })) |hk| {
            var copy_txt = std.ArrayList(u8).init(self.gpa);
            defer copy_txt.deinit();
            self.core.copyArrayListUtf8(&copy_txt, switch (hk.key) {
                .x => .cut,
                .c => .copy,
            });
            copy_txt.append('\x00') catch @panic("oom");
            beui.setClipboard(copy_txt.items[0 .. copy_txt.items.len - 1 :0]);
        }
        if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.v})) |_| {
            var paste_txt = std.ArrayList(u8).init(self.gpa);
            defer paste_txt.deinit();
            beui.getClipboard(&paste_txt);
            self.core.executeCommand(.{ .paste = .{ .text = paste_txt.items } });
        }

        if (beui.textInput()) |text| {
            self.core.executeCommand(.{ .insert_text = .{ .text = text } });
        }

        self.scroll_position += @floatCast(beui.frame.scroll_px[1]);

        const window_pos: @Vector(2, f32) = .{ 10, 10 };
        const window_size: @Vector(2, f32) = content_region_size - @Vector(2, f32){ 20, 20 };

        var cursor_positions = self.core.getCursorPositions();
        defer cursor_positions.deinit();

        var syn_hl = self.core.syn_hl_ctx.highlight();
        defer syn_hl.deinit();

        var pos: @Vector(2, f32) = .{ 0, @floatCast(self.scroll_position) };
        var prev_char_advance: f32 = 0;
        var click_target: ?usize = null;
        for (0..block.length() + 1) |i| {
            const cursor_info = cursor_positions.advanceAndRead(i);
            const syn_hl_info = syn_hl.advanceAndRead(i);
            const char = syn_hl.znh.charAt(i);

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

            if ((show_invisibles or is_invisible == null) and pos[0] <= window_size[0] and pos[1] <= window_size[1] and pos[0] >= 0 and pos[1] >= 0) {
                draw_list.addChar(char_or_invisible, window_pos + pos + char_offset, hexToFloat(DefaultTheme.synHlColor(switch (is_invisible != null) {
                    true => .invisible,
                    false => syn_hl_info,
                })));
            }
            if (cursor_info.selected) {
                draw_list.addRect(window_pos + pos + @Vector(2, f32){ -1, -1 }, .{ char_advance, draw_list.getCharHeight() + 2 - 1 }, .{ .tint = hexToFloat(DefaultTheme.selection_color) });
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
            const shift_held = beui.isKeyHeld(.left_shift) or beui.isKeyHeld(.right_shift);
            const alt_held = (beui.isKeyHeld(.left_alt) or beui.isKeyHeld(.right_alt)) != (beui.isKeyHeld(.left_control) or beui.isKeyHeld(.right_control));

            if (beui.isKeyPressed(.mouse_left)) {
                const mode: ?editor_core.DragSelectionMode = switch (beui.leftMouseClickedCount()) {
                    1 => .{ .stop = .unicode_grapheme_cluster, .select = false },
                    2 => .{ .stop = .word, .select = true },
                    3 => .{ .stop = .line, .select = true },
                    else => null,
                };
                if (mode) |sel_mode| {
                    self.core.executeCommand(.{ .click = .{
                        .pos = clicked_pos,
                        .mode = sel_mode,
                        .extend = shift_held,
                        .select_ts_node = alt_held,
                    } });
                } else {
                    self.core.executeCommand(.select_all);
                }
                self.selecting = true;
            } else if (self.selecting and beui.isKeyHeld(.mouse_left)) {
                self.core.executeCommand(.{ .drag = .{ .pos = clicked_pos, .select_ts_node = alt_held } });
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
    // colors are defined in srgb
    pub const editor_bg: u32 = 0x1d252c;
    pub const selection_color: u32 = 0x28323a;

    pub fn synHlColor(syn_hl_color: editor_core.SynHlColorScope) u32 {
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

// CLIPBOARD:
// https://github.com/microsoft/vscode/blob/faf7a5c748720c4f7962f462de058da4c12b54f5/src/vs/editor/browser/controller/editContext/native/nativeEditContext.ts#L370
// - vscode stores clipboard metadata and writes text to the clipboard
// - vscode copies as an array of lines
// - we could copy a block with text fallback, or we could copy text and store a lines array somewhere and only use it if the hash matches.
// - we'll want to copy blocks eventually but it doesn't have to be now.
// copy with glfw_window.clipboard something
