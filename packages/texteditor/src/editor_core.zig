//! text editing core that is mostly agnostic to the visual editor

const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;

pub const Position = bi.text_component.Position;
pub const Selection = struct {
    anchor: Position,
    focus: Position,
    pub fn at(focus: Position) Selection {
        return .{ .anchor = focus, .focus = focus };
    }
    pub fn range(anchor: Position, focus: Position) Selection {
        return .{ .anchor = anchor, .focus = focus };
    }
};
const PosLen = struct {
    pos: Position,
    right: Position,
    len: usize,
};
pub const CursorPosition = struct {
    pos: Selection,

    /// for pressing the up/down arrow going from [aaaa|a] ↓ to [a|] to [aaaa|a]. resets on move.
    vertical_move_start: ?u64 = null,
    /// when selecting up with tree-sitter to allow selecting back down. resets on move.
    node_select_start: ?Selection = null,
    /// select
    drag_info: ?DragInfo = null,

    pub fn from(sel: Selection) CursorPosition {
        return .{ .pos = sel };
    }
    pub fn at(focus: Position) CursorPosition {
        return .from(.at(focus));
    }
    pub fn range(anchor: Position, focus: Position) CursorPosition {
        return .from(.range(anchor, focus));
    }
};

pub const DragInfo = struct {
    start_pos: Position,
    sel_mode: DragSelectionMode,
};
pub const DragSelectionMode = struct {
    stop: CursorLeftRightStop,
    select: bool,
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
        .unicode_grapheme_cluster => {
            // maybe we should pass in the Position we're testing? not sure
            @panic("function does not have enough information to determine grapheme stop");
        },
        .word => {
            const left = asciiClassify(left_byte);
            const right = asciiClassify(right_byte);
            if (left == right) return null;
            if (left == .whitespace) return .left_or_select;
            if (right == .whitespace) return .right_or_select;
            return .both;
        },
        .unicode_word => {
            @panic("function does not have enough information to determine word stop");
        },
        .line => {
            // not sure what to do for empty lines?
            if (left_byte == '\n') return .left_or_select;
            if (right_byte == '\r') return .right_only;
            if (right_byte == '\n' and left_byte != '\r') return .right_only;
            return null;
        },
        .visual_line => {
            @panic("function does not have enough information to determine visual line stop");
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

    // TODO:
    // - 'word' can sometimes stop you in the middle of a grapheme cluster
    //   eg: "e\u{301}" is a single grapheme cluster, but 'word' will put your
    //   cursor right in the middle of it when you press <alt+right arrow>.
    //   ideally, anything after unicode_grapheme_cluster in this list will never
    //   place your cursor inside of a grapheme cluster.

    /// .|h|e|l|l|o| |w|o|r|l|d|.
    byte,
    /// .|a|…|b|.
    codepoint,
    /// .|म|नी|ष|.
    unicode_grapheme_cluster,
    /// .|fn> <demo()> <void> <{}|.
    word,
    /// like word but for natural language instead of code. there is a unicode algorithm for this.
    unicode_word,
    /// .|\n<hello]\n<\n<goodbye!]\n|.
    line,
    /// like line but includes soft wrapped start/ends
    visual_line,
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
    move_cursor_left_right: struct {
        direction: LRDirection,
        stop: CursorLeftRightStop,
        mode: enum { move, select },
    },
    delete: struct {
        direction: LRDirection,
        stop: CursorLeftRightStop,
    },
    move_cursor_up_down: struct {
        direction: enum { up, down },
        mode: enum { move, select },
        metric: enum { screen, raw },
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

    config: EditorConfig = .{
        .indent_with = .{ .spaces = 4 },
    },

    /// refs document
    pub fn initFromDoc(self: *EditorCore, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
        self.* = .{
            .gpa = gpa,
            .document = document,

            .cursor_positions = .init(gpa),
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
    fn getPrevLineStart(self: *EditorCore, prev_line_start: Position) Position {
        const block = self.document.value;
        const value = block.docbyteFromPosition(prev_line_start);
        if (value == 0) return prev_line_start;
        return self.getLineStart(block.positionFromDocbyte(value - 1));
    }
    fn getThisLineEnd(self: *EditorCore, prev_line_start: Position) Position {
        const block = self.document.value;
        const next_line_start = self.getNextLineStart(prev_line_start);
        const next_line_start_byte = block.docbyteFromPosition(next_line_start);
        const prev_line_start_byte = block.docbyteFromPosition(prev_line_start);

        if (prev_line_start_byte == next_line_start_byte) return prev_line_start;
        if (next_line_start_byte == block.length()) return block.positionFromDocbyte(next_line_start_byte);
        std.debug.assert(next_line_start_byte > prev_line_start_byte);
        return block.positionFromDocbyte(next_line_start_byte - 1);
    }
    fn getNextLineStart(self: *EditorCore, prev_line_start: Position) Position {
        const block = self.document.value;
        var index: usize = block.docbyteFromPosition(prev_line_start);
        const len = block.length();
        while (index < len) {
            index += 1;
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

    fn toWordBoundary(self: *EditorCore, pos: Position, direction: LRDirection, stop: CursorLeftRightStop, mode: enum { left, right, select }, nomove: enum { must_move, may_move }) Position {
        const block = self.document.value;
        const src_index = block.docbyteFromPosition(pos);
        var index: usize = src_index;
        const len = block.length();
        while (switch (direction) {
            .left => index > 0,
            .right => index < len,
        }) : ({
            if (nomove == .may_move) switch (direction) {
                .left => index -= 1,
                .right => index += 1,
            };
        }) {
            if (nomove == .must_move) switch (direction) {
                .left => index -= 1,
                .right => index += 1,
            };
            if (index <= 0 or index >= len) continue; // readSlice will go out of range
            var bytes: [2]u8 = undefined;
            block.readSlice(block.positionFromDocbyte(index - 1), &bytes);
            const marker = hasStop(bytes[0], bytes[1], stop) orelse continue;
            switch (mode) {
                .left => switch (marker) {
                    .left_or_select, .both => break,
                    .right_or_select, .right_only => {},
                },
                .right => switch (marker) {
                    .right_or_select, .right_only, .both => break,
                    .left_or_select => {},
                },
                .select => switch (marker) {
                    .left_or_select, .right_or_select, .both => break,
                    .right_only => {},
                },
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
            .right = block.positionFromDocbyte(max),
            .len = max - min,
        };
    }
    pub fn normalizePosition(self: *EditorCore, pos: Position) Position {
        const block = self.document.value;
        return block.positionFromDocbyte(block.docbyteFromPosition(pos));
    }
    /// makes sure that cursors always go to the right of any insert.
    pub fn normalizeCursors(self: *EditorCore) void {
        for (self.cursor_positions.items) |*cursor_position| {
            cursor_position.pos = .{
                .focus = self.normalizePosition(cursor_position.pos.focus),
                .anchor = self.normalizePosition(cursor_position.pos.anchor),
            };
        }
        // TODO: merge any overlapping cursors
    }
    pub fn select(self: *EditorCore, selection: Selection) void {
        self.cursor_positions.clearRetainingCapacity();
        self.cursor_positions.append(.{
            .pos = selection,
        }) catch @panic("oom");
    }
    pub fn executeCommand(self: *EditorCore, command: EditorCommand) void {
        const block = self.document.value;

        self.normalizeCursors();
        defer self.normalizeCursors();

        switch (command) {
            .set_cursor_pos => |sc_op| {
                self.select(.at(sc_op.position));
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

                    self.replaceRange(.{
                        .position = pos_len.pos,
                        .delete_len = pos_len.len,
                        .insert_text = text_op.text,
                    });
                    const res_pos = pos_len.pos;

                    cursor_position.* = .{ .pos = .{
                        .anchor = res_pos,
                        .focus = res_pos,
                    } };
                }
            },
            .move_cursor_up_down => |ud_cmd| {
                for (self.cursor_positions.items) |*cursor_position| {
                    if (ud_cmd.metric == .screen) {
                        // the view needs to provide us with some functions:
                        // - measure x position given Pos
                        // - find line start given Pos
                        // - find line end given Pos
                        // - given x position and line start, find character
                        @panic("TODO impl screen move cursor");
                    }
                    const this_line_start = self.getLineStart(cursor_position.pos.focus);
                    const distance = cursor_position.vertical_move_start orelse ( //
                        block.docbyteFromPosition(cursor_position.pos.focus) - block.docbyteFromPosition(this_line_start) //
                    );

                    const new_line_start = switch (ud_cmd.direction) {
                        .up => self.getPrevLineStart(this_line_start),
                        .down => self.getNextLineStart(this_line_start),
                    };

                    const this_line_start_pos = block.docbyteFromPosition(this_line_start);
                    const new_line_start_pos = block.docbyteFromPosition(new_line_start);
                    const new_line_end_pos = block.docbyteFromPosition(self.getThisLineEnd(new_line_start));
                    const new_line_len = new_line_end_pos - new_line_start_pos;

                    const res_offset = @min(new_line_len, distance);
                    var res_pos_idx = block.docbyteFromPosition(new_line_start) + res_offset;
                    if (this_line_start_pos == new_line_start_pos) {
                        if (new_line_start_pos == 0 and ud_cmd.direction == .up) {
                            res_pos_idx = new_line_start_pos;
                        } else if (new_line_end_pos == block.length() and ud_cmd.direction == .down) {
                            res_pos_idx = new_line_end_pos;
                        }
                    }
                    const res_pos = block.positionFromDocbyte(res_pos_idx);

                    cursor_position.* = .{
                        .pos = .{
                            .anchor = switch (ud_cmd.mode) {
                                .move => res_pos,
                                .select => cursor_position.pos.anchor,
                            },
                            .focus = res_pos,
                        },
                        .vertical_move_start = distance,
                    };
                }
            },
            .move_cursor_left_right => |lr_cmd| {
                for (self.cursor_positions.items) |*cursor_position| {
                    const current_pos = self.selectionToPosLen(cursor_position.pos);
                    if (current_pos.len > 0 and lr_cmd.mode == .move) {
                        cursor_position.* = switch (lr_cmd.direction) {
                            .left => .at(current_pos.pos),
                            .right => .at(current_pos.right),
                        };
                        return;
                    }

                    const moved = self.toWordBoundary(cursor_position.pos.focus, lr_cmd.direction, lr_cmd.stop, switch (lr_cmd.direction) {
                        .left => .left,
                        .right => .right,
                    }, .must_move);

                    switch (lr_cmd.mode) {
                        .move => {
                            cursor_position.* = .at(moved);
                        },
                        .select => {
                            cursor_position.* = .range(cursor_position.pos.anchor, moved);
                        },
                    }
                }
            },
            .delete => |lr_cmd| {
                for (self.cursor_positions.items) |*cursor_position| {
                    const moved = self.toWordBoundary(cursor_position.pos.focus, lr_cmd.direction, lr_cmd.stop, switch (lr_cmd.direction) {
                        .left => .left,
                        .right => .right,
                    }, .must_move);

                    // if there is a selection, delete the selection
                    // if there is no selection, delete from the focus in the direction to the stop
                    var pos_len = self.selectionToPosLen(cursor_position.pos);
                    if (pos_len.len == 0) {
                        pos_len = self.selectionToPosLen(.{ .anchor = cursor_position.pos.focus, .focus = moved });
                    }
                    self.replaceRange(.{
                        .position = pos_len.pos,
                        .delete_len = pos_len.len,
                        .insert_text = "",
                    });
                    const res_pos = pos_len.pos;

                    cursor_position.* = .at(res_pos);
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

                    self.replaceRange(.{
                        .position = pos_len.pos,
                        .delete_len = pos_len.len,
                        .insert_text = temp_insert_slice.items,
                    });
                }
            },
            .indent_selection => |indent_cmd| {
                for (self.cursor_positions.items) |*cursor_position| {
                    const pos_len = self.selectionToPosLen(cursor_position.pos);
                    const end_pos = block.positionFromDocbyte(block.docbyteFromPosition(pos_len.pos) + pos_len.len);
                    var line_start = self.getLineStart(pos_len.pos);
                    while (true) {
                        const next_line_start = self.getNextLineStart(line_start);
                        defer line_start = next_line_start;
                        const end = block.docbyteFromPosition(next_line_start) >= block.docbyteFromPosition(end_pos);
                        const line_indent_count = self.measureIndent(line_start);
                        const new_indent_count: usize = switch (indent_cmd.direction) {
                            .left => std.math.sub(usize, line_indent_count.indents, 1) catch 0,
                            .right => line_indent_count.indents + 1,
                        };

                        var temp_insert_slice = std.ArrayList(u8).init(self.gpa);
                        defer temp_insert_slice.deinit();
                        temp_insert_slice.appendNTimes(self.config.indent_with.char(), self.config.indent_with.count() * new_indent_count) catch @panic("oom");

                        self.replaceRange(.{
                            .position = line_start,
                            .delete_len = line_indent_count.chars,
                            .insert_text = temp_insert_slice.items,
                        });
                        if (end) break;
                    }
                }
            },
            .ts_select_node => {
                @panic("TODO tree-sitter");
            },
            .undo => {
                // const undo_op = self.undo_list.popOrNull() orelse return;
                // _ = undo_op;
                @panic("TODO undo");
            },
            .redo => {
                // const redo_op = self.redo_list.popOrNull() orelse return;
                // _ = redo_op;
                @panic("TODO redo");
            },
        }
    }
    fn getEnsureOneCursor(self: *EditorCore, default_pos: Position) *CursorPosition {
        if (self.cursor_positions.items.len == 0) {
            self.select(.at(default_pos));
        } else if (self.cursor_positions.items.len > 1) {
            self.cursor_positions.items.len = 1;
        }
        return &self.cursor_positions.items[0];
    }
    pub fn onClick(self: *EditorCore, pos: Position, click_count: usize, shift_held: bool) void {
        const cursor = self.getEnsureOneCursor(pos);
        const sel_mode: DragSelectionMode = switch (click_count) {
            1 => .{ .stop = .byte, .select = false },
            2 => .{ .stop = .word, .select = true },
            3 => .{ .stop = .line, .select = true },
            else => {
                cursor.drag_info = null;
                self.executeCommand(.select_all);
                return;
            },
        };

        if (shift_held) {
            if (cursor.drag_info == null) {
                cursor.drag_info = .{
                    .start_pos = cursor.pos.focus,
                    .sel_mode = sel_mode,
                };
            }
            if (sel_mode.select) cursor.drag_info.?.sel_mode = sel_mode;
        } else {
            cursor.drag_info = .{
                .start_pos = pos,
                .sel_mode = sel_mode,
            };
        }
        self.onDrag(pos);
    }
    pub fn onDrag(self: *EditorCore, pos: Position) void {
        const cursor = self.getEnsureOneCursor(pos);
        if (cursor.drag_info == null) return;

        const drag_info = cursor.drag_info.?;
        const stop = drag_info.sel_mode.stop;
        const anchor_pos = drag_info.start_pos;
        const anchor_l = self.toWordBoundary(anchor_pos, .left, stop, .select, .may_move);
        const focus_l = self.toWordBoundary(pos, .left, stop, .select, .may_move);
        if (drag_info.sel_mode.select) {
            const anchor_r = self.toWordBoundary(anchor_pos, .right, stop, .select, .must_move);
            const focus_r = self.toWordBoundary(pos, .right, stop, .select, .must_move);

            // now:
            // we select from @min(all) to @max(all) and put the cursor on (focus_l < anchor_l ? left : right)

            const anchor_l_docbyte = self.document.value.docbyteFromPosition(anchor_l);
            const anchor_r_docbyte = self.document.value.docbyteFromPosition(anchor_r);
            const focus_l_docbyte = self.document.value.docbyteFromPosition(focus_l);
            const focus_r_docbyte = self.document.value.docbyteFromPosition(focus_r);

            const min_docbyte = @min(@min(anchor_l_docbyte, anchor_r_docbyte), @min(focus_l_docbyte, focus_r_docbyte));
            const max_docbyte = @max(@max(anchor_l_docbyte, anchor_r_docbyte), @max(focus_l_docbyte, focus_r_docbyte));
            const min_pos = self.document.value.positionFromDocbyte(min_docbyte);
            const max_pos = self.document.value.positionFromDocbyte(max_docbyte);

            if (focus_l_docbyte < anchor_l_docbyte) {
                cursor.pos = .range(max_pos, min_pos);
            } else {
                cursor.pos = .range(min_pos, max_pos);
            }
        } else {
            cursor.pos = .range(anchor_l, focus_l);
        }
    }

    pub fn replaceRange(self: *EditorCore, operation: bi.text_component.TextDocument.SimpleOperation) void {
        self.document.applySimpleOperation(operation, null);
    }

    pub fn getCursorPositions(self: *EditorCore) CursorPositions {
        const block = self.document.value;

        var positions: CursorPositions = .init(self.gpa);
        for (self.cursor_positions.items) |cursor| {
            const anchor = block.docbyteFromPosition(cursor.pos.anchor);
            const focus = block.docbyteFromPosition(cursor.pos.focus);

            positions.add(anchor, focus);
        }
        positions.sort();

        return positions;
    }
};

const PositionItem = struct {
    bufbyte: usize,
    mode: enum { start, end },
    kind: enum { anchor, focus },

    fn compareFn(_: void, a: PositionItem, b: PositionItem) bool {
        return a.bufbyte < b.bufbyte;
    }
};
pub const CursorPosState = enum { none, start, focus, end };
pub const CursorPosRes = struct {
    left_cursor: CursorPosState,
    selected: bool,
};
pub const CursorPositions = struct {
    idx: usize,
    count: i32,
    positions: std.ArrayList(PositionItem),

    pub fn init(gpa: std.mem.Allocator) CursorPositions {
        return .{ .idx = 0, .count = 0, .positions = .init(gpa) };
    }
    pub fn deinit(self: *CursorPositions) void {
        self.positions.deinit();
    }
    fn add(self: *CursorPositions, anchor: usize, focus: usize) void {
        const left = @min(anchor, focus);
        const right = @max(anchor, focus);
        self.positions.append(.{ .mode = .start, .bufbyte = left, .kind = if (left == focus) .focus else .anchor }) catch @panic("oom");
        self.positions.append(.{ .mode = .end, .bufbyte = right, .kind = if (left == focus) .anchor else .focus }) catch @panic("oom");
    }
    fn sort(self: *CursorPositions) void {
        std.mem.sort(PositionItem, self.positions.items, {}, PositionItem.compareFn);
    }

    pub fn advanceAndRead(self: *CursorPositions, bufbyte: usize) CursorPosRes {
        var left_cursor: CursorPosState = .none;
        while (true) : (self.idx += 1) {
            if (self.idx >= self.positions.items.len) break;
            const itm = self.positions.items[self.idx];
            if (itm.bufbyte > bufbyte) break;
            switch (itm.mode) {
                .start => self.count += 1,
                .end => self.count -= 1,
            }
            if (itm.bufbyte == bufbyte) {
                left_cursor = switch (left_cursor) {
                    .none => switch (itm.kind) {
                        .anchor => switch (itm.mode) {
                            .start => .start,
                            .end => .end,
                        },
                        .focus => .focus,
                    },
                    .start, .end, .focus => .focus,
                };
            }
        }
        return .{
            .left_cursor = left_cursor,
            .selected = self.count != 0,
        };
    }
};

fn testEditorContent(expected: []const u8, editor: *EditorCore) !void {
    const actual = &editor.document;
    const gpa = std.testing.allocator;
    var rendered = std.ArrayList(u8).init(gpa);
    defer rendered.deinit();
    try rendered.ensureUnusedCapacity(actual.value.length() + 1);
    rendered.appendNTimesAssumeCapacity(undefined, actual.value.length());
    actual.value.readSlice(actual.value.positionFromDocbyte(0), rendered.items);
    rendered.appendAssumeCapacity('\x00');

    var positions = editor.getCursorPositions();
    defer positions.deinit();
    var rendered2 = std.ArrayList(u8).init(gpa);
    defer rendered2.deinit();
    for (rendered.items, 0..) |char, i| {
        const pos_info = positions.advanceAndRead(i);
        switch (pos_info.left_cursor) {
            .none => {},
            .start => try rendered2.append('['),
            .focus => try rendered2.append('|'),
            .end => try rendered2.append(']'),
        }
        try rendered2.append(char);
    }
    std.debug.assert(rendered2.pop() == '\x00');

    try std.testing.expectEqualStrings(expected, rendered2.items);
}

const EditorTester = struct {
    gpa: std.mem.Allocator,
    my_db: db_mod.BlockDB,
    src_block: *db_mod.BlockRef,
    src_component: db_mod.TypedComponentRef(bi.TextDocumentBlock.Child),
    editor: EditorCore,

    pub fn init(res: *EditorTester, gpa: std.mem.Allocator, initial_text: []const u8) void {
        res.* = .{
            .gpa = gpa,
            .my_db = undefined,
            .src_block = undefined,
            .src_component = undefined,
            .editor = undefined,
        };
        res.my_db = .init(gpa);
        res.src_block = res.my_db.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
        res.src_component = res.src_block.typedComponent(bi.TextDocumentBlock) orelse unreachable;
        res.editor.initFromDoc(gpa, res.src_component);

        res.src_component.applySimpleOperation(.{ .position = res.src_component.value.positionFromDocbyte(0), .delete_len = 0, .insert_text = initial_text }, null);
    }
    pub fn deinit(self: *EditorTester) void {
        self.editor.deinit();
        self.src_block.unref();
        self.my_db.deinit();
    }

    pub fn expectContent(self: *EditorTester, expected: []const u8) !void {
        try testEditorContent(expected, &self.editor);
    }
    pub fn executeCommand(self: *EditorTester, command: EditorCommand) void {
        self.editor.executeCommand(command);
    }
    pub fn pos(self: *EditorTester, docbyte: usize) Position {
        return self.editor.document.value.positionFromDocbyte(docbyte);
    }
};

/// Chars:
/// left_or_select : `<`
/// right_or_select : `>`
/// right_only : `]`
/// both : `|`
fn testFindStops(expected: []const u8, stop_type: CursorLeftRightStop) !void {
    var test_src = std.ArrayList(u8).init(std.testing.allocator);
    defer test_src.deinit();
    for (expected) |char| {
        switch (char) {
            '<', '>', ']', '|' => {},
            else => try test_src.append(char),
        }
    }
    var test_res = std.ArrayList(u8).init(std.testing.allocator);
    defer test_res.deinit();
    for (0..test_src.items.len + 1) |i| {
        const hs_res = blk: {
            if (i == 0 or i == test_src.items.len) break :blk .both;
            break :blk hasStop(test_src.items[i - 1], test_src.items[i], stop_type);
        };
        if (hs_res) |hr| try test_res.append(switch (hr) {
            .left_or_select => '<',
            .right_or_select => '>',
            .right_only => ']',
            .both => '|',
        });
        if (i < test_src.items.len) try test_res.append(test_src.items[i]);
    }
    try std.testing.expectEqualStrings(expected, test_res.items);
}
test hasStop {
    inline for (std.meta.fields(CursorLeftRightStop)) |field| {
        const v = @field(CursorLeftRightStop, field.name);
        switch (v) {
            .byte => {
                try testFindStops("|h|e|l|l|o|", v);
                try testFindStops("|u|\xE2|\x80|\xA6|!|", v);
            },
            .codepoint => {
                try testFindStops("|u|\xE2\x80\xA6|!|", v);
                try testFindStops("|H|e|\u{301}|l|l|o|", .codepoint);
            },
            .unicode_grapheme_cluster => {
                // TODO
                // try testFindStops("|म|नी|ष|", v);
                // try testFindStops("|H|e\u{301}|l|l|o|", v);
            },
            .word => {
                try testFindStops("|hello> <world|", v);
                try testFindStops("|    <\\\\>    <}>\n    <\\\\>    <@|vertex> <fn> <vert|(|in|:> <VertexIn|)|", v);
                try testFindStops("| <myfn|(|crazy|)> |", v);
                try testFindStops("|He|\u{301}|llo|", v); // TODO: don't put word stops in the middle of a grapheme cluster
            },
            .unicode_word => {
                // TODO. also unicode word segmentation is system language dependant for some reason.
                // so either make it use english or ask for the system language and use that.
                // try testFindStops("|这|只是|一些|随机|的|文本|", v);
            },
            .line => {
                try testFindStops("|line one]\n<line two]\n<line three|", v);
            },
            .visual_line => {
                // todo
            },
        }
    }
}

test EditorCore {
    var tester: EditorTester = undefined;
    tester.init(std.testing.allocator, "hello!");
    defer tester.deinit();

    try tester.expectContent("hello!");
    tester.executeCommand(.{ .set_cursor_pos = .{ .position = tester.pos(0) } });
    try tester.expectContent("|hello!");
    tester.executeCommand(.{ .insert_text = .{ .text = "abcd!" } });
    try tester.expectContent("abcd!|hello!");
    tester.executeCommand(.{ .set_cursor_pos = .{ .position = tester.pos(0) } });
    try tester.expectContent("|abcd!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .right, .stop = .byte } });
    try tester.expectContent("|bcd!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    try tester.expectContent("|bcd!hello!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .select } });
    try tester.expectContent("[b|cd!hello!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .byte, .mode = .select } });
    try tester.expectContent("[bc|d!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .right, .stop = .byte } });
    try tester.expectContent("|d!hello!");
    tester.executeCommand(.{ .insert_text = .{ .text = "……" } });
    try tester.expectContent("……|d!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .codepoint } });
    try tester.expectContent("…|d!hello!");
    tester.executeCommand(.{ .delete = .{ .direction = .right, .stop = .line } });
    try tester.expectContent("…|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .line } });
    try tester.expectContent("|");
    tester.executeCommand(.{ .insert_text = .{ .text = "    hi();" } });
    try tester.expectContent("    hi();|");
    tester.executeCommand(.newline);
    try tester.expectContent("    hi();\n    |");
    tester.executeCommand(.{ .insert_text = .{ .text = "goodbye();" } });
    try tester.expectContent("    hi();\n    goodbye();|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try tester.expectContent("    hi();\ngoodbye();|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try tester.expectContent("    hi();\n    goodbye();|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try tester.expectContent("    hi();\n        goodbye();|");
    tester.executeCommand(.newline);
    try tester.expectContent("    hi();\n        goodbye();\n        |");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try tester.expectContent("    hi();\n        goodbye();\n|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try tester.expectContent("    hi();\n        goodbye();\n    |");
    tester.executeCommand(.select_all);
    try tester.expectContent("[    hi();\n        goodbye();\n    |");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try tester.expectContent("[hi();\n    goodbye();\n|");
    tester.executeCommand(.{ .indent_selection = .{ .direction = .right } });
    try tester.expectContent("    [hi();\n        goodbye();\n|"); // not sure if this is what we want
    tester.executeCommand(.{ .indent_selection = .{ .direction = .left } });
    try tester.expectContent("[hi();\n    goodbye();\n|");
    tester.executeCommand(.{ .delete = .{ .direction = .right, .stop = .byte } });
    try tester.expectContent("|");
    tester.executeCommand(.{ .insert_text = .{ .text = "hello\nto the world!" } });
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .stop = .byte, .mode = .move } });
    try tester.expectContent(
        \\hello
        \\to the world|!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .raw, .mode = .move } });
    try tester.expectContent(
        \\hello|
        \\to the world!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .raw, .mode = .move } });
    try tester.expectContent(
        \\hello
        \\to the world|!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .raw, .mode = .move } });
    try tester.expectContent(
        \\hello|
        \\to the world!
    );
    tester.executeCommand(.{ .insert_text = .{ .text = "!" } });
    try tester.expectContent(
        \\hello!|
        \\to the world!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .raw, .mode = .move } });
    try tester.expectContent(
        \\hello!
        \\to the| world!
    );

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "hello" } });
    try tester.expectContent("hello|");

    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .byte } });
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .byte } });
    try tester.expectContent("hel|lo");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .raw, .mode = .select } });
    try tester.expectContent("hel[lo|");

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "hela\n\ninput\n\n\nlo!" } });
    try tester.expectContent("hela\n\ninput\n\n\nlo!|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .raw, .mode = .move } });
    try tester.expectContent("hela\n\ninput\n\n|\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .raw, .mode = .move } });
    try tester.expectContent("hela\n\ninput\n|\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .raw, .mode = .move } });
    try tester.expectContent("hela\n\ninp|ut\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .byte } });
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .byte } });
    try tester.expectContent("hela\n\ninput|\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .raw, .mode = .move } });
    try tester.expectContent("hela\n|\ninput\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .raw, .mode = .move } });
    try tester.expectContent("hela|\n\ninput\n\n\nlo!");

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "here are a few words to traverse!" } });
    try tester.expectContent("here are a few words to traverse!|");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to traverse|!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to |traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words |to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few |words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a |few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here are |a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("here |are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("|here are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .mode = .move, .stop = .word } });
    try tester.expectContent("|here are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here| are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are| a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a| few words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few| words to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words| to traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to| traverse!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to traverse|!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to traverse!|");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .word } });
    try tester.expectContent("here are a few words to traverse!|");

    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .raw, .mode = .move } });
    try tester.expectContent("|here are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .raw, .mode = .move } });
    try tester.expectContent("here are a few words to traverse!|");

    tester.editor.onClick(tester.pos(13), 1, false);
    try tester.expectContent("here are a fe|w words to traverse!");
    tester.editor.onClick(tester.pos(17), 1, true);
    try tester.expectContent("here are a fe[w wo|rds to traverse!");
    tester.editor.onClick(tester.pos(6), 1, false);
    try tester.expectContent("here a|re a few words to traverse!");
    tester.editor.onClick(tester.pos(6), 2, false);
    try tester.expectContent("here [are| a few words to traverse!");
    tester.editor.onDrag(tester.pos(13));
    try tester.expectContent("here [are a few| words to traverse!");
    tester.editor.onDrag(tester.pos(1));
    try tester.expectContent("|here are] a few words to traverse!");

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = (
        \\    \\    }
        \\    \\    @vertex fn vert(in: VertexIn)
    ) } });
    tester.executeCommand(.{ .set_cursor_pos = .{ .position = tester.pos(11) } });
    try tester.expectContent(
        \\    \\    }|
        \\    \\    @vertex fn vert(in: VertexIn)
    );
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .word, .mode = .move } });
    try tester.expectContent(
        \\    \\    }
        \\    \\|    @vertex fn vert(in: VertexIn)
    );
}

const zg_grapheme = @import("zg_grapheme");
var _global_grapheme_data: ?zg_grapheme.GraphemeData = null;
var _global_zg_alloc: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
fn getGlobalGraphemeData() *const zg_grapheme.GraphemeData {
    if (_global_grapheme_data == null) {
        _global_grapheme_data = zg_grapheme.GraphemeData.init(_global_zg_alloc.allocator()) catch @panic("grapheme data init fail");
    }
    return &_global_grapheme_data.?;
}

// this will be problematic on very long lines
// also apparently \r\n is a single grapheme cluster
// we'll constantly be putting cursors in the middle of it with the current
// end of line detection, but that can be fixed
fn clusterLine(line_content: []const u8) void {
    // https://docs.rs/unicode-segmentation/1.8.0/unicode_segmentation/struct.GraphemeCursor.html
    // this is what we want
    const gd = getGlobalGraphemeData();
    var iter = zg_grapheme.Iterator.init(line_content, gd);
    while (iter.next()) |gc| {
        // gc.offset, gc.len
        _ = gc;
    }
}

// apparently sometimes you're not supposed to backspace the whole
// grapheme cluster? like we need backspace_only marks in text
// segmentation because "किमपि" is three grapheme clusters but five
// backspaces. but "👨‍👩‍👧‍👧" is one grapheme cluster and one backspace.

test "grapheme cluster" {
    // so unfortunately:
    // - starting clustering partway through a codepoint produces a bunch of
    //   grapheme clusters holding just a single byte
    // - starting clustering partway through a cluster sometimes splits that cluster
    //   up into two. ie |A[zwj]B -> "A[zwj]B" but A|[zwj]B -> "[zwj]" "B"
    // - "🇷🇸🇮🇴" <- this is worst case. a line full of flags you just have to keep
    //   searching back and back and back until the start, then walk forwards
    //   again. deleting one codepoint could shift every flag after it.

    const gd = getGlobalGraphemeData();
    const str = "He\u{301}! …मनीष!👨‍👩‍👧‍👧";

    var iter = zg_grapheme.Iterator.init(str, gd);
    while (iter.next()) |gc| {
        std.log.err("gc: \"{s}\"", .{str[gc.offset..][0..gc.len]});
    }

    // if we can't seek backwards, we can segment out the whole line
    // until we find the segment we care about

    // i wonder if we could walk backwards one byte at a time until
    // the first cluster is found that does not contain the target byte?
    // or if that is invalid with some character setups
}
