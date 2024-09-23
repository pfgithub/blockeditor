//! text editing core that is mostly agnostic to the visual editor

const std = @import("std");
const blocks_mod = @import("blocks");
const seg_dep = @import("grapheme_cursor");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;
const tree_sitter = @import("tree_sitter.zig");
const tracy = @import("anywhere").tracy;

const Core = @This();

gpa: std.mem.Allocator,
document: db_mod.TypedComponentRef(bi.text_component.TextDocument),
syn_hl_ctx: tree_sitter.Context,
clipboard_cache: ?struct {
    /// owned by self.gpa
    contents: []const []const u8,
    /// true only if every line copied had selection .len == 0
    paste_in_new_line: bool,
    /// Wyhash of copied string
    copied_str_hash: u64,
},
undo: TextStack,
redo: TextStack,

cursor_positions: std.ArrayList(CursorPosition),

config: EditorConfig = .{
    .indent_with = .{ .spaces = 4 },
},

/// refs document
pub fn initFromDoc(self: *Core, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
    self.* = .{
        .gpa = gpa,
        .document = document,
        .syn_hl_ctx = undefined,
        .clipboard_cache = null,
        .undo = .init(gpa),
        .redo = .init(gpa),

        .cursor_positions = .init(gpa),
    };
    document.ref();
    document.addUpdateListener(util.Callback(bi.text_component.TextDocument.SimpleOperation, void).from(self, cb_onEdit)); // to keep the language server up to date

    self.syn_hl_ctx.init(self.document, gpa) catch {
        @panic("TODO handle syn_hl_ctx init failure");
    };
}
pub fn deinit(self: *Core) void {
    self.undo.deinit();
    self.redo.deinit();
    if (self.clipboard_cache) |*v| {
        for (v.contents) |c| self.gpa.free(c);
        self.gpa.free(v.contents);
    }
    self.syn_hl_ctx.deinit();
    self.cursor_positions.deinit();
    self.document.removeUpdateListener(util.Callback(bi.text_component.TextDocument.SimpleOperation, void).from(self, cb_onEdit));
    self.document.unref();
}

fn cb_onEdit(self: *Core, edit: bi.text_component.TextDocument.SimpleOperation) void {
    // TODO: keep tree-sitter updated
    _ = self;
    _ = edit;
}

pub fn getLineStart(self: *Core, pos: Position) Position {
    const block = self.document.value;
    var lyncol = block.lynColFromPosition(pos);
    lyncol.col = 0;
    return block.positionFromLynCol(lyncol).?;
}
pub fn getPrevLineStart(self: *Core, pos: Position) Position {
    const block = self.document.value;
    var lyncol = block.lynColFromPosition(pos);
    lyncol.col = 0;
    if (lyncol.lyn > 0) lyncol.lyn -= 1;
    return block.positionFromLynCol(lyncol).?;
}
pub fn getThisLineEnd(self: *Core, prev_line_start: Position) Position {
    const block = self.document.value;
    const next_line_start = self.getNextLineStart(prev_line_start);
    const next_line_start_byte = block.docbyteFromPosition(next_line_start);
    const prev_line_start_byte = block.docbyteFromPosition(prev_line_start);

    if (prev_line_start_byte == next_line_start_byte) return prev_line_start;
    if (next_line_start_byte == block.length()) return block.positionFromDocbyte(next_line_start_byte);
    std.debug.assert(next_line_start_byte > prev_line_start_byte);
    return block.positionFromDocbyte(next_line_start_byte - 1);
}
pub fn getNextLineStartMaybeInsertNewline(self: *Core, pos: Position) Position {
    if (self.document.value.docbyteFromPosition(pos) == self.document.value.length()) {
        self.replaceRange(.{ .position = .end, .delete_len = 0, .insert_text = "\n" });
        return .end;
    }
    return self.getNextLineStart(pos);
}
pub fn getNextLineStart(self: *Core, prev_line: Position) Position {
    const block = self.document.value;
    var lyncol = block.lynColFromPosition(prev_line);
    lyncol.col = 0;
    lyncol.lyn += 1;
    return block.positionFromLynCol(lyncol) orelse {
        return .end;
    };
}
fn measureIndent(self: *Core, line_start_pos: Position) struct { indents: u64, chars: u64 } {
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

fn toWordBoundary(self: *Core, pos: Position, direction: LRDirection, stop: CursorLeftRightStop, mode: enum { left, right, select }, nomove: enum { must_move, may_move }) Position {
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

pub fn selectionToPosLen(self: *Core, selection: Selection) PosLen {
    const block = self.document.value;

    const bufbyte_1 = block.docbyteFromPosition(selection.anchor);
    const bufbyte_2 = block.docbyteFromPosition(selection.focus);

    const min = @min(bufbyte_1, bufbyte_2);
    const max = @max(bufbyte_1, bufbyte_2);

    return .{
        .pos = block.positionFromDocbyte(min),
        .left_docbyte = min,
        .right = block.positionFromDocbyte(max),
        .right_docbyte = max,
        .len = max - min,
        .is_right = min == bufbyte_1,
    };
}
pub fn normalizePosition(self: *Core, pos: Position) Position {
    const block = self.document.value;
    return block.positionFromDocbyte(block.docbyteFromPosition(pos));
}
/// makes sure cursors are:
/// - on live spans, not deleted ones `hello ` `5|` `world` -> `hello `5` `|world`
/// - not overlapping `he[llo[ wor|ld|` -> `he[llo world|`
/// - in left-to-right order ``
pub fn normalizeCursors(self: *Core) void {
    const block = self.document.value;

    var positions = self.getCursorPositions();
    defer positions.deinit();

    var uncommitted_start: ?u64 = null;

    const len_start = self.cursor_positions.items.len;
    self.cursor_positions.clearRetainingCapacity();
    for (positions.positions.items) |pos| {
        const prev_selected = positions.count > 0;
        if (positions.idx >= positions.positions.items.len) break;
        if (positions.positions.items[positions.idx].docbyte > pos.docbyte) continue;
        const sel_info = positions.advanceAndRead(pos.docbyte);
        const next_selected = sel_info.selected;

        var res_cursor = sel_info.left_cursor_extra.?;
        if (prev_selected and next_selected) {
            // don't put a cursor
            continue;
        } else if (!prev_selected and next_selected) {
            uncommitted_start = pos.docbyte;
        } else if (prev_selected and !next_selected) {
            // commit
            std.debug.assert(uncommitted_start != null);
            if (sel_info.left_cursor == .focus) {
                res_cursor.pos = .range(
                    block.positionFromDocbyte(uncommitted_start.?),
                    block.positionFromDocbyte(pos.docbyte),
                );
            } else {
                res_cursor.pos = .range(
                    block.positionFromDocbyte(pos.docbyte),
                    block.positionFromDocbyte(uncommitted_start.?),
                );
            }
            self.cursor_positions.appendAssumeCapacity(res_cursor);
            uncommitted_start = null;
        } else if (!prev_selected and !next_selected) {
            // commit
            std.debug.assert(uncommitted_start == null);
            res_cursor.pos = .at(
                block.positionFromDocbyte(pos.docbyte),
            );
            self.cursor_positions.appendAssumeCapacity(res_cursor);
        } else unreachable;
    }
    std.debug.assert(uncommitted_start == null);
    const len_end = self.cursor_positions.items.len;
    std.debug.assert(len_end <= len_start);
}
pub fn select(self: *Core, selection: Selection) void {
    self.cursor_positions.clearRetainingCapacity();
    self.cursor_positions.append(.{
        .pos = selection,
    }) catch @panic("oom");
}
fn measureMetric(self: *Core, pos: Position, metric: CursorHorizontalPositionMetric) u64 {
    const block = self.document.value;
    const this_line_start = self.getLineStart(pos);
    return switch (metric) {
        .byte => block.docbyteFromPosition(pos) - block.docbyteFromPosition(this_line_start),
        else => @panic("TODO support metric"),
    };
}
fn applyMetric(self: *Core, new_line_start: Position, metric: CursorHorizontalPositionMetric, metric_value: u64) Position {
    const block = self.document.value;

    const new_line_start_pos = block.docbyteFromPosition(new_line_start);
    const new_line_end_pos = block.docbyteFromPosition(self.getThisLineEnd(new_line_start));
    const new_line_len = new_line_end_pos - new_line_start_pos;
    return switch (metric) {
        .byte => block.positionFromDocbyte(new_line_start_pos + @min(new_line_len, metric_value)),
        else => @panic("TODO support metric"),
    };
}
pub fn executeCommand(self: *Core, command: EditorCommand) void {
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
        .paste => |paste_op| {
            self.paste(paste_op.text);
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
                    continue;
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

                const line_indent_count = self.measureIndent(line_start);
                const dist = pos_len.left_docbyte - block.docbyteFromPosition(line_start);
                const order = line_indent_count.chars <= dist;

                if (order) temp_insert_slice.append('\n') catch @panic("oom");
                temp_insert_slice.appendNTimes(self.config.indent_with.char(), usi(self.config.indent_with.count() * line_indent_count.indents)) catch @panic("oom");
                if (!order) temp_insert_slice.append('\n') catch @panic("oom");

                self.replaceRange(.{
                    .position = pos_len.pos,
                    .delete_len = pos_len.len,
                    .insert_text = temp_insert_slice.items,
                });
            }
        },
        .insert_line => |cmd| {
            switch (cmd.direction) {
                .up => {
                    for (self.cursor_positions.items) |*cursor_position| cursor_position.* = .at(self.getLineStart(cursor_position.pos.focus));
                    self.executeCommand(.newline);
                    self.executeCommand(.{ .move_cursor_left_right = .{ .mode = .move, .stop = .unicode_grapheme_cluster, .direction = .left } });
                },
                .down => {
                    for (self.cursor_positions.items) |*cursor_position| cursor_position.* = .at(self.getThisLineEnd(cursor_position.pos.focus));
                    self.executeCommand(.newline);
                },
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
        .duplicate_line => |dupe_cmd| {
            for (self.cursor_positions.items) |*cursor_position| {
                const pos_len = self.selectionToPosLen(cursor_position.pos);

                const start_line = self.getLineStart(pos_len.pos);
                const end_line = self.getThisLineEnd(pos_len.right);

                const start_byte = block.docbyteFromPosition(start_line);
                const end_byte = block.docbyteFromPosition(end_line);

                var dupe_al: std.ArrayList(u8) = .init(self.gpa);
                defer dupe_al.deinit();
                block.readSlice(start_line, dupe_al.addManyAsSlice(end_byte - start_byte) catch @panic("oom"));
                switch (dupe_cmd.direction) {
                    .down => {
                        if (dupe_al.items.len == 0 or dupe_al.items[dupe_al.items.len - 1] != '\n') {
                            dupe_al.append('\n') catch @panic("oom");
                        }
                    },
                    .up => {
                        if (dupe_al.items.len != 0 and dupe_al.items[dupe_al.items.len - 1] == '\n') {
                            _ = dupe_al.pop();
                        }
                        dupe_al.insertSlice(0, &.{'\n'}) catch @panic("oom");
                    },
                }

                self.replaceRange(.{
                    .position = switch (dupe_cmd.direction) {
                        .down => start_line,
                        .up => end_line,
                    },
                    .delete_len = 0,
                    .insert_text = dupe_al.items,
                });

                // handle case where cursor is at the end of the line when duplicating up
                if (dupe_cmd.direction == .up) {
                    const target = block.docbyteFromPosition(end_line);
                    for (&[_]*Position{ &cursor_position.pos.anchor, &cursor_position.pos.focus }) |pos| {
                        const pos_int = block.docbyteFromPosition(pos.*);
                        if (pos_int == target) {
                            pos.* = block.positionFromDocbyte(pos_int - dupe_al.items.len);
                        }
                    }
                }
            }
        },
        .ts_select_node => |ts_sel| {
            for (self.cursor_positions.items) |*cursor_position| {
                var sel_start = cursor_position.node_select_start orelse cursor_position.pos;
                _ = &sel_start; // work around zig bug. sel_start should be 'const' but it mutates if it is
                const start_pos_len = self.selectionToPosLen(sel_start);
                const sel_curr = cursor_position.pos;
                const curr_pos_len = self.selectionToPosLen(sel_curr);

                const tree = self.syn_hl_ctx.getTree();
                const min_node = tree.rootNode().descendantForByteRange(@intCast(start_pos_len.left_docbyte), @intCast(start_pos_len.right_docbyte));

                var curr_node_v = min_node;
                var prev_node: ?tree_sitter.ts.Node = null;

                while (curr_node_v) |curr_node| {
                    const node_start = curr_node.startByte();
                    const node_end = curr_node.endByte();

                    //  za[bc]de
                    //  za[bc]de
                    const db = node_start <= curr_pos_len.left_docbyte and node_end >= curr_pos_len.right_docbyte;
                    if (ts_sel.direction == .child and db) {
                        // on down: select previous node
                        break;
                    }
                    if (ts_sel.direction == .parent and db and (node_start < curr_pos_len.left_docbyte or node_end > curr_pos_len.right_docbyte)) {
                        // on up: select this node
                        break;
                    }

                    prev_node = curr_node;
                    curr_node_v = curr_node.slowParent();
                }

                const target_node = switch (ts_sel.direction) {
                    .parent => curr_node_v,
                    .child => prev_node,
                };

                if (target_node == null) switch (ts_sel.direction) {
                    .parent => {
                        // select all
                        cursor_position.* = .{
                            .pos = .range(block.positionFromDocbyte(0), .end),
                            .node_select_start = sel_start,
                        };
                        continue;
                    },
                    .child => {
                        // select min
                        cursor_position.* = .{
                            .pos = sel_start,
                            .node_select_start = sel_start,
                        };
                        continue;
                    },
                };

                cursor_position.* = .{
                    .pos = .range(block.positionFromDocbyte(target_node.?.startByte()), block.positionFromDocbyte(target_node.?.endByte())),
                    .node_select_start = sel_start,
                };
            }
        },
        .undo => {
            const undo_op = self.undo.take() orelse return;

            const rb = self.redo.begin();
            self.document.applyUndoOperation(undo_op, rb.al);
            rb.end() catch @panic("oom");
        },
        .redo => {
            const redo_op = self.redo.take() orelse return;

            const ub = self.undo.begin();
            self.document.applyUndoOperation(redo_op, ub.al);
            ub.end() catch @panic("oom");
        },
        .click => |click_op| {
            self.onClick(click_op.pos, click_op.mode, click_op.extend, click_op.select_ts_node);
        },
        .drag => |drag_op| {
            self.onDrag(drag_op.pos);
        },
    }
}
pub const CopyMode = enum { copy, cut };
/// returned string is utf-8 encoded. caller owns the returned string and must copy it to the clipboard
pub fn copyAllocUtf8(self: *Core, alloc: std.mem.Allocator, mode: CopyMode) []const u8 {
    var result_str = std.ArrayList(u8).init(alloc);
    defer result_str.deinit();

    self.copyArrayListUtf8(&result_str, mode);

    return result_str.toOwnedSlice() catch @panic("oom");
}
/// written string is utf-8 encoded and does not include any null bytes
pub fn copyArrayListUtf8(self: *Core, result_str: *std.ArrayList(u8), mode: CopyMode) void {
    self.normalizeCursors();
    defer self.normalizeCursors();

    const stored_buf = self.gpa.alloc([]const u8, self.cursor_positions.items.len) catch @panic("oom");
    var paste_in_new_line = true;
    var this_needs_newline = false;
    for (self.cursor_positions.items, stored_buf) |*cursor, *stored| {
        var pos_range = self.selectionToPosLen(cursor.pos);
        var next_needs_newline = true;
        defer this_needs_newline = next_needs_newline;
        if (pos_range.len == 0) {
            pos_range = self.selectionToPosLen(.range(self.getLineStart(pos_range.pos), self.getNextLineStartMaybeInsertNewline(pos_range.pos)));
            next_needs_newline = false;
        } else {
            paste_in_new_line = false;
        }
        const slice = self.gpa.alloc(u8, pos_range.len) catch @panic("oom");
        self.document.value.readSlice(pos_range.pos, slice);
        stored.* = slice;

        if (this_needs_newline) result_str.appendSlice("\n") catch @panic("oom");
        result_str.appendSlice(slice) catch @panic("oom");

        if (mode == .cut) {
            self.replaceRange(.{ .position = pos_range.pos, .delete_len = pos_range.len, .insert_text = "" });
        }
    }
    self.clipboard_cache = .{
        .contents = stored_buf,
        .copied_str_hash = std.hash.Wyhash.hash(0, result_str.items),
        .paste_in_new_line = paste_in_new_line,
    };

    seg_dep.replaceInvalidUtf8(result_str.items);
}
fn paste(self: *Core, clipboard_contents: []const u8) void {
    self.normalizeCursors();
    defer self.normalizeCursors();

    defer {
        if (self.clipboard_cache) |*v| {
            for (v.contents) |c| self.gpa.free(c);
            self.gpa.free(v.contents);
        }
        self.clipboard_cache = null;
    }

    var clip_contents: []const []const u8 = &.{clipboard_contents};
    var paste_in_new_line = false;
    if (self.clipboard_cache) |*c| if (c.copied_str_hash == std.hash.Wyhash.hash(0, clipboard_contents)) {
        clip_contents = c.contents;
        paste_in_new_line = c.paste_in_new_line;
    };

    if (clip_contents.len == self.cursor_positions.items.len) {
        for (clip_contents, self.cursor_positions.items) |text, *cursor_pos| {
            self.pasteInternal(cursor_pos, text, paste_in_new_line);
        }
    } else {
        for (clip_contents) |text| for (self.cursor_positions.items) |*cursor_pos| {
            self.pasteInternal(cursor_pos, text, paste_in_new_line);
        };
    }
}
fn pasteInternal(self: *Core, cursor_pos: *const CursorPosition, text: []const u8, paste_in_new_line: bool) void {
    var pos_range = self.selectionToPosLen(cursor_pos.pos);
    var add_newline = false;
    if (pos_range.len == 0 and paste_in_new_line) {
        pos_range = self.selectionToPosLen(.at(self.getLineStart(pos_range.pos)));
        add_newline = true;
    }

    self.replaceRange(.{
        .position = pos_range.pos,
        .delete_len = pos_range.len,
        .insert_text = text,
    });
}
fn getEnsureOneCursor(self: *Core, default_pos: Position) *CursorPosition {
    if (self.cursor_positions.items.len == 0) {
        self.select(.at(default_pos));
    } else if (self.cursor_positions.items.len > 1) {
        self.cursor_positions.items.len = 1;
    }
    return &self.cursor_positions.items[0];
}
// change to sel_mode: DragSelectionMode, shift_held: bool?
// make this an EditorCommand?
fn onClick(self: *Core, pos: Position, sel_mode: DragSelectionMode, shift_held: bool, ctrl_or_alt_held: bool) void {
    const cursor = self.getEnsureOneCursor(pos);

    if (shift_held) {
        if (cursor.drag_info == null) {
            cursor.drag_info = .{
                .start_pos = cursor.pos.focus,
                .sel_mode = sel_mode,
                .select_ts_node = ctrl_or_alt_held,
            };
        }
        if (sel_mode.select) cursor.drag_info.?.sel_mode = sel_mode;
    } else {
        cursor.drag_info = .{
            .start_pos = pos,
            .sel_mode = sel_mode,
            .select_ts_node = ctrl_or_alt_held,
        };
    }
    self.onDrag(pos);
}
fn onDrag(self: *Core, pos: Position) void {
    const block = self.document.value;

    // TODO: support tree_sitter selection when holding ctrl|alt:
    // - given (drag_start, drag_end):
    //   - find node for range (start, end)
    //   - select from node left to node right
    // should allow for easy selection within brackets: ctrl+drag a little bit and you're done
    const cursor = self.getEnsureOneCursor(pos);
    if (cursor.drag_info == null) return;

    const drag_info = cursor.drag_info.?;
    const stop = drag_info.sel_mode.stop;
    const anchor_pos = drag_info.start_pos;
    if (drag_info.select_ts_node) {
        const sel_start: Selection = .range(anchor_pos, pos);
        const pos_len = self.selectionToPosLen(sel_start);

        const tree = self.syn_hl_ctx.getTree();
        const min_node = tree.rootNode().descendantForByteRange(@intCast(pos_len.left_docbyte), @intCast(pos_len.right_docbyte));

        const target_start = if (min_node) |m| m.startByte() else 0;
        const target_end = if (min_node) |m| m.endByte() else block.length();

        cursor.* = .{
            .pos = switch (pos_len.is_right) {
                false => .range(block.positionFromDocbyte(target_end), block.positionFromDocbyte(target_start)),
                true => .range(block.positionFromDocbyte(target_start), block.positionFromDocbyte(target_end)),
            },
            .node_select_start = sel_start,
            .drag_info = drag_info,
        };
        return;
    }
    const anchor_l = self.toWordBoundary(anchor_pos, .left, stop, .select, .may_move);
    const focus_l = self.toWordBoundary(pos, .left, stop, .select, .may_move);
    if (drag_info.sel_mode.select) {
        const anchor_r = self.toWordBoundary(anchor_pos, .right, stop, .select, .must_move);
        const focus_r = self.toWordBoundary(pos, .right, stop, .select, .must_move);

        // now:
        // we select from @min(all) to @max(all) and put the cursor on (focus_l < anchor_l ? left : right)

        const anchor_l_docbyte = block.docbyteFromPosition(anchor_l);
        const anchor_r_docbyte = block.docbyteFromPosition(anchor_r);
        const focus_l_docbyte = block.docbyteFromPosition(focus_l);
        const focus_r_docbyte = block.docbyteFromPosition(focus_r);

        const min_docbyte = @min(@min(anchor_l_docbyte, anchor_r_docbyte), @min(focus_l_docbyte, focus_r_docbyte));
        const max_docbyte = @max(@max(anchor_l_docbyte, anchor_r_docbyte), @max(focus_l_docbyte, focus_r_docbyte));
        const min_pos = block.positionFromDocbyte(min_docbyte);
        const max_pos = block.positionFromDocbyte(max_docbyte);

        if (focus_l_docbyte < anchor_l_docbyte) {
            cursor.* = .{
                .pos = .range(max_pos, min_pos),
                .drag_info = drag_info,
            };
        } else {
            cursor.* = .{
                .pos = .range(min_pos, max_pos),
                .drag_info = drag_info,
            };
        }
    } else {
        cursor.* = .{
            .pos = .range(anchor_l, focus_l),
            .drag_info = drag_info,
        };
    }
}

pub fn replaceRange(self: *Core, operation: bi.text_component.TextDocument.SimpleOperation) void {
    self.redo.clear();
    const ub = self.undo.begin();
    self.document.applySimpleOperation(operation, ub.al);
    ub.end() catch @panic("oom");
}

pub fn getCursorPositions(self: *Core) CursorPositions {
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
    left_docbyte: u64,
    right: Position,
    right_docbyte: u64,
    len: u64,
    is_right: bool,
};
pub const CursorPosition = struct {
    pos: Selection,

    /// for pressing the up/down arrow going from [aaaa|a] ↓ to [a|] to [aaaa|a]. resets on move.
    vertical_move_start: ?Position = null,
    /// for tree_sitter, the selection at the time of the first select_up command
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
    select_ts_node: bool,
};
pub const DragSelectionMode = struct {
    stop: CursorLeftRightStop,
    select: bool,

    fn fromSelect(v: CursorLeftRightStop) DragSelectionMode {
        return .{ .select = true, .stop = v };
    }
    fn fromMove(v: CursorLeftRightStop) DragSelectionMode {
        return .{ .select = false, .stop = v };
    }
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
        mode: enum { move, select },
        direction: LRDirection,
        stop: CursorLeftRightStop,
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
    paste: struct {
        text: []const u8,
    },
    newline: void,
    insert_line: struct {
        direction: enum { up, down },
    },
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
    duplicate_line: struct {
        direction: enum { up, down },
    },

    click: struct {
        pos: Position,
        mode: DragSelectionMode = .fromMove(.unicode_grapheme_cluster),
        extend: bool = false,
        select_ts_node: bool = false,
    },
    drag: struct {
        pos: Position,
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

pub fn SliceStackAligned(comptime T: type, comptime alignment: ?u29) type {
    if (alignment) |a| {
        if (a == @alignOf(T)) {
            return SliceStackAligned(T, null);
        }
    }
    return struct {
        const Range = struct { start: usize, end: if (alignment) |_| usize else void };
        const SSA = @This();
        items: std.ArrayListAligned(T, alignment),
        ranges: std.ArrayList(Range),

        pub fn init(gpa: std.mem.Allocator) TextStack {
            return .{ .items = .init(gpa), .ranges = .init(gpa) };
        }
        pub fn deinit(self: TextStack) void {
            self.items.deinit();
            self.ranges.deinit();
        }

        pub fn clear(self: *TextStack) void {
            self.items.clearRetainingCapacity();
            self.ranges.clearRetainingCapacity();
        }

        const Begin = struct {
            ssa: *SSA,
            al: *std.ArrayListAligned(T, alignment),
            pos_start: usize,

            pub fn cancel(b: Begin) void {
                b.ssa.items.items.len = b.pos_start;
            }
            pub fn end(b: Begin) !void {
                try b.ssa.ranges.append(.{ .start = b.pos_start, .end = if (alignment) |_| b.ssa.items.items.len else {} });
                errdefer _ = b.ssa.ranges.pop();
                if (alignment) |a| {
                    const aligned_len = std.mem.alignForward(usize, b.ssa.items.items.len, a);
                    try b.ssa.items.resize(aligned_len);
                }
            }
        };

        /// { const begin = mystack.begin();
        /// errdefer begin.cancel();
        /// try begin.al.appendSlice("0123456789ABCDEF");
        /// try begin.end(); }
        pub fn begin(self: *TextStack) Begin {
            return .{ .ssa = self, .al = &self.items, .pos_start = self.items.items.len };
        }

        pub fn add(self: *TextStack, value: []const T) !void {
            try self.ranges.append(.{ .start = self.items.items.len, .end = if (alignment) |_| self.items.items.len + value.len else {} });
            errdefer _ = self.ranges.pop();
            const aligned_len = if (alignment) |a| std.mem.alignForward(usize, value.len, a) else value.len;
            const res_slice = try self.items.addManyAsSlice(aligned_len);
            @memcpy(res_slice[0..value.len], value);
        }
        /// pointer is only valid until next add(), begin(), or deinit() call.
        pub fn take(self: *TextStack) ?(if (alignment) |a| []align(a) T else []T) {
            if (self.ranges.items.len == 0) return null;

            const range = self.ranges.pop();
            const res = self.items.items[range.start..if (alignment) |_| range.end else self.items.items.len];
            self.items.items = self.items.items[0..range.start];
            return @alignCast(res);
        }
    };
}

const TextStack = SliceStackAligned(u8, bi.Alignment);

test TextStack {
    var mystack: TextStack = .init(std.testing.allocator);
    defer mystack.deinit();

    try std.testing.expectEqual(@as(usize, 0), mystack.items.items.len);
    try mystack.add("one");
    try std.testing.expectEqual(@as(usize, 16), mystack.items.items.len);
    try mystack.add("2");
    try std.testing.expectEqual(@as(usize, 32), mystack.items.items.len);
    try mystack.add("threeee!");
    try std.testing.expectEqual(@as(usize, 48), mystack.items.items.len);
    try std.testing.expectEqualStrings("threeee!", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 32), mystack.items.items.len);
    try std.testing.expectEqualStrings("2", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 16), mystack.items.items.len);
    try mystack.add("five");
    try std.testing.expectEqual(@as(usize, 32), mystack.items.items.len);
    try std.testing.expectEqualStrings("five", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 16), mystack.items.items.len);
    mystack.clear();
    try std.testing.expectEqual(@as(usize, 0), mystack.items.items.len);
    try std.testing.expectEqualStrings("null", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 0), mystack.items.items.len);

    try mystack.add("0123456789ABCDEF");
    try std.testing.expectEqual(@as(usize, 16), mystack.items.items.len);
    try mystack.add("0123456789ABCDEFG");
    try std.testing.expectEqual(@as(usize, 48), mystack.items.items.len);
    try mystack.add("0123456789ABCDEFGH");
    try std.testing.expectEqual(@as(usize, 80), mystack.items.items.len);
    try std.testing.expectEqualStrings("0123456789ABCDEFGH", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 48), mystack.items.items.len);
    try std.testing.expectEqualStrings("0123456789ABCDEFG", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 16), mystack.items.items.len);
    try std.testing.expectEqualStrings("0123456789ABCDEF", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 0), mystack.items.items.len);
    try std.testing.expectEqualStrings("null", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 0), mystack.items.items.len);

    {
        const begin = mystack.begin();
        errdefer begin.cancel();
        try begin.al.appendSlice("0123456789ABCDEF");
        try begin.end();
    }
    try std.testing.expectEqual(@as(usize, 16), mystack.items.items.len);
    {
        const begin = mystack.begin();
        errdefer begin.cancel();
        try begin.al.appendSlice("0123456789ABCDEFG");
        try begin.end();
    }
    try std.testing.expectEqual(@as(usize, 48), mystack.items.items.len);
    {
        const begin = mystack.begin();
        errdefer begin.cancel();
        try begin.al.appendSlice("0123456789ABCDEFGH");
        try begin.end();
    }
    try std.testing.expectEqual(@as(usize, 80), mystack.items.items.len);
    try std.testing.expectEqualStrings("0123456789ABCDEFGH", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 48), mystack.items.items.len);
    try std.testing.expectEqualStrings("0123456789ABCDEFG", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 16), mystack.items.items.len);
    try std.testing.expectEqualStrings("0123456789ABCDEF", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 0), mystack.items.items.len);
    try std.testing.expectEqualStrings("null", mystack.take() orelse "null");
    try std.testing.expectEqual(@as(usize, 0), mystack.items.items.len);
}

const PositionItem = struct {
    docbyte: u64,
    mode: enum { start, end },
    kind: enum { anchor, focus },

    extra: CursorPosition,

    fn compareFn(_: void, a: PositionItem, b: PositionItem) bool {
        return a.docbyte < b.docbyte;
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
    last_query: u64,
    last_query_result: ?CursorPosRes,

    pub fn init(gpa: std.mem.Allocator) CursorPositions {
        return .{ .idx = 0, .count = 0, .positions = .init(gpa), .last_query = 0, .last_query_result = null };
    }
    pub fn deinit(self: *CursorPositions) void {
        self.positions.deinit();
    }
    fn add(self: *CursorPositions, anchor: u64, focus: u64, extra: CursorPosition) void {
        const left = @min(anchor, focus);
        const right = @max(anchor, focus);
        self.positions.append(.{ .mode = .start, .docbyte = left, .kind = if (left == focus) .focus else .anchor, .extra = extra }) catch @panic("oom");
        self.positions.append(.{ .mode = .end, .docbyte = right, .kind = if (left == focus) .anchor else .focus, .extra = extra }) catch @panic("oom");
    }
    fn sort(self: *CursorPositions) void {
        std.mem.sort(PositionItem, self.positions.items, {}, PositionItem.compareFn);
    }

    pub fn advanceAndRead(self: *CursorPositions, docbyte: u64) CursorPosRes {
        const tctx = tracy.trace(@src());
        defer tctx.end();

        if (docbyte == self.last_query and self.last_query_result != null) return self.last_query_result.?;
        if (docbyte < self.last_query) @panic("advanceAndRead must advance");
        var left_cursor: CursorPosState = .none;
        var left_cursor_extra: ?CursorPosition = null;
        while (true) : (self.idx += 1) {
            if (self.idx >= self.positions.items.len) break;
            const itm = self.positions.items[self.idx];
            if (itm.docbyte > docbyte) break;
            switch (itm.mode) {
                .start => self.count += 1,
                .end => self.count -= 1,
            }
            if (itm.docbyte == docbyte) {
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
        self.last_query = docbyte;
        self.last_query_result = .{
            .left_cursor = left_cursor,
            .left_cursor_extra = left_cursor_extra,
            .selected = self.count != 0,
        };
        return self.last_query_result.?;
    }
};

fn testEditorContent(expected: []const u8, editor: *Core) !void {
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
    editor: Core,

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

test Core {
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

    tester.executeCommand(.{ .click = .{ .pos = tester.pos(13) } });
    try tester.expectContent("here are a fe|w words to traverse!");
    tester.executeCommand(.{ .click = .{ .pos = tester.pos(17), .extend = true } });
    try tester.expectContent("here are a fe[w wo|rds to traverse!");
    tester.executeCommand(.{ .click = .{ .pos = tester.pos(6) } });
    try tester.expectContent("here a|re a few words to traverse!");
    tester.executeCommand(.{ .click = .{ .pos = tester.pos(6), .mode = .fromSelect(.word) } });
    try tester.expectContent("here [are| a few words to traverse!");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(13) } });
    try tester.expectContent("here [are a few| words to traverse!");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(1) } });
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
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(1) } });
    try tester.expectContent("|e\u{301}");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(2) } });
    try tester.expectContent("|e\u{301}");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(3) } });
    try tester.expectContent("[e\u{301}|");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(2) } });
    try tester.expectContent("|e\u{301}");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(1) } });
    try tester.expectContent("|e\u{301}");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(0) } });
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

    //
    // Duplicate line
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .move_cursor_left_right = .{ .direction = .right, .stop = .word, .mode = .move } });
    try tester.expectContent("line 5\nline 5\nline 5\nline 5|");
    tester.executeCommand(.{ .duplicate_line = .{ .direction = .up } });
    try tester.expectContent("line 5\nline 5\nline 5\nline 5|\nline 5");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    tester.executeCommand(.{ .insert_text = .{ .text = "9" } });
    try tester.expectContent("line 5\nline 5\nline 5\nline 9|\nline 5");
    tester.executeCommand(.{ .duplicate_line = .{ .direction = .down } });
    try tester.expectContent("line 5\nline 5\nline 5\nline 9\nline 9|\nline 5");

    //
    // Tree sitter node functions
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .insert_text = .{ .text = "pub fn demo() !u8 {\n    return 5;\n}\n" } });
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(29), .select_ts_node = true } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return| 5;\n}\n");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(29) } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return| 5;\n}\n");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(27) } });
    try tester.expectContent("pub fn demo() !u8 {\n    |return] 5;\n}\n");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(23) } });
    try tester.expectContent("pub fn demo() !u8 |{\n    return 5;\n}]\n");
    tester.executeCommand(.{ .drag = .{ .pos = tester.pos(8) } });
    try tester.expectContent("pub |fn demo() !u8 {\n    return 5;\n}]\n");
    tester.executeCommand(.{ .click = .{ .pos = tester.pos(29) } });
    try tester.expectContent("pub fn demo() !u8 {\n    retur|n 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return| 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return 5|;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return 5;|\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub fn demo() !u8 [{\n    return 5;\n}|\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("pub [fn demo() !u8 {\n    return 5;\n}|\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("[pub fn demo() !u8 {\n    return 5;\n}\n|");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .parent } });
    try tester.expectContent("[pub fn demo() !u8 {\n    return 5;\n}\n|");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub [fn demo() !u8 {\n    return 5;\n}|\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 [{\n    return 5;\n}|\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return 5;|\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return 5|;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    [return| 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    retur|n 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });
    try tester.expectContent("pub fn demo() !u8 {\n    retur|n 5;\n}\n");
    tester.executeCommand(.{ .ts_select_node = .{ .direction = .child } });

    //
    // Insert line
    //
    tester.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("pub fn demo() !u8 {\n    return 5;\n    |\n}\n");
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .line } });
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .unicode_grapheme_cluster } });
    try tester.expectContent("pub fn demo() !u8 {\n    return 5;|\n}\n");
    tester.executeCommand(.{ .insert_line = .{ .direction = .up } });
    try tester.expectContent("pub fn demo() !u8 {\n    |\n    return 5;\n}\n");

    //
    // Copy/Paste
    //
    var copy_arena_backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer copy_arena_backing.deinit();
    const copy_arena = copy_arena_backing.allocator();
    var copied: []const u8 = undefined;

    tester.executeCommand(.{ .move_cursor_up_down = .{ .direction = .down, .mode = .duplicate, .metric = .byte } });
    try tester.expectContent("pub fn demo() !u8 {\n    |\n    |return 5;\n}\n");
    copied = tester.editor.copyAllocUtf8(copy_arena, .cut);
    try tester.expectContent("pub fn demo() !u8 {\n|}\n");
    tester.executeCommand(.{ .paste = .{ .text = copied } });
    try tester.expectContent("pub fn demo() !u8 {\n    \n    return 5;\n|}\n");

    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(4) } });
    try tester.expectContent("pub |fn demo() !u8 {\n    \n    return 5;\n}\n");
    copied = tester.editor.copyAllocUtf8(copy_arena, .cut);
    try tester.expectContent("|    \n    return 5;\n}\n");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(10) } });
    try tester.expectContent("    \n    r|eturn 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = copied } });
    try tester.expectContent("    \npub fn demo() !u8 {\n    r|eturn 5;\n}\n");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(6) } });
    try tester.expectContent("    \np|ub fn demo() !u8 {\n    return 5;\n}\n");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(6), .mode = .fromSelect(.word) } });
    try tester.expectContent("    \n[pub| fn demo() !u8 {\n    return 5;\n}\n");
    copied = tester.editor.copyAllocUtf8(copy_arena, .cut);
    try tester.expectContent("    \n| fn demo() !u8 {\n    return 5;\n}\n");
    tester.editor.executeCommand(.{ .click = .{ .pos = tester.pos(14) } });
    try tester.expectContent("    \n fn demo(|) !u8 {\n    return 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = copied } });
    try tester.expectContent("    \n fn demo(pub|) !u8 {\n    return 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = ", const" } });
    try tester.expectContent("    \n fn demo(pub, const|) !u8 {\n    return 5;\n}\n");

    copied = tester.editor.copyAllocUtf8(copy_arena, .cut);
    try tester.expectContent("    \n|    return 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = "abc" } });
    try tester.expectContent("    \nabc|    return 5;\n}\n");
    tester.executeCommand(.{ .paste = .{ .text = copied } });
    try tester.expectContent("    \nabc fn demo(pub, const) !u8 {\n|    return 5;\n}\n");

    //
    // ctrl + enter
    //
    tester.editor.executeCommand(.{ .move_cursor_left_right = .{ .direction = .left, .stop = .byte, .mode = .select } });
    try tester.expectContent("    \nabc fn demo(pub, const) !u8 {|\n]    return 5;\n}\n");
    tester.editor.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("    \nabc fn demo(pub, const) !u8 {\n|\n    return 5;\n}\n");

    //
    // undo + redo
    //
    tester.executeCommand(.select_all);
    tester.executeCommand(.{ .delete = .{ .direction = .left, .stop = .byte } });
    try tester.expectContent("|");
    tester.editor.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("\n|");
    tester.editor.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("\n\n|");
    tester.editor.executeCommand(.{ .insert_line = .{ .direction = .down } });
    try tester.expectContent("\n\n\n|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("\n\n|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("\n|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("\n|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("\n\n|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("\n\n\n|");
    tester.editor.executeCommand(.redo);
    try tester.expectContent("\n\n\n|");
    tester.editor.executeCommand(.undo);
    try tester.expectContent("\n\n|");

    // undo everything, see if it works
    while (tester.editor.undo.items.items.len > 0) {
        tester.editor.executeCommand(.undo);
    }

    try tester.expectContent("hello!");
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
    /// plain text, to be rendered in a variable width font
    markdown_plain_text,

    /// editor color - your syntax highlighter never needs to output this
    unstyled,
    /// editor color - your syntax highlighter never needs to output this
    invisible,
};
