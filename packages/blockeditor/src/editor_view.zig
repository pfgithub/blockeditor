const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;
const draw_lists = @import("render_list.zig");

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

    pub fn gui(self: *EditorView, arena: std.mem.Allocator, draw_list: *draw_lists.RenderList) void {
        _ = self;
        _ = arena;

        var x_pos: f32 = 10.0;
        for ("Hello, World! render") |char| {
            draw_list.addChar(char, .{ x_pos, 10 }, .{ 1.0, 1.0, 1.0, 1.0 });
            x_pos += draw_list.getCharAdvance(char);
        }
    }
};
