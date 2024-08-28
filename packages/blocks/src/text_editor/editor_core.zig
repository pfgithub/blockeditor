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

const BetweenCharsStop = enum {
    left_or_select,
    right_or_select,
    right_only,
    both,
};
const AsciiClassification = enum {
    whitespace,
    symbols,
    text,
    unicode,
};
fn asciiClassify(char: u8) AsciiClassification {
    if (std.ascii.isAlphanumeric(char) or char == '_') return .text;
    if (std.ascii.isWhitespace(char)) return .whitespace;
    if (char >= 0x80) return .unicode;
    return .symbols;
}
fn hasStop(left_byte: u8, right_byte: u8, stop: CursorLeftRightStop) ?BetweenCharsStop {
    switch (stop) {
        .byte => {
            return .both;
        },
        .codepoint => {
            if (right_byte < 0x80 or ((right_byte & 0b11_000000) == 0b11_000000)) {
                return .both;
            }
            return null;
        },
        .unicode_grapheme => {
            // maybe we should pass in the Position we're testing? not sure
            @panic("function does not have enough information to determine grapheme stop");
        },
        .word => {
            const left = asciiClassify(left_byte);
            const right = asciiClassify(right_byte);
            if (left == right) return null;
            if (left == .whitespace or left == .symbols) return .left_or_select;
            if (right == .whitespace or left == .symbols) return .right_or_select;
            return .both;
        },
        .unicode_word => {
            @panic("function does not have enough information to determine word stop");
        },
        .line => {
            // not sure what to do for empty lines?
            if (left_byte == '\n') return .left_or_select;
            if (right_byte == '\n') return .right_only;
            return null;
        },
    }
}
pub const CursorLeftRightStop = enum {
    // so the way these stops should work is:
    // - the whole document has invisible stops for all of these
    // - every stop is either a 'left' stop or a 'right' stop or both.
    // - left movement moves to the next left|both stop from the current position
    // - selection selects to the previous and next either stop from the current position
    // in descriptions: '<' indicates left stop, '>' indicates right stop, '|' indicates both, '.' indicates eof
    // ']' indicates right-only stop, not counted for selections

    /// .|h|e|l|l|o| |w|o|r|l|d|.
    byte,
    /// .|a|…|b|.
    codepoint,
    /// .|म|नी|ष|.
    unicode_grapheme,
    /// .|fn> <demo()> <void> <{}|.
    word,
    /// like word but for natural language instead of code. there is a unicode algorithm for this.
    unicode_word,
    /// .|\n<hello]\n<\n<goodbye!]\n|.
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

pub const IndentMode = union(enum) {
    tabs,
    spaces: usize,
    fn char(self: IndentMode) u8 {
        return switch (self) {
            .tabs => '\t',
            .spaces => ' ',
        };
    }
    fn count(self: IndentMode) usize {
        return switch (self) {
            .tabs => 1,
            .spaces => |s| s,
        };
    }
};
pub const EditorConfig = struct {
    indent_with: IndentMode,
};

// we would like EditorCore to edit any TextDocument component
// in order to apply operations to the document, we need to be able to wrap an operation
// with whatever is needed to target the right document
pub const EditorCore = struct {
    gpa: std.mem.Allocator,
    document: db_mod.TypedComponentRef(bi.text_component.TextDocument),

    cursor_positions: std.ArrayList(CursorPosition),
    drag_info: DragInfo = .{},

    config: EditorConfig = .{
        .indent_with = .{ .spaces = 4 },
    },

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

    fn getLineStart(self: *EditorCore, pos: Position) Position {
        const block = self.document.value;
        var index: usize = block.docbyteFromPosition(pos);
        while (index > 0) : (index -= 1) {
            if (index <= 0) continue; // to keep readSlice in bounds
            var byte: [1]u8 = undefined;
            block.readSlice(block.positionFromDocbyte(index - 1), &byte);
            if (byte[0] == '\n') {
                break;
            }
        }
        return block.positionFromDocbyte(index);
    }
    fn measureIndent(self: *EditorCore, line_start_pos: Position) struct { indents: usize, chars: usize } {
        var indent_segments: usize = 0;
        var chars: usize = 0;

        const block = self.document.value;
        var index: usize = block.docbyteFromPosition(line_start_pos);
        const len = block.length();
        while (index < len) : (index += 1) {
            if (index >= len) continue; // to keep readSlice in bounds
            var byte: [1]u8 = undefined;
            block.readSlice(block.positionFromDocbyte(index), &byte);
            switch (byte[0]) {
                ' ' => indent_segments += 1,
                '\t' => indent_segments += self.config.indent_with.count(),
                else => break,
            }
            chars += 1;
        }

        return .{
            .indents = std.math.divCeil(usize, indent_segments, self.config.indent_with.count()) catch unreachable,
            .chars = chars,
        };
    }

    fn toWordBoundary(self: *EditorCore, pos: Position, direction: LRDirection, stop: CursorLeftRightStop) Position {
        const block = self.document.value;
        var index: usize = block.docbyteFromPosition(pos);
        const len = block.length();
        while (switch (direction) {
            .left => index > 0,
            .right => index < len,
        }) {
            switch (direction) {
                .left => index -= 1,
                .right => index += 1,
            }
            if (index <= 0 or index >= len) continue; // readSlice will go out of range
            var bytes: [2]u8 = undefined;
            block.readSlice(block.positionFromDocbyte(index - 1), &bytes);
            const marker = hasStop(bytes[0], bytes[1], stop) orelse continue;
            switch (marker) {
                else => break,
            }
        }
        return block.positionFromDocbyte(index);
    }

    fn selectionToPosLen(self: *EditorCore, selection: Selection) PosLen {
        const block = self.document.value;

        const bufbyte_1 = block.docbyteFromPosition(selection.anchor);
        const bufbyte_2 = block.docbyteFromPosition(selection.focus);

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
            .select_all => {
                self.cursor_positions.clearRetainingCapacity();
                self.cursor_positions.append(.{
                    .pos = .{
                        .anchor = block.positionFromDocbyte(0),
                        .focus = block.positionFromDocbyte(block.length()), // same as Position.end
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
                    const res_pos = pos_len.pos;

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
            .newline => {
                for (self.cursor_positions.items) |*cursor_position| {
                    const pos_len = self.selectionToPosLen(cursor_position.pos);

                    const line_start = self.getLineStart(pos_len.pos);

                    var temp_insert_slice = std.ArrayList(u8).init(self.gpa);
                    defer temp_insert_slice.deinit();

                    temp_insert_slice.append('\n') catch @panic("oom");

                    const line_indent_count = self.measureIndent(line_start);
                    temp_insert_slice.appendNTimes(self.config.indent_with.char(), self.config.indent_with.count() * line_indent_count.indents) catch @panic("oom");

                    self.document.applySimpleOperation(.{
                        .position = pos_len.pos,
                        .delete_len = pos_len.len,
                        .insert_text = temp_insert_slice.items,
                    }, null);
                }
            },
            .indent_selection => |indent_cmd| {
                for (self.cursor_positions.items) |*cursor_position| {
                    const pos_len = self.selectionToPosLen(cursor_position.pos);
                    if (pos_len.len > 0) @panic("TODO impl indent_selection over multiple lines");
                    const line_start = self.getLineStart(pos_len.pos);
                    const line_indent_count = self.measureIndent(line_start);
                    const new_indent_count: usize = switch (indent_cmd.direction) {
                        .left => std.math.sub(usize, line_indent_count.indents, 1) catch 0,
                        .right => line_indent_count.indents + 1,
                    };

                    var temp_insert_slice = std.ArrayList(u8).init(self.gpa);
                    defer temp_insert_slice.deinit();
                    temp_insert_slice.appendNTimes(self.config.indent_with.char(), self.config.indent_with.count() * new_indent_count) catch @panic("oom");

                    self.document.applySimpleOperation(.{
                        .position = line_start,
                        .delete_len = line_indent_count.chars,
                        .insert_text = temp_insert_slice.items,
                    }, null);
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
    editor.executeCommand(.{ .insert_text = .{ .text = "……" } });
    try testEditorContent("……d!hello!", src_component);
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .stop = .codepoint, .mode = .delete } });
    try testEditorContent("…d!hello!", src_component);
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .line, .mode = .delete } });
    try testEditorContent("…", src_component);
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .stop = .line, .mode = .delete } });
    try testEditorContent("", src_component);
    editor.executeCommand(.{ .insert_text = .{ .text = "    hi();" } });
    try testEditorContent("    hi();", src_component);
    editor.executeCommand(.newline);
    try testEditorContent("    hi();\n    ", src_component);
    editor.executeCommand(.{ .insert_text = .{ .text = "goodbye();" } });
    try testEditorContent("    hi();\n    goodbye();", src_component);
    editor.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try testEditorContent("    hi();\ngoodbye();", src_component);
    editor.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try testEditorContent("    hi();\n    goodbye();", src_component);
    editor.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try testEditorContent("    hi();\n        goodbye();", src_component);
    editor.executeCommand(.newline);
    try testEditorContent("    hi();\n        goodbye();\n        ", src_component);
    editor.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    editor.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try testEditorContent("    hi();\n        goodbye();\n", src_component);
    editor.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try testEditorContent("    hi();\n        goodbye();\n    ", src_component);
    editor.executeCommand(.select_all);
    editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .delete } });
    try testEditorContent("", src_component);
}
