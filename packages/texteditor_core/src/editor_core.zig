//! text editing core that is mostly agnostic to the visual editor

const std = @import("std");
const core = @import("mach").core;
const imgui = @import("zig-imgui");
const util = @import("../../../util.zig");
const build_options = @import("build-options");
const tree_sitter_hl = @import("languages/tree_sitter.zig");
const tree_sitter = @import("tree-sitter");
const lsp = @import("./languages/lsp.zig");
const code_globals = @import("code_globals.zig");
const language_interface = @import("./languages/language_interface.zig");

const blocks = @import("../../blocks.zig");
const block_text_v1 = blocks.block_text_v1;

const BlockTextCallback = blocks.BlockTextCallback;

pub const CursorLeftRightStop = enum {
    byte,
    codepoint,
    grapheme,
    word,
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
};

pub const InsertOp = block_text_v1.operation;

const ByteOffsetConfig = struct {
    prefer: enum { left, right },
};
pub fn ByteOffsetConfigurable(comptime config: ByteOffsetConfig) type {
    return struct {
        const Self = @This();
        value: usize,

        pub fn updateForInsert(offset: *Self, op: InsertOp) void {
            if (offset.value > op.pos or (config.prefer == .right and offset.value == op.pos)) {
                if (offset.value < op.pos + op.prev_slice.len) {
                    offset.value = op.pos;
                } else {
                    offset.value -= op.prev_slice.len;
                }
                offset.value += op.next_slice.len;
            }
        }
    };
}
pub const ByteOffset = ByteOffsetConfigurable(.{
    .prefer = .right,
});
pub const ByteOffsetPreferLeft = ByteOffsetConfigurable(.{
    .prefer = .left,
});

pub const Selection = struct {
    anchor: ByteOffset,
    focus: ByteOffset,

    pub fn updateForInsert(self: *Selection, op: InsertOp) void {
        self.anchor.updateForInsert(op);
        self.focus.updateForInsert(op);
    }

    pub fn left(self: Selection) usize {
        return @min(self.anchor.value, self.focus.value);
    }
    pub fn right(self: Selection) usize {
        return @max(self.anchor.value, self.focus.value);
    }
};
pub const CursorPosition = struct {
    pos: Selection,

    /// for pressing the up/down arrow going from [aaaa|a] ↓ to [a|] to [aaaa|a]. resets on move.
    vertical_move_start: ?ByteOffset = null,
    /// when selecting up with tree-sitter to allow selecting back down. resets on move.
    node_select_start: ?Selection = null,

    pub fn updateForInsert(self: *CursorPosition, insert_op: InsertOp) void {
        self.pos.updateForInsert(insert_op);

        if (self.vertical_move_start) |*v| v.updateForInsert(insert_op);
        if (self.node_select_start) |*v| v.updateForInsert(insert_op);
    }
    pub fn onMove(self: *CursorPosition) void {
        self.vertical_move_start = null;
        self.node_select_start = null;
    }

    pub fn left(self: CursorPosition) usize {
        return self.pos.left();
    }
    pub fn right(self: CursorPosition) usize {
        return self.pos.right();
    }
};
pub const WordBoundaryType = enum {
    whitespace,
    identifier_like,
    symbols_and_unicode,
};
pub fn wordBoundaryCharactarize(char: u8) WordBoundaryType {
    return switch (char) {
        ' ', '\t', '\n', '\r' => .whitespace,
        'A'...'Z', 'a'...'z', '0'...'9', '_', '$' => .identifier_like,
        else => .symbols_and_unicode,
    };
}

pub const DragInfo = struct {
    start_pos: ?ByteOffset = null,
    selection_mode: DragSelectionMode = .ignore_drag,
};
pub const DragSelectionMode = enum {
    none,
    word,
    line,

    ignore_drag,
};
pub const LineCol = struct {
    line: usize, // 0-indexed, not 1-indexed!
    col: usize, // 0-indexed, not 1-indexed!
};

pub const EditorCore = struct {
    alloc: std.mem.Allocator,
    block_ref: blocks.BlockRef(blocks.block_text_v1),

    cursor_position: CursorPosition,
    drag_info: DragInfo = .{},

    // TODO: this should be per block id
    hlctx: ?language_interface.Hlctx,
    // TODO: there should only be one of these per active language
    lsp: ?*lsp.LspProcessManager,

    undo_list: std.ArrayList(blocks.OperationToken),
    redo_list: std.ArrayList(blocks.OperationToken),

    fn onMoveCursor(self: *EditorCore) void {
        self.cursor_position.onMove();
    }

    // ! ref must be loaded
    pub fn initFromBlock(self: *EditorCore, block_ref: blocks.BlockRef(blocks.block_text_v1), alloc: std.mem.Allocator) void {
        // block.add
        self.* = .{
            .alloc = alloc,
            .block_ref = block_ref,
            .cursor_position = .{
                .pos = .{
                    .focus = .{
                        .value = 0,
                    },
                    .anchor = .{
                        .value = 0,
                    },
                },
            },
            .hlctx = null,
            .lsp = null,

            .undo_list = std.ArrayList(blocks.OperationToken).init(alloc),
            .redo_list = std.ArrayList(blocks.OperationToken).init(alloc),
        };
        self.lsp = code_globals.instance().refLsp(.zig);
        // TODO: syn_hl_ctx = language.refSynHl(block_ref.id())
        self.hlctx = code_globals.instance().refHlctx(block_ref.id());
        block_ref.addUpdateListener(self, beforeUpdateCallback);
    }
    pub fn deinit(self: *EditorCore) void {
        if (self.hlctx != null) code_globals.instance().unrefHlctx(self.block_ref.id());
        if (self.lsp != null) code_globals.instance().unrefLsp(.zig);
        self.block_ref.removeUpdateListener(self, beforeUpdateCallback);
        self.block_ref.unref();
        self.undo_list.deinit();
        self.redo_list.deinit();
    }

    pub fn trackPosition(self: *EditorCore, position: *ByteOffset) void {
        self.block_ref.addUpdateListener(position, ByteOffset.updateForInsert);
    }
    pub fn untrackPosition(self: *EditorCore, position: *ByteOffset) void {
        self.block_ref.removeUpdateListener(position, ByteOffset.updateForInsert);
    }

    fn measureXPosition(self: *EditorCore, pos: usize) f64 {
        const line_start = self.thisLineStart(pos);
        return @floatFromInt(pos - line_start);
    }

    fn beforeUpdateCallback(self: *EditorCore, op: block_text_v1.operation) void {
        if (self.drag_info.start_pos) |*sp| sp.updateForInsert(op);
        self.cursor_position.updateForInsert(op);
    }
    pub fn applyInsert(self: *EditorCore, op: block_text_v1.operation) void {
        const token = self.block_ref.applyOperation(op);
        self.undo_list.append(token) catch @panic("oom");
        // ok this is the problem
        // we apply an operation to the block ref
        // but the operations we actually want to apply are Document operations
        // that way we can track and put the relevant items in our undo/redo lists
    }

    pub fn measureIndent(self: *EditorCore, line_start: usize) usize {
        const block = self.block_ref.getDataAssumeLoadedConst();

        var indent_len: usize = 0;
        var retry = false;
        // oops forgot the eof case
        // 2 bad so sad
        for (line_start..block.len()) |i| {
            const buffer_val = block.at(i);
            if (buffer_val == ' ' or buffer_val == '\t') {
                indent_len += 1;
            } else if (buffer_val == '\n') {
                retry = true;
                break;
            } else break;
        }
        if (retry) {
            const prev_line_start = self.prevLineStart(line_start);
            if (line_start == prev_line_start) return 0;
            return @call(std.builtin.CallModifier.always_tail, measureIndent, .{ self, prev_line_start });
        }
        return indent_len;
    }
    // left to word boundary (first, move until not whitespace, then move until class changes)
    pub fn leftToWordBoundary(self: *EditorCore, start_pos: usize) usize {
        const block = self.block_ref.getDataAssumeLoadedConst();

        var pos: usize = start_pos;
        // 1. eat whitespace
        if (pos == 0) return pos;
        pos -= 1;
        while (wordBoundaryCharactarize(block.at(pos)) == .whitespace) {
            if (pos == 0) return pos;
            pos -= 1;
        }
        // 2. wordBoundaryCharactarize(current char), move until a different charactarization is reached
        const current_charactarization = wordBoundaryCharactarize(block.at(pos));
        while (wordBoundaryCharactarize(block.at(pos)) == current_charactarization) {
            if (pos == 0) return pos;
            pos -= 1;
        }
        return pos + 1;
    }
    // left to word boundary (first, move until not whitespace, then move until class changes)
    pub fn rightToWordBoundary(self: *EditorCore, start_pos: usize) usize {
        const block = self.block_ref.getDataAssumeLoadedConst();

        var pos: usize = start_pos;
        // 1. eat whitespace
        if (pos == block.len()) return pos;
        while (wordBoundaryCharactarize(block.at(pos)) == .whitespace) {
            pos += 1;
            if (pos == block.len()) return pos;
        }
        // 2. wordBoundaryCharactarize(current char), move until a different charactarization is reached
        const current_charactarization = wordBoundaryCharactarize(block.at(pos));
        while (wordBoundaryCharactarize(block.at(pos)) == current_charactarization) {
            pos += 1;
            if (pos == block.len()) return pos;
        }
        return pos;
    }
    pub fn prevLineStart(self: *EditorCore, line_start: usize) usize {
        if (line_start > 0) return self.thisLineStart(line_start - 1);
        return 0;
    }
    pub fn thisLineStart(self: *EditorCore, line_center: usize) usize {
        const block = self.block_ref.getDataAssumeLoadedConst();
        return util.text.lineStart(block.buffer.items, line_center);
    }
    pub fn thisLineEnd(self: *EditorCore, line_center: usize) usize {
        const block = self.block_ref.getDataAssumeLoadedConst();

        var line_start = line_center;
        while (line_start < block.len() and block.at(line_start) != '\n') {
            line_start += 1;
        }
        return line_start;
    }
    pub fn nextLineStart(self: *EditorCore, line_center: usize) usize {
        const block = self.block_ref.getDataAssumeLoadedConst();

        var line_start = self.thisLineEnd(line_center);
        if (line_start < block.len()) line_start += 1;
        return line_start;
    }

    pub fn getLineCol(self: *EditorCore, byte_offset: usize) LineCol {
        const block = self.block_ref.getDataAssumeLoadedConst();

        var res: LineCol = .{ .line = 0, .col = 0 };
        for (block.buffer.items[0..byte_offset]) |char| {
            if (char == '\n') {
                res.col = 0;
                res.line += 1;
            } else {
                res.col += 1;
            }
        }

        return res;
    }

    pub fn select(self: *EditorCore, anchor: usize, focus: usize) void {
        self.cursor_position.pos.anchor = .{ .value = anchor };
        self.cursor_position.pos.focus = .{ .value = focus };
        self.onMoveCursor();
    }
    pub fn moveCursor(self: *EditorCore, pos: usize) void {
        self.select(pos, pos);
    }
    pub fn moveCursorFocus(self: *EditorCore, pos: usize) void {
        self.cursor_position.pos.focus = .{ .value = pos };
        self.onMoveCursor();
    }

    pub fn executeCommand(self: *EditorCore, command: EditorCommand) void {
        const block = self.block_ref.getDataAssumeLoadedConst();

        switch (command) {
            .move_cursor_up_down => |ud_op| {
                // TODO:
                // up down result depends on the EditorView
                // we'll have to ask the EditorView to measure it out for us and find where the cursor should go
                // for now, we're keeping byte offset. but that's obviously wrong.

                var pos = self.cursor_position.pos.focus.value;
                if (ud_op.mode == .move and self.cursor_position.pos.anchor.value != self.cursor_position.pos.focus.value) {
                    // when text is selected, up moves up relative to selection left and down moves down relative to selection right
                    pos = switch (ud_op.direction) {
                        .up => self.cursor_position.left(),
                        .down => self.cursor_position.right(),
                    };
                }
                const line_start_pos = self.thisLineStart(pos);
                const prev_x_idx: usize = if (self.cursor_position.vertical_move_start) |v| v.value else 0;
                const prev_x_offset = std.math.lossyCast(usize, self.measureXPosition(prev_x_idx));
                const initial_pos = pos;
                const curr_x_offset = std.math.lossyCast(usize, self.measureXPosition(initial_pos));
                const cursor_x_offset = @max(prev_x_offset, curr_x_offset);
                switch (ud_op.direction) {
                    .up => {
                        if (line_start_pos != 0) {
                            const prev_line_start_pos = self.thisLineStart(line_start_pos - 1);
                            pos = @min(prev_line_start_pos + cursor_x_offset, line_start_pos - 1);
                        }
                    },
                    .down => {
                        const next_line_start = self.nextLineStart(line_start_pos);
                        const line_after_line_start = self.nextLineStart(next_line_start);
                        if (line_after_line_start > 0) {
                            pos = @min(next_line_start + cursor_x_offset, line_after_line_start - 1);
                        }
                    },
                }
                switch (ud_op.mode) {
                    .move => {
                        self.moveCursor(pos);
                    },
                    .select => {
                        self.moveCursorFocus(pos);
                    },
                }

                if (cursor_x_offset > prev_x_offset) {
                    self.cursor_position.vertical_move_start = .{ .value = initial_pos };
                } else {
                    self.cursor_position.vertical_move_start = .{ .value = prev_x_idx };
                }
            },
            .move_cursor_left_right => |lr_op| {
                // right: [sep somew|ord sep] => [sep someword| sep]
                // left: [sep somew|ord sep] => [sep |someword sep]
                var pos: isize = @intCast(self.cursor_position.pos.focus.value);

                if (lr_op.mode == .move and self.cursor_position.pos.anchor.value != self.cursor_position.pos.focus.value) {
                    const pos_left = self.cursor_position.left();
                    const pos_right = self.cursor_position.right();
                    const res_pos = switch (lr_op.direction) {
                        .left => pos_left,
                        .right => pos_right,
                    };
                    self.moveCursor(res_pos);
                    return; // done
                }
                // move by byte:
                // - move one byte
                // move by codepoint:
                // - utf-8 algorithm
                // move by grapheme:
                // - unicode algorithm, use a library
                // move by word:
                // - if at whitespace:
                //   - move until not at whitespace. continue:
                // - if at alphanumeric
                //   - move until not at alphanumeric. stop.
                // - if at symbol
                //   - move until not at symbol. stop.
                // - else
                //   - move until not else. stop.
                switch (lr_op.stop) {
                    .byte => {
                        pos += lr_op.direction.value();
                    },
                    .codepoint => {},
                    .grapheme => {},
                    .word => {
                        pos = @intCast(switch (lr_op.direction) {
                            .left => self.leftToWordBoundary(@intCast(pos)),
                            .right => self.rightToWordBoundary(@intCast(pos)),
                        });
                    },
                    .line => {
                        pos = @intCast(switch (lr_op.direction) {
                            .left => self.thisLineStart(@intCast(pos)),
                            .right => blk: {
                                const res_plus_one = self.nextLineStart(@intCast(pos));
                                if (res_plus_one > 0) break :blk res_plus_one - 1;
                                break :blk res_plus_one;
                            },
                        });
                    },
                }
                pos = @min(@max(pos, 0), block.len());
                switch (lr_op.mode) {
                    .move => {
                        self.moveCursor(@intCast(pos));
                    },
                    .select => {
                        self.moveCursorFocus(@intCast(pos));
                    },
                    .delete => {
                        if (self.cursor_position.pos.anchor.value != self.cursor_position.pos.focus.value) {
                            pos = @intCast(self.cursor_position.pos.anchor.value);
                        }
                        const pos_usz: usize = @intCast(pos);
                        const pos_min = @min(pos_usz, self.cursor_position.pos.focus.value);
                        const pos_max = @max(pos_usz, self.cursor_position.pos.focus.value);
                        const op = InsertOp{
                            .pos = pos_min,
                            .prev_slice = block.prevSliceTemp(pos_min, pos_max),
                            .next_slice = "",
                        };
                        self.applyInsert(op);
                    },
                }
            },
            .insert_text => |text_op| {
                const pos_min = self.cursor_position.left();
                const pos_max = self.cursor_position.right();
                const op = InsertOp{
                    .pos = pos_min,
                    .prev_slice = block.prevSliceTemp(pos_min, pos_max),
                    .next_slice = text_op.text,
                };
                self.applyInsert(op);
            },
            .newline => {
                const pos_min = self.cursor_position.left();
                const pos_max = self.cursor_position.right();

                const indent_count = self.measureIndent(self.thisLineStart(pos_min));
                const temp_insert_slice = self.alloc.alloc(u8, 1 + indent_count) catch @panic("oom");
                defer self.alloc.free(temp_insert_slice);
                temp_insert_slice[0] = '\n';
                for (temp_insert_slice[1..]) |*char| char.* = ' ';

                const op = InsertOp{
                    .pos = pos_min,
                    .prev_slice = block.prevSliceTemp(pos_min, pos_max),
                    .next_slice = temp_insert_slice,
                };
                self.applyInsert(op);
            },
            .indent_selection => |indent_op| {
                const pos_min = self.cursor_position.left();
                const first_pos_max = self.cursor_position.right();
                const first_line_start = self.thisLineStart(pos_min);

                // now, we loop
                var line_start = ByteOffset{ .value = first_line_start };
                var pos_max = ByteOffset{ .value = first_pos_max };

                self.trackPosition(&line_start);
                defer self.untrackPosition(&line_start);

                self.trackPosition(&pos_max);
                defer self.untrackPosition(&pos_max);

                while (line_start.value <= pos_max.value) {
                    switch (indent_op.direction) {
                        .left => {
                            var delete_count: usize = 0;
                            // not correct handling of \t
                            for (line_start.value..@min(line_start.value + DefaultConfig.indent_len, block.len())) |i| {
                                const buffer_val = block.at(i);
                                if (buffer_val == ' ' or buffer_val == '\t') {
                                    delete_count += 1;
                                } else break;
                            }
                            self.applyInsert(.{
                                .pos = line_start.value,
                                .prev_slice = block.prevSliceTemp(line_start.value, line_start.value + delete_count),
                                .next_slice = "",
                            });
                        },
                        .right => {
                            const insert_count = DefaultConfig.indent_len;
                            const temp_insert_slice = self.alloc.alloc(u8, insert_count) catch @panic("oom");
                            defer self.alloc.free(temp_insert_slice);
                            for (temp_insert_slice) |*char| char.* = ' ';
                            self.applyInsert(.{
                                .pos = line_start.value,
                                .prev_slice = "",
                                .next_slice = temp_insert_slice,
                            });
                        },
                    }

                    // go to next line start
                    line_start.value = self.nextLineStart(line_start.value);
                }
            },
            .select_all => {
                self.select(0, block.len());
            },
            .ts_select_node => |tsln| {
                // we have to reimplement this and make it better this time
                _ = tsln;
                @panic("TODO reimplement this with hlctx");
            },
            .undo => {
                const undo_op = self.undo_list.popOrNull() orelse return;
                _ = undo_op;
                @panic("TODO undo");
            },
            .redo => {
                const redo_op = self.redo_list.popOrNull() orelse return;
                _ = redo_op;
                @panic("TODO redo");
            },
            else => {
                std.log.warn("TODO operation: {any}", .{command});
            },
        }
    }

    pub fn onClick(self: *EditorCore, index: usize, click_count: i32, shift_held: bool) void {
        const sel_mode: DragSelectionMode = switch (click_count) {
            1 => .none,
            2 => .word,
            3 => .line,
            else => .ignore_drag,
        };
        if (shift_held) {
            if (sel_mode != .none) self.drag_info.selection_mode = sel_mode;
        } else {
            self.drag_info = .{
                .selection_mode = sel_mode,
                .start_pos = ByteOffset{ .value = index },
            };
        }
        if (click_count == 4) {
            self.executeCommand(.select_all);
            return;
        }
        self.onDrag(index);
    }
    pub fn onDrag(self: *EditorCore, index: usize) void {
        // maybe it would be good to keep track of the starting index?
        // rather than having to make sure stuff ends up right
        switch (self.drag_info.selection_mode) {
            .none => {
                const anchor_pos = self.drag_info.start_pos.?.value;
                self.select(anchor_pos, index);
            },
            .word => {
                // this isn't quite right
                // from orig_pos:
                // if whitespace both sides:
                // - select whitespace (not to word boundary, just to edge of whitespace)
                // if whitespace left:
                // - right to word boundary
                // if whitespace right:
                // - left to word boundary
                // else:
                // - right to word boundary then left from there to word start
                //
                // we can implement this as fn selectWord(center_pos)
                const orig_pos = self.drag_info.start_pos.?.value;
                const orig_word_end = self.rightToWordBoundary(orig_pos);
                const orig_word_start = self.leftToWordBoundary(orig_word_end);

                const word_end = self.rightToWordBoundary(index);
                const word_start = self.leftToWordBoundary(word_end);

                if (word_start < orig_word_start) {
                    self.select(orig_word_end, word_start);
                } else {
                    self.select(orig_word_start, word_end);
                }
            },
            .line => {
                const orig_pos = self.drag_info.start_pos.?.value;
                const orig_line_start = self.thisLineStart(orig_pos);
                const orig_next_line_start = self.nextLineStart(orig_pos);

                const line_start = self.thisLineStart(index);
                const next_line_start = self.nextLineStart(index);
                if (line_start < orig_line_start) {
                    self.select(orig_next_line_start, line_start);
                } else {
                    self.select(orig_line_start, next_line_start);
                }
            },
            .ignore_drag => {},
        }
    }
};

pub const DefaultConfig = struct {
    pub const indent_len = 4;
};
