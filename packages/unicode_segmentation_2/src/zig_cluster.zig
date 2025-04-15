const std = @import("std");
const grapheme = @import("grapheme");

const ReverseCodepointIterator = struct {
    slice: []const u21,
    index: usize,
    fn left(self: *ReverseCodepointIterator) ?u21 {
        if (self.index == 0) return null;
        self.index -= 1;
        return self.slice[self.index];
    }
    fn peekRight(self: *ReverseCodepointIterator) ?u21 {
        if (self.index >= self.slice.len) return null;
        return self.slice[self.index];
    }
};

// [...] [left] [right] | <- iter pointer
// https://unicode.org/reports/tr29/#GB1
// we could have this return the match code. ie return .GB4 / return .GB11 / ...
// and then unicode could have their tests show the expected match code
fn hasBoundary(iter: *ReverseCodepointIterator, data: *const grapheme.GraphemeData) bool {
    const extended = true;

    const right = iter.peekRight() orelse return true;
    const left = iter.left() orelse return true;

    const left_gbp = data.gbp(left);
    const left_indic_prop = data.indic(left);

    const right_gbp = data.gbp(right);
    const right_indic_prop = data.indic(right);
    const right_is_emoji = data.isEmoji(right);

    // GB3
    if (left == '\r' and right == '\n') {
        return false;
    }

    // GB4, GB5
    if (left_gbp == .Control or right_gbp == .Control or left == '\r' or left == '\n' or right == '\r' or right == '\n') {
        return true;
    }

    // GB6
    if (left_gbp == .L and (right_gbp == .L or right_gbp == .V or right_gbp == .LV or right_gbp == .LVT)) {
        return false;
    }

    // GB7
    if ((left_gbp == .LV or left_gbp == .V) and (right_gbp == .V or right_gbp == .T)) {
        return false;
    }

    // GB8
    if ((left_gbp == .LVT or left_gbp == .T) and right_gbp == .T) {
        return false;
    }

    // GB9
    if (right_gbp == .Extend or right_gbp == .ZWJ) {
        return false;
    }

    if (extended) {
        // GB9a
        if (right_gbp == .SpacingMark) return false;
        // GB9b
        if (right_gbp == .Prepend) return false;
    }

    if (extended) {
        // GB9c
        if (left_indic_prop == .Linker and right_indic_prop == .Consonant) {
            // consonant [ extend linker ]* linker [extend <here>linker]*
            // ? return false
            // a bit complicated to implement
            // @panic("TODO impl GB9c Indic_Conjunct_Break");
            return false; // TODO
        }
    }

    // GB11
    if (left_gbp == .ZWJ and right_is_emoji) {
        while (true) {
            const codepoint = iter.left() orelse return true;
            const gbp = data.gbp(codepoint);
            const is_emoji = data.isEmoji(codepoint);
            if (gbp == .Extend) continue;
            if (is_emoji) return true;
            break;
        }
    }

    // GB12, GB13
    if (left_gbp == .Regional_Indicator and right_gbp == .Regional_Indicator) {
        var count: usize = 0;
        while (true) {
            const codepoint = iter.left() orelse break;
            const gbp = data.gbp(codepoint);
            if (gbp != .Regional_Indicator) break;
            count += 1;
        }
        if (count % 2 == 1) return true;
    }

    // GB999
    return true;
}

test hasBoundary {
    const allocator = std.testing.allocator;
    const gd = try grapheme.GraphemeData.init(allocator);
    defer gd.deinit();
    // TODO

    var iter: ReverseCodepointIterator = .{ .slice = &.{ 'a', 'b', 'c' }, .index = 2 };
    try std.testing.expectEqual(true, hasBoundary(&iter, &gd));

    var out_codepoints = std.ArrayList(u21).init(allocator);
    defer out_codepoints.deinit();
    var out_breaks = std.ArrayList(bool).init(allocator);
    defer out_breaks.deinit();
    var out_break_pos = std.ArrayList(usize).init(allocator);
    defer out_break_pos.deinit();
    var line_iter = std.mem.splitScalar(u8, @embedFile("grapheme_break_test"), '\n');
    var line_no: usize = 0;
    while (line_iter.next()) |line_full| {
        line_no += 1;
        const line_hash = std.mem.indexOfScalar(u8, line_full, '#') orelse line_full.len;
        const line = std.mem.trimRight(u8, line_full[0..line_hash], " \t\r");
        var grapheme_break_tkz = GraphemeBreakTestTkz{
            .src = line,
            .idx = 0,
        };
        out_codepoints.clearRetainingCapacity();
        out_breaks.clearRetainingCapacity();
        out_break_pos.clearRetainingCapacity();
        grapheme_break_tkz.read(&out_codepoints, &out_breaks, &out_break_pos);
        if (out_codepoints.items.len == 0 and out_breaks.items.len == 0) continue;

        var iter2: ReverseCodepointIterator = .{ .slice = out_codepoints.items, .index = undefined };
        for (out_breaks.items, out_break_pos.items, 0..) |should_break, out_break_pos_val, i| {
            if (i == 0) continue;
            if (i == out_breaks.items.len) continue;
            iter2.index = i;
            const actual = hasBoundary(&iter2, &gd);
            if (actual != should_break) {
                std.log.err("grapheme_break_test:{d}:{d}: expected {}, got {}:\n{s}\n{}^", .{ line_no, out_break_pos_val, should_break, actual, ReplaceUnicode{ .slice = line_full }, Indenter{ .value = out_break_pos_val } });
            }
        }
    }
}
const ReplaceUnicode = struct {
    slice: []const u8,
    pub fn format(value: ReplaceUnicode, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        for (value.slice) |sli| {
            try writer.writeByte(switch (sli) {
                '\t' => '.',
                195 => ' ',
                183 => 'B',
                0x97 => 'n',
                else => sli,
            });
        }
    }
};
const Indenter = struct {
    value: usize,
    pub fn format(value: Indenter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.writeByteNTimes(' ', value.value);
    }
};

const GraphemeBreakTestTkz = struct {
    src: []const u8,
    idx: usize,
    fn peekByte(self: *GraphemeBreakTestTkz) ?u8 {
        if (self.idx >= self.src.len) return null;
        return self.src[self.idx];
    }
    fn nextByte(self: *GraphemeBreakTestTkz) ?u8 {
        if (self.idx >= self.src.len) return null;
        const byte = self.src[self.idx];
        self.idx += 1;
        return byte;
    }
    fn read(self: *GraphemeBreakTestTkz, out_codepoints: *std.ArrayList(u21), out_breaks: *std.ArrayList(bool), out_break_pos: *std.ArrayList(usize)) void {
        defer std.debug.assert(self.idx == self.src.len);
        while (true) {
            const start = self.idx;
            const byte = self.nextByte() orelse return;
            if (byte == 195) {
                const next = self.nextByte() orelse @panic("bad data");
                if (next == 183) {
                    out_breaks.append(true) catch @panic("oom");
                    out_break_pos.append(self.idx) catch @panic("oom");
                    continue;
                } else if (next == 0x97) {
                    out_breaks.append(false) catch @panic("oom");
                    out_break_pos.append(self.idx) catch @panic("oom");
                    continue;
                } else std.debug.panic("bad byte in if: {x}", .{next});
            }
            if (byte == ' ' or byte == '\r' or byte == '\t') continue;
            if (std.fmt.charToDigit(byte, 16)) |_| {
                while (self.peekByte()) |num| {
                    if (std.fmt.charToDigit(num, 16)) |_| {
                        _ = self.nextByte();
                    } else |_| {
                        break;
                    }
                }
                const slice = self.src[start..self.idx];
                const codepoint = std.fmt.parseInt(u21, slice, 16) catch @panic("bad data");
                out_codepoints.append(codepoint) catch @panic("oom");
                continue;
            } else |_| {}
            std.debug.panic("bad byte: {x}", .{byte});
        }
    }
};

// TODO: get tests from https://www.unicode.org/Public/UCD/latest/ucd/auxiliary/GraphemeBreakTest.txt
// zig fetch should support downloading that file i think. make sure to get a non-latest url though
