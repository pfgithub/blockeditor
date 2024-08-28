//! text editing core that is mostly agnostic to the visual editor

const std = @import("std");
const db_mod = @import("../blockdb.zig");
const bi = @import("../blockinterface2.zig");
const util = @import("../util.zig");

pub const Position = bi.text_component.Position;
pub const Selection = struct {
    anchor: Position,
    focus: Position,
};
const PosLen = struct {
    pos: Position,
    len: usize,
};
pub const CursorPosition = struct {
    pos: Selection,

    /// for pressing the up/down arrow going from [aaaa|a] ↓ to [a|] to [aaaa|a]. resets on move.
    vertical_move_start: ?Position = null,
    /// when selecting up with tree-sitter to allow selecting back down. resets on move.
    node_select_start: ?Selection = null,
};

pub const DragInfo = struct {
    start_pos: ?Position = null,
    selection_mode: DragSelectionMode = .ignore_drag,
};
pub const DragSelectionMode = enum {
    none,
    word,
    line,

    ignore_drag,
};

pub const CursorLeftRightStop = enum {
    // so the way these stops should work is:
    // - the whole document has invisible stops for all of these
    // - every stop is either a 'left' stop or a 'right' stop or both.
    // - left movement moves to the next left|both stop from the current position
    // - selection selects to the previous and next either stop from the current position
    // in descriptions: '<' indicates left stop, '>' indicates right stop, '|' indicates both, '.' indicates eof

    /// .|h|e|l|l|o| |w|o|r|l|d|.
    byte,
    /// .|a|…|b|.
    codepoint,
    /// .|म|नी|ष|.
    grapheme, // default
    /// .<fn> <demo><()> <void> <{}>.
    word,
    /// .<hello>\n<goodbye!>.
    line,
};
pub const CursorUpDownStop = enum {
    line,
};
pub const LRDirection = enum {
    left,
    right,
    pub fn value(dir: LRDirection) i2 {
        return switch (dir) {
            .left => -1,
            .right => 1,
        };
    }
};
pub const EditorCommand = union(enum) {
    none: void,
    move_cursor_left_right: struct {
        direction: LRDirection,
        stop: CursorLeftRightStop,
        mode: enum { move, select, delete },
    },
    move_cursor_up_down: struct {
        direction: enum { up, down },
        stop: CursorUpDownStop,
        mode: enum { move, select },
    },
    select_all: void,
    insert_text: struct {
        text: []const u8,
    },
    newline: void,
    indent_selection: struct {
        direction: LRDirection,
    },
    ts_select_node: struct {
        direction: enum { parent, child },
    },
    undo: void,
    redo: void,
    set_cursor_pos: struct {
        position: Position,
    },
};

// we would like EditorCore to edit any TextDocument component
// in order to apply operations to the document, we need to be able to wrap an operation
// with whatever is needed to target the right document
pub const EditorCore = struct {
    gpa: std.mem.Allocator,
    document: db_mod.TypedComponentRef(bi.text_component.TextDocument),

    cursor_positions: std.ArrayList(CursorPosition),
    drag_info: DragInfo = .{},

    /// refs document
    pub fn initFromDoc(self: *EditorCore, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
        self.* = .{
            .gpa = gpa,
            .document = document,

            .cursor_positions = std.ArrayList(CursorPosition).init(gpa),
        };
        document.ref();
        document.addUpdateListener(util.Callback(bi.text_component.TextDocument.SimpleOperation, void).from(self, cb_onEdit)); // to keep the language server up to date
    }
    pub fn deinit(self: *EditorCore) void {
        self.cursor_positions.deinit();
        self.document.removeUpdateListener(util.Callback(bi.text_component.TextDocument.SimpleOperation, void).from(self, cb_onEdit));
        self.document.unref();
    }

    fn cb_onEdit(self: *EditorCore, edit: bi.text_component.TextDocument.SimpleOperation) void {
        // TODO: keep tree-sitter updated
        _ = self;
        _ = edit;
    }

    fn toWordBoundary(self: *EditorCore, pos: Position, direction: LRDirection, stop: CursorLeftRightStop) Position {
        const block = self.document.value;

        switch (stop) {
            .byte => {
                var pos_int = block.byteOffsetFromPosition(pos);
                switch (direction) {
                    .left => {
                        if (pos_int > 0) {
                            pos_int -= 1;
                        }
                    },
                    .right => {
                        if (pos_int < block.length()) {
                            pos_int += 1;
                        }
                    },
                }
                return block.positionFromDocbyte(pos_int);
            },
            else => {
                std.log.err("TODO toWordBoundary for stop: {s}", .{@tagName(stop)});
                @panic("TODO");
            },
        }
    }

    fn selectionToPosLen(self: *EditorCore, selection: Selection) PosLen {
        const block = self.document.value;

        const bufbyte_1 = block.byteOffsetFromPosition(selection.anchor);
        const bufbyte_2 = block.byteOffsetFromPosition(selection.focus);

        const min = @min(bufbyte_1, bufbyte_2);
        const max = @max(bufbyte_1, bufbyte_2);

        return .{
            .pos = block.positionFromDocbyte(min),
            .len = max - min,
        };
    }
    pub fn executeCommand(self: *EditorCore, command: EditorCommand) void {
        const block = self.document.value;

        switch (command) {
            .set_cursor_pos => |sc_op| {
                self.cursor_positions.clearRetainingCapacity();
                self.cursor_positions.append(.{
                    .pos = .{
                        .anchor = sc_op.position,
                        .focus = sc_op.position,
                    },
                }) catch @panic("oom");
            },
            .insert_text => |text_op| {
                for (self.cursor_positions.items) |*cursor_position| {
                    const pos_len = self.selectionToPosLen(cursor_position.pos);

                    self.document.applySimpleOperation(.{
                        .position = pos_len.pos,
                        .delete_len = pos_len.len,
                        .insert_text = text_op.text,
                    }, null);
                    const res_pos = block.positionFromDocbyte(block.byteOffsetFromPosition(pos_len.pos) + text_op.text.len);

                    cursor_position.* = .{ .pos = .{
                        .anchor = res_pos,
                        .focus = res_pos,
                    } };
                }
            },
            .move_cursor_left_right => |lr_cmd| {
                for (self.cursor_positions.items) |*cursor_position| {
                    const moved = self.toWordBoundary(cursor_position.pos.focus, lr_cmd.direction, lr_cmd.stop);

                    switch (lr_cmd.mode) {
                        .move => {
                            cursor_position.* = .{ .pos = .{
                                .anchor = moved,
                                .focus = moved,
                            } };
                        },
                        .select => {
                            cursor_position.* = .{ .pos = .{
                                .anchor = cursor_position.pos.anchor,
                                .focus = moved,
                            } };
                        },
                        .delete => {
                            // if there is a selection, delete the selection
                            // if there is no selection, delete from the focus in the direction to the stop
                            var pos_len = self.selectionToPosLen(cursor_position.pos);
                            if (pos_len.len == 0) {
                                pos_len = self.selectionToPosLen(.{ .anchor = cursor_position.pos.focus, .focus = moved });
                            }
                            self.document.applySimpleOperation(.{
                                .position = pos_len.pos,
                                .delete_len = pos_len.len,
                                .insert_text = "",
                            }, null);
                            const res_pos = pos_len.pos;

                            cursor_position.* = .{ .pos = .{
                                .anchor = res_pos,
                                .focus = res_pos,
                            } };
                        },
                    }
                }
            },
            else => {
                std.log.err("TODO executeCommand {s}", .{@tagName(command)});
                @panic("TODO");
            },
        }
    }
};

fn testEditorContent(expected: []const u8, actual: db_mod.TypedComponentRef(bi.text_component.TextDocument)) !void {
    const gpa = std.testing.allocator;
    const rendered = try gpa.alloc(u8, actual.value.length());
    defer gpa.free(rendered);
    actual.value.readSlice(actual.value.positionFromDocbyte(0), rendered);
    try std.testing.expectEqualStrings(expected, rendered);
}

test EditorCore {
    const gpa = std.testing.allocator;
    var my_db = db_mod.BlockDB.init(gpa);
    defer my_db.deinit();
    const src_block = my_db.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
    defer src_block.unref();

    const src_component = src_block.typedComponent(bi.TextDocumentBlock) orelse return error.NotLoaded;

    src_component.applySimpleOperation(.{ .position = src_component.value.positionFromDocbyte(0), .delete_len = 0, .insert_text = "hello!" }, null);
    try testEditorContent("hello!", src_component);

    // now initialize the editor
    var editor: EditorCore = undefined;
    editor.initFromDoc(gpa, src_component);
    defer editor.deinit();

    editor.executeCommand(.{ .set_cursor_pos = .{ .position = src_component.value.positionFromDocbyte(0) } });
    editor.executeCommand(.{ .insert_text = .{ .text = "abcd!" } });
    try testEditorContent("abcd!hello!", src_component);
    editor.executeCommand(.{ .set_cursor_pos = .{ .position = src_component.value.positionFromDocbyte(0) } });
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .delete } });
    try testEditorContent("bcd!hello!", src_component);
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .stop = .byte, .mode = .delete } });
    try testEditorContent("bcd!hello!", src_component);
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .select } });
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .select } });
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .delete } });
    try testEditorContent("d!hello!", src_component);
}
