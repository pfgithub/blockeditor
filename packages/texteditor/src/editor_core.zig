//! text editing core that is mostly agnostic to the visual editor

const std = @import("std");
const blocks_mod = @import("blocks");
const seg_dep = @import("grapheme_cursor");
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
    len: u64,
};
pub const CursorPosition = struct {
    pos: Selection,

    /// for pressing the up/down arrow going from [aaaa|a] ↓ to [a|] to [aaaa|a]. resets on move.
    vertical_move_start: ?Position = null,
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
    // TODO left_delete_only, for backspacing part of a grapheme cluster
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
fn hasStop(doc: seg_dep.GenericDocument, docbyte: u64, stop: CursorLeftRightStop) ?BetweenCharsStop {
    if (docbyte == 0 or docbyte == doc.len) unreachable;

    if (stop == .unicode_grapheme_cluster) {
        return switch (doc.isBoundary(docbyte)) {
            true => .both,
            false => null,
        };
    }

    const docl = doc.read(doc, docbyte - 1, .right);
    const left_byte = docl[0];
    const right_byte = if (docl.len > 1) docl[1] else blk: {
        const docl2 = doc.read(doc, docbyte, .right);
        break :blk docl2[0];
    };
    return hasStop_bytes(left_byte, right_byte, stop);
}
fn hasStop_bytes(left_byte: u8, right_byte: u8, stop: CursorLeftRightStop) ?BetweenCharsStop {
    switch (stop) {
        .byte => {
            return .both;
        },
        .codepoint => {
            _ = std.unicode.utf8ByteSequenceLength(right_byte) catch return null;
            return .both;
        },
        .unicode_grapheme_cluster => {
            @panic("handled in hasStop()");
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
            @panic("TODO: unicode_word stop");
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
pub const CursorHorizontalPositionMetric = enum {
    byte,
    codepoint,
    unicode_grapheme_cluster,

    screen, // view-dependant
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
        mode: enum { move, select, duplicate },
        metric: CursorHorizontalPositionMetric,
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
    fn count(self: IndentMode) u64 {
        return switch (self) {
            .tabs => 1,
            .spaces => |s| s,
        };
    }
};
pub const EditorConfig = struct {
    indent_with: IndentMode,
};

const DocumentDocument = struct {
    text_doc: *bi.text_component.TextDocument,

    pub fn read(self_g: seg_dep.GenericDocument, offset: u64, direction: seg_dep.GDirection) []const u8 {
        const self = self_g.cast(DocumentDocument);

        return switch (direction) {
            .right => self.text_doc.read(self.text_doc.positionFromDocbyte(offset)),
            .left => self.text_doc.readLeft(self.text_doc.positionFromDocbyte(offset)),
            // TODO: implement and switch to .readLeft()
            // note that switching before seg_dep.segmentation_issue_139 is fixed will cause
            // inconsistent behaviour moving the cursor left over an emoji with zwj that is split
            // in half with a span vs one that is not
        };
    }

    pub fn doc(self: *DocumentDocument) seg_dep.GenericDocument {
        return .from(DocumentDocument, self, self.text_doc.length());
    }
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
        var index: u64 = block.docbyteFromPosition(pos);
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
        var index: u64 = block.docbyteFromPosition(prev_line_start);
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
    fn measureIndent(self: *EditorCore, line_start_pos: Position) struct { indents: u64, chars: u64 } {
        var indent_segments: u64 = 0;
        var chars: u64 = 0;

        const block = self.document.value;
        var index: u64 = block.docbyteFromPosition(line_start_pos);
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
            .indents = std.math.divCeil(u64, indent_segments, self.config.indent_with.count()) catch unreachable,
            .chars = chars,
        };
    }

    fn toWordBoundary(self: *EditorCore, pos: Position, direction: LRDirection, stop: CursorLeftRightStop, mode: enum { left, right, select }, nomove: enum { must_move, may_move }) Position {
        const block = self.document.value;
        var docdoc = DocumentDocument{ .text_doc = block };
        const gendoc = docdoc.doc();

        const src_index = block.docbyteFromPosition(pos);
        var index: u64 = src_index;
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
            if (index <= 0 or index >= len) break; // readSlice will go out of range
            const marker = hasStop(gendoc, index, stop) orelse continue;
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
    /// makes sure cursors are:
    /// - on live spans, not deleted ones `hello ` `5|` `world` -> `hello `5` `|world`
    /// - not overlapping `he[llo[ wor|ld|` -> `he[llo world|`
    /// - in left-to-right order ``
    pub fn normalizeCursors(self: *EditorCore) void {
        const block = self.document.value;

        var positions = self.getCursorPositions();
        defer positions.deinit();

        var uncommitted_start: ?u64 = null;

        const len_start = self.cursor_positions.items.len;
        self.cursor_positions.clearRetainingCapacity();
        for (positions.positions.items) |pos| {
            const prev_selected = positions.count > 0;
            if (positions.idx >= positions.positions.items.len) break;
            if (positions.positions.items[positions.idx].bufbyte > pos.bufbyte) continue;
            const sel_info = positions.advanceAndRead(pos.bufbyte);
            const next_selected = sel_info.selected;

            var res_cursor = sel_info.left_cursor_extra.?;
            if (prev_selected and next_selected) {
                // don't put a cursor
                continue;
            } else if (!prev_selected and next_selected) {
                uncommitted_start = pos.bufbyte;
            } else if (prev_selected and !next_selected) {
                // commit
                std.debug.assert(uncommitted_start != null);
                if (sel_info.left_cursor == .focus) {
                    res_cursor.pos = .range(
                        block.positionFromDocbyte(uncommitted_start.?),
                        block.positionFromDocbyte(pos.bufbyte),
                    );
                } else {
                    res_cursor.pos = .range(
                        block.positionFromDocbyte(pos.bufbyte),
                        block.positionFromDocbyte(uncommitted_start.?),
                    );
                }
                self.cursor_positions.appendAssumeCapacity(res_cursor);
                uncommitted_start = null;
            } else if (!prev_selected and !next_selected) {
                // commit
                std.debug.assert(uncommitted_start == null);
                res_cursor.pos = .at(
                    block.positionFromDocbyte(pos.bufbyte),
                );
                self.cursor_positions.appendAssumeCapacity(res_cursor);
            } else unreachable;
        }
        std.debug.assert(uncommitted_start == null);
        const len_end = self.cursor_positions.items.len;
        std.debug.assert(len_end <= len_start);
    }
    pub fn select(self: *EditorCore, selection: Selection) void {
        self.cursor_positions.clearRetainingCapacity();
        self.cursor_positions.append(.{
            .pos = selection,
        }) catch @panic("oom");
    }
    fn measureMetric(self: *EditorCore, pos: Position, metric: CursorHorizontalPositionMetric) u64 {
        const block = self.document.value;
        const this_line_start = self.getLineStart(pos);
        return switch (metric) {
            .byte => block.docbyteFromPosition(pos) - block.docbyteFromPosition(this_line_start),
            else => @panic("TODO support metric"),
        };
    }
    fn applyMetric(self: *EditorCore, new_line_start: Position, metric: CursorHorizontalPositionMetric, metric_value: u64) Position {
        const block = self.document.value;

        const new_line_start_pos = block.docbyteFromPosition(new_line_start);
        const new_line_end_pos = block.docbyteFromPosition(self.getThisLineEnd(new_line_start));
        const new_line_len = new_line_end_pos - new_line_start_pos;
        return switch (metric) {
            .byte => block.positionFromDocbyte(new_line_start_pos + @min(new_line_len, metric_value)),
            else => @panic("TODO support metric"),
        };
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
                const orig_len = self.cursor_positions.items.len;
                for (0..orig_len) |i| {
                    const cursor_position = &self.cursor_positions.items[i];
                    switch (ud_cmd.metric) {
                        .byte => {},
                        else => @panic("TODO impl ud_cmd metric"),
                    }
                    const this_line_start = self.getLineStart(cursor_position.pos.focus);
                    var target_pos: Position = cursor_position.vertical_move_start orelse cursor_position.pos.focus;
                    _ = &target_pos; // works around a miscompilation where target_pos changes values after writing to cursor_position :/
                    const target = self.measureMetric(target_pos, ud_cmd.metric);

                    const new_line_start = switch (ud_cmd.direction) {
                        .up => self.getPrevLineStart(this_line_start),
                        .down => self.getNextLineStart(this_line_start),
                    };

                    // special-case first and last lines
                    const res_pos = if (ud_cmd.direction == .up and block.docbyteFromPosition(this_line_start) == 0) blk: {
                        break :blk new_line_start;
                    } else if (ud_cmd.direction == .down and block.docbyteFromPosition(self.getThisLineEnd(this_line_start)) == block.length()) blk: {
                        break :blk self.getThisLineEnd(new_line_start);
                    } else blk: {
                        break :blk self.applyMetric(new_line_start, ud_cmd.metric, target);
                    };

                    switch (ud_cmd.mode) {
                        .move => {
                            cursor_position.* = .{ .pos = .at(res_pos), .vertical_move_start = target_pos };
                            cursor_position.vertical_move_start = target_pos;
                        },
                        .select => cursor_position.* = .{ .pos = .range(cursor_position.pos.anchor, res_pos), .vertical_move_start = target_pos },
                        .duplicate => {
                            self.cursor_positions.append(.{ .pos = .at(res_pos), .vertical_move_start = target_pos }) catch @panic("oom");
                        },
                    }
                    // cursor_position pointer is invalidated
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
                    temp_insert_slice.appendNTimes(self.config.indent_with.char(), usi(self.config.indent_with.count() * line_indent_count.indents)) catch @panic("oom");

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
                        const new_indent_count: u64 = switch (indent_cmd.direction) {
                            .left => std.math.sub(u64, line_indent_count.indents, 1) catch 0,
                            .right => line_indent_count.indents + 1,
                        };

                        var temp_insert_slice = std.ArrayList(u8).init(self.gpa);
                        defer temp_insert_slice.deinit();
                        temp_insert_slice.appendNTimes(self.config.indent_with.char(), usi(self.config.indent_with.count() * new_indent_count)) catch @panic("oom");

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
    // change to sel_mode: DragSelectionMode, shift_held: bool?
    // make this an EditorCommand?
    pub fn onClick(self: *EditorCore, pos: Position, click_count: usize, shift_held: bool) void {
        const cursor = self.getEnsureOneCursor(pos);
        const sel_mode: DragSelectionMode = switch (click_count) {
            1 => .{ .stop = .unicode_grapheme_cluster, .select = false },
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

            positions.add(anchor, focus, cursor);
        }
        positions.sort();

        return positions;
    }
};

const PositionItem = struct {
    bufbyte: u64,
    mode: enum { start, end },
    kind: enum { anchor, focus },

    extra: CursorPosition,

    fn compareFn(_: void, a: PositionItem, b: PositionItem) bool {
        return a.bufbyte < b.bufbyte;
    }
};
pub const CursorPosState = enum { none, start, focus, end };
pub const CursorPosRes = struct {
    left_cursor: CursorPosState,
    left_cursor_extra: ?CursorPosition,
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
    fn add(self: *CursorPositions, anchor: u64, focus: u64, extra: CursorPosition) void {
        const left = @min(anchor, focus);
        const right = @max(anchor, focus);
        self.positions.append(.{ .mode = .start, .bufbyte = left, .kind = if (left == focus) .focus else .anchor, .extra = extra }) catch @panic("oom");
        self.positions.append(.{ .mode = .end, .bufbyte = right, .kind = if (left == focus) .anchor else .focus, .extra = extra }) catch @panic("oom");
    }
    fn sort(self: *CursorPositions) void {
        std.mem.sort(PositionItem, self.positions.items, {}, PositionItem.compareFn);
    }

    pub fn advanceAndRead(self: *CursorPositions, bufbyte: u64) CursorPosRes {
        var left_cursor: CursorPosState = .none;
        var left_cursor_extra: ?CursorPosition = null;
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
            left_cursor_extra = itm.extra;
        }
        return .{
            .left_cursor = left_cursor,
            .left_cursor_extra = left_cursor_extra,
            .selected = self.count != 0,
        };
    }
};

fn testEditorContent(expected: []const u8, editor: *EditorCore) !void {
    const actual = &editor.document;
    const gpa = std.testing.allocator;
    var rendered = std.ArrayList(u8).init(gpa);
    defer rendered.deinit();
    try rendered.ensureUnusedCapacity(usi(actual.value.length() + 1));
    rendered.appendNTimesAssumeCapacity(undefined, usi(actual.value.length()));
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
        self.src_component.unref();
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
    var test_src_doc_itm = seg_dep.SliceDocument{ .slice = test_src.items };
    const test_src_doc = test_src_doc_itm.doc();

    var test_res = std.ArrayList(u8).init(std.testing.allocator);
    defer test_res.deinit();
    for (0..test_src.items.len + 1) |i| {
        const hs_res = blk: {
            if (i == 0 or i == test_src.items.len) break :blk .both;
            break :blk hasStop(test_src_doc, i, stop_type);
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
                try testFindStops("|H|e|\u{301}|l|l|o|", v);
            },
            .unicode_grapheme_cluster => {
                try testFindStops("|म|नी|ष|", v);
                try testFindStops("|H|e\u{301}|l|l|o|", v);
                try testFindStops("|🇷🇸|🇮🇴|🇷🇸|🇮🇴|🇷🇸|🇮🇴|🇷🇸|🇮🇴|", v);
                try testFindStops("|\u{301}|", v);
                if (!seg_dep.segmentation_issue_139) try testFindStops("|h|i|👨‍👩‍👧‍👧|b|y|e|", v);
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
    try std.testing.expectEqual(@as(usize, 1), tester.editor.cursor_positions.items.len);
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
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move } });
    try tester.expectContent(
        \\hello|
        \\to the world!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .byte, .mode = .move } });
    try tester.expectContent(
        \\hello
        \\to the world|!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move } });
    try tester.expectContent(
        \\hello|
        \\to the world!
    );
    tester.executeCommand(.{ .insert_text = .{ .text = "!" } });
    try tester.expectContent(
        \\hello!|
        \\to the world!
    );
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .byte, .mode = .move } });
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
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .byte, .mode = .select } });
    try tester.expectContent("hel[lo|");

    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "hela\n\ninput\n\n\nlo!" } });
    try tester.expectContent("hela\n\ninput\n\n\nlo!|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move } });
    try tester.expectContent("hela\n\ninput\n\n|\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move } });
    try tester.expectContent("hela\n\ninput\n|\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move } });
    try tester.expectContent("hela\n\ninp|ut\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .byte } });
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .mode = .move, .stop = .byte } });
    try tester.expectContent("hela\n\ninput|\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move } });
    try tester.expectContent("hela\n|\ninput\n\n\nlo!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move } });
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

    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .move } });
    try tester.expectContent("|here are a few words to traverse!");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .metric = .byte, .mode = .move } });
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

    //
    // Grapheme cluster movement
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n!\n." } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n!\n.|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n!\n|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n!|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!\r\n|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧/|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!👨‍👩‍👧‍👧|");
    for (0..if (seg_dep.segmentation_issue_139) 4 else 1) |_| tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष!|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनीष|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …मनी|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …म|"); // TODO: not sure if this is expected behaviour. firefox deletes these one codepoint at a time
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! …|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}! |");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}!|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("He\u{301}|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("H|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("|");

    //
    // Grapheme cluster click
    //
    tester.executeCommand(.{ .insert_text = .{ .text = "e\u{301}" } });
    try tester.expectContent("e\u{301}|");
    tester.editor.onClick(tester.pos(1), 1, false);
    try tester.expectContent("|e\u{301}");
    tester.editor.onDrag(tester.pos(2));
    try tester.expectContent("|e\u{301}");
    tester.editor.onDrag(tester.pos(3));
    try tester.expectContent("[e\u{301}|");
    tester.editor.onDrag(tester.pos(2));
    try tester.expectContent("|e\u{301}");
    tester.editor.onDrag(tester.pos(1));
    try tester.expectContent("|e\u{301}");
    tester.editor.onDrag(tester.pos(0));
    try tester.expectContent("|e\u{301}");

    //
    // Grapheme cluster movement
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "line 1\nline 2\nline 3\nline 4" } });
    try tester.expectContent("line 1\nline 2\nline 3\nline 4|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .duplicate } });
    try tester.expectContent("line 1\nline 2\nline 3|\nline 4|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .duplicate } });
    try tester.expectContent("line 1\nline 2|\nline 3|\nline 4|");
    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .up, .metric = .byte, .mode = .duplicate } });
    try tester.expectContent("line 1|\nline 2|\nline 3|\nline 4|");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    try tester.expectContent("line |\nline |\nline |\nline |");
    tester.executeCommand(.{ .insert_text = .{ .text = "5" } });
    try tester.expectContent("line 5|\nline 5|\nline 5|\nline 5|");
}

fn usi(a: u64) usize {
    return @intCast(a);
}

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
