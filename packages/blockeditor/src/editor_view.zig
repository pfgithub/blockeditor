const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;
const draw_lists = @import("render_list.zig");
const zgui = @import("zgui");

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

    pub fn gui(self: *EditorView, arena: std.mem.Allocator, draw_list: *draw_lists.RenderList, content_region_size: @Vector(2, f32)) void {
        const allow_kbd = zgui.io.getWantCaptureKeyboard();
        const allow_mouse = zgui.io.getWantCaptureMouse();
        _ = allow_kbd;
        _ = allow_mouse;

        const block = self.core.document.value;

        const buffer = arena.alloc(u8, block.length()) catch @panic("oom");
        defer arena.free(buffer);
        block.readSlice(block.positionFromDocbyte(0), buffer);

        const line_height: f32 = draw_list.getCharHeight();
        const window_scroll_y: f32 = 0.0;
        var code_height: f32 = 0;
        var line_len: f32 = 0;
        var start_idx: usize = 0;
        var start_offset: f32 = 0;
        for (buffer, 0..) |char, i| {
            if (char == '\n') {
                code_height += line_height;
                line_len = 0;
                if (code_height < window_scroll_y) {
                    start_idx = i + 1;
                    start_offset = code_height;
                }
            } else {
                const advance = draw_list.getCharAdvance(char);
                if (line_len + advance > content_region_size[0]) {
                    code_height += line_height;
                    line_len = 0;
                }
                line_len += advance;
            }
        }

        var x_pos: f32 = 10.0;
        for (std.fmt.allocPrint(arena, "V: {d}", .{code_height}) catch @panic("oom")) |char| {
            draw_list.addChar(char, .{ x_pos, 10 }, .{ 1.0, 1.0, 1.0, 1.0 });
            x_pos += draw_list.getCharAdvance(char);
        }
    }
};
