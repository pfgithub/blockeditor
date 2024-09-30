const std = @import("std");
const build_options = @import("build_options");

pub const segmentation_issue_139 = true; // https://github.com/unicode-rs/unicode-segmentation/issues/139

// bindings for
// https://docs.rs/unicode-segmentation/1.8.0/unicode_segmentation/struct.GraphemeCursor.html
//
// choose:
// - use wasm? use riscv32? compile for every target? sure

var is_correct: std.atomic.Value(bool) = .init(false);
fn assertCorrect() void {
    if (is_correct.load(.unordered)) return;
    if (!std.meta.eql(unicode_segmentation__GraphemeCursor__layout(), GraphemeCursor.layout)) @panic("bad layout for GraphemeCursor");
    is_correct.store(true, .unordered);
}

pub const GraphemeCursor = extern struct {
    data: [layout.size]u8 align(layout.alignment),
    pub const layout = Layout{ .size = 72, .alignment = 8 };
    pub fn init(offset: usize, len: usize, is_extended: bool) GraphemeCursor {
        assertCorrect();

        var result: GraphemeCursor = undefined;
        unicode_segmentation__GraphemeCursor__init(&result, offset, len, is_extended);
        return result; // moves result but that's probably okay
    }
    pub const setCursor = unicode_segmentation__GraphemeCursor__set_cursor;
    pub const curCursor = unicode_segmentation__GraphemeCursor__cur_cursor;
    pub const provideContext = unicode_segmentation__GraphemeCursor__provide_context;
    pub const isBoundary = unicode_segmentation__GraphemeCursor__is_boundary;
    pub const nextBoundary = unicode_segmentation__GraphemeCursor__next_boundary;
    pub const prevBoundary = unicode_segmentation__GraphemeCursor__prev_boundary;
};

pub const AndStr = extern struct {
    ptr: [*]const u8,
    len: usize,

    /// requires str to be utf-8 encoded
    /// before calling this function, it is recommended to
    /// iterate over the slice and replace any invalid bytes with '?'
    pub fn from(str: []const u8) AndStr {
        std.debug.assert(std.unicode.utf8ValidateSlice(str));
        return .fromUnchecked(str);
    }
    pub fn fromUnchecked(str: []const u8) AndStr {
        std.debug.assert(std.unicode.utf8ValidateSlice(str)); // just in case
        return .{ .ptr = str.ptr, .len = str.len };
    }
};
pub const ResultTag = enum(u8) { ok, err };
pub fn Result(comptime Ok: type, comptime Err: type) type {
    return extern struct {
        tag: ResultTag,
        value: extern union { ok: Ok, err: Err },
    };
}
pub const GraphemeIncompleteTag = enum(u8) {
    pre_context,
    prev_chunk,
    next_chunk,
    invalid_offset,
};
pub const GraphemeIncomplete = extern struct {
    // https://docs.rs/unicode-segmentation/1.8.0/unicode_segmentation/enum.GraphemeIncomplete.html
    tag: GraphemeIncompleteTag,
    pre_context_offset: usize,
};

const Layout = extern struct {
    size: usize,
    alignment: usize,
};

export fn rust_eh_personality() noreturn {
    @panic("rust_eh_personality");
}
export fn zig_panic(msg_ptr: [*]const u8, msg_len: usize) noreturn {
    @panic(msg_ptr[0..msg_len]);
}
extern fn unicode_segmentation__GraphemeCursor__layout() Layout;
extern fn unicode_segmentation__GraphemeCursor__init(self: *GraphemeCursor, offset: usize, len: usize, is_extended: bool) void;
extern fn unicode_segmentation__GraphemeCursor__set_cursor(self: *GraphemeCursor, offset: usize) void;
extern fn unicode_segmentation__GraphemeCursor__cur_cursor(self: *GraphemeCursor) usize;
extern fn unicode_segmentation__GraphemeCursor__provide_context(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) void;
extern fn unicode_segmentation__GraphemeCursor__is_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) Result(bool, GraphemeIncomplete);
extern fn unicode_segmentation__GraphemeCursor__next_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) Result(Result(usize, void), GraphemeIncomplete);
extern fn unicode_segmentation__GraphemeCursor__prev_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) Result(Result(usize, void), GraphemeIncomplete);

/// replaces invalid utf-8 bytes with '?', to allow the creation of a rust string.
/// be careful with string boundaries passed to rust - the string must not start or
/// end halfway through a codepoint because it will mess with cursor movement.
pub fn replaceInvalidUtf8(str_in: []u8) void {
    const replacement_char = '?';
    var str = str_in;
    while (str.len > 0) {
        // disallow null byte
        if (str[0] == '\x00') {
            str[0] = replacement_char;
            str = str[1..];
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(str[0]) catch {
            str[0] = replacement_char;
            str = str[1..];
            continue;
        };
        if (str.len < seq_len) {
            str[0] = replacement_char;
            str = str[1..];
            continue;
        }
        // is '0' a valid utf8 byte? utf8Decode seems to think it is, and so does utf8ValidateSlice
        _ = std.unicode.utf8Decode(str[0..seq_len]) catch {
            str[0] = replacement_char;
            str = str[1..];
            continue;
        };
        str = str[seq_len..];
    }
}

test replaceInvalidUtf8 {
    const dest_str = "…?À?:/";
    var mut_str = [_]u8{
        0b11100010, 0b10000000, 0b10100110, // 3 byte long, valid
        0b11110010, // 4 byte long, but invalid
        0b11000011, 0b10000000, // 2 byte long
        0b10010010, // extra non-start byte
        ':',
        '/',
    };

    replaceInvalidUtf8(&mut_str);
    try std.testing.expectEqualStrings(dest_str, &mut_str);
}

test "sizes" {
    assertCorrect();
}

const RtlFbs = struct {
    buf: []u8,
    written: usize,
    fn init(buf: []u8) RtlFbs {
        return .{ .buf = buf, .written = 0 };
    }
    fn rem(self: *RtlFbs) []u8 {
        return self.buf[0 .. self.buf.len - self.written];
    }
    fn res(self: *RtlFbs) []u8 {
        return self.buf[self.buf.len - self.written ..];
    }
    fn write(self: *RtlFbs, msg_in: []const u8) void {
        var msg = msg_in;
        const remv = self.rem();
        if (msg.len > remv.len) msg = msg[msg.len - remv.len ..];
        @memcpy(remv[remv.len - msg.len ..], msg);
        self.written += msg.len;
    }
};
pub const GDirection = enum { left, right };
pub const GenericDocument = struct {
    data: *anyopaque,
    len: u64,

    /// pointer has to stay valid even across multiple calls to read()
    read: *const fn (self: GenericDocument, offset: u64, direction: GDirection) []const u8,

    pub fn from(comptime T: type, val: *const T, len: u64) GenericDocument {
        return .{ .data = @constCast(@ptrCast(val)), .len = len, .read = &T.read };
    }
    pub fn cast(self: GenericDocument, comptime T: type) *T {
        return @ptrCast(@alignCast(self.data));
    }
    fn readFullCodepointLeft(doc: GenericDocument, offset: u64, backup_buffer: *[4]u8) ?[]const u8 {
        std.debug.assert(offset != 0 and offset != doc.len);

        // how about we read at least four bytes, then walk right to left checking if it's a valid codepoint
        // - utf8ByteSequenceLength err -> keep going left
        // - utf8Decode err -> return '?'
        var read_result = doc.read(doc, offset, .left);
        if (read_result.len < 4) {
            var buf_fbs = RtlFbs.init(backup_buffer);
            buf_fbs.write(read_result);
            while (buf_fbs.written < 4) {
                if (offset - buf_fbs.written == 0) break;
                const read_result_2 = doc.read(doc, offset - buf_fbs.written, .left);
                buf_fbs.write(read_result_2);
            }
            read_result = buf_fbs.res();
        }

        var last = read_result.len;
        const min_last = std.math.sub(usize, last, 4) catch 0;
        while (last > min_last) {
            last -= 1;
            const last_len = std.unicode.utf8ByteSequenceLength(read_result[last]) catch {
                continue;
            };
            const rrlast = read_result[last..];
            if (last_len > rrlast.len) return null; // ie [3] [x] | [x] [x] : cursor in the middle of a codepoint
            if (last_len != rrlast.len) return "?"; // went too far left
            _ = std.unicode.utf8Decode(rrlast[0..last_len]) catch {
                // utf8 decode error
                return "?";
            };
            // success
            return rrlast;
        }
        // went too far left
        return "?";
    }
    fn readFullCodepointRight(doc: GenericDocument, offset: u64, backup_buffer: *[4]u8) ?[]const u8 {
        std.debug.assert(offset != 0 and offset != doc.len);
        const read_result = doc.read(doc, offset, .right);
        std.debug.assert(read_result.len > 0);
        const start_codepoint_len = std.unicode.utf8ByteSequenceLength(read_result[0]) catch {
            // offset to readFullCodepoint should be aligned to a codepoint boundary
            // caller chooses how to handle
            return null;
        };
        if (read_result.len >= start_codepoint_len) {
            _ = std.unicode.utf8Decode(read_result[0..start_codepoint_len]) catch {
                // invalid unicode
                return "?";
            };
            // TODO we can return read_result[0.. first codepoint that fails validation]
            return read_result[0..start_codepoint_len];
        }
        var fbs = std.io.fixedBufferStream(backup_buffer[0..start_codepoint_len]);
        _ = fbs.write(read_result) catch unreachable;
        while (fbs.pos < start_codepoint_len) {
            if (offset + fbs.pos >= doc.len) {
                // codepoint is invalid because it goes off the edge of the document
                return "?";
            }
            const right_read_result = doc.read(doc, offset + fbs.pos, .right);
            _ = fbs.write(right_read_result) catch unreachable; // only errors if called a second time after returning < read_result.len the first time
        }

        _ = std.unicode.utf8Decode(fbs.buffer) catch {
            // invalid unicode
            return "?";
        };
        return fbs.buffer;
    }
    pub fn isBoundary(doc: GenericDocument, cursor_pos: u64) bool {
        if (cursor_pos == 0) return true;
        if (cursor_pos == doc.len) return true;

        var backup_buf: [4]u8 = undefined;
        const right_text = doc.readFullCodepointRight(cursor_pos, &backup_buf) orelse {
            // offset to readFullCodepoint is not aligned to a codepoint boundary
            return false;
        };

        var cursor: GraphemeCursor = .init(@intCast(cursor_pos), @intCast(doc.len), true);
        while (true) {
            const res = cursor.isBoundary(.fromUnchecked(right_text), @intCast(cursor_pos));
            if (res.tag == .ok) return res.value.ok;
            const err = res.value.err;
            switch (err.tag) {
                .pre_context => {
                    var left_buf: [4]u8 = undefined;
                    const left_text = doc.readFullCodepointLeft(err.pre_context_offset, &left_buf) orelse blk: {
                        // offset to readCodepoint has a codepoint to the left that wants to read to the right
                        break :blk "?";
                    };
                    cursor.provideContext(.fromUnchecked(left_text), err.pre_context_offset - left_text.len);
                },
                .prev_chunk => unreachable,
                .next_chunk => unreachable,
                .invalid_offset => unreachable,
            }
        }

        // so what needs to happen?
        // - rust can only be provided slices to whole codepoints
        // - steps:
        //     - call read() to the right of cursor_pos. is the first byte a valid codepoint start char?
        //       - if it is not:
        //         - call read() to the left of cursor_pos.
        //         - go to the nearest valid codepoint start char to the left
        //         - try parsing it. is it valid and does it include cursor_pos?
        //           VALID => RETURN false
        //           INVALID => RETURN true
        //     - cursor_pos is at the start of a valid codepoint. initialize GraphemeCursor at cursorpos
        //     - call isBoundary on GraphemeCursor
        //       - pass in context to the right, ending before the first invalid codepoint
        //       ...

        @panic("TODO");
    }
};
pub const SliceDocument = struct {
    slice: []const u8,
    pub fn read(self_g: GenericDocument, offset: u64, direction: GDirection) []const u8 {
        const self = self_g.cast(SliceDocument);
        return switch (direction) {
            .left => self.slice[0..@intCast(offset)],
            .right => self.slice[@intCast(offset)..],
        };
    }

    pub fn doc(self: *const SliceDocument) GenericDocument {
        return .from(SliceDocument, self, self.slice.len);
    }
};

test "genericdocument family test" {
    if (segmentation_issue_139) return error.SkipZigTest;
    const family_emoji = "A👨‍👩‍👧‍👧B";
    const slice_doc = SliceDocument{ .slice = family_emoji };
    const doc = slice_doc.doc();

    for (0..family_emoji.len + 1) |i| {
        const expected = switch (i) {
            0 => true,
            1 => true,
            family_emoji.len - 1 => true,
            family_emoji.len => true,
            else => false,
        };
        const actual = doc.isBoundary(i);
        try std.testing.expectEqual(expected, actual);
    }
}
test "family test" {
    if (segmentation_issue_139) return error.SkipZigTest;
    const family_emoji: []const u8 = "A👨‍👩‍👧‍👧B";

    var view = std.unicode.Utf8View.initUnchecked(family_emoji);
    var vi = view.iterator();
    while (vi.nextCodepointSlice()) |cs| {
        const idx = cs.ptr - family_emoji.ptr;

        var cursor: GraphemeCursor = .init(idx, family_emoji.len, true);
        const ibres = cursor.isBoundary(.fromUnchecked(family_emoji), 0);

        const expected = switch (idx) {
            0 => true,
            1 => true,
            family_emoji.len - 1 => true,
            family_emoji.len => true,
            else => false,
        };

        try std.testing.expectEqual(ResultTag.ok, ibres.tag);
        try std.testing.expectEqual(expected, ibres.value.ok);
    }

    {
        var cursor: GraphemeCursor = .init(8, family_emoji.len, true);
        const ibres1 = cursor.isBoundary(.fromUnchecked(family_emoji[8..]), 8);
        try std.testing.expectEqual(ResultTag.err, ibres1.tag);
        try std.testing.expectEqual(GraphemeIncompleteTag.pre_context, ibres1.value.err.tag);
        try std.testing.expectEqual(@as(usize, 8), ibres1.value.err.pre_context_offset);

        cursor.provideContext(.fromUnchecked(family_emoji[5..8]), 5);
        const ibres2 = cursor.isBoundary(.fromUnchecked(family_emoji[8..]), 8);
        try std.testing.expectEqual(ResultTag.err, ibres2.tag);
        try std.testing.expectEqual(GraphemeIncompleteTag.pre_context, ibres2.value.err.tag);
        try std.testing.expectEqual(@as(usize, 5), ibres2.value.err.pre_context_offset);

        cursor.provideContext(.fromUnchecked(family_emoji[1..5]), 1);
        const ibres3 = cursor.isBoundary(.fromUnchecked(family_emoji[8..]), 8);
        try std.testing.expectEqual(ResultTag.ok, ibres3.tag);
        try std.testing.expectEqual(false, ibres3.value.ok);
    }
}

test "genericdocument flag test" {
    const my_str = "🇷🇸🇮🇴🇷🇸🇮🇴🇷🇸🇮🇴🇷🇸🇮🇴";
    const my_doc = struct {
        const my_doc = @This();
        str: []const u8,
        fn read(self_g: GenericDocument, offset: u64, direction: GDirection) []const u8 {
            const self = self_g.cast(my_doc);
            return switch (direction) {
                .right => self.str[offset .. offset + 1],
                .left => self.str[offset - 1 .. offset],
            };
        }
    };
    const docv = my_doc{ .str = my_str };
    const doc = GenericDocument.from(my_doc, &docv, my_str.len);

    for (0..my_str.len + 1) |i| {
        const expected = i % 8 == 0;
        const actual = doc.isBoundary(i);
        try std.testing.expectEqual(expected, actual);
    }
}

test "flag test" {
    // apparently vscode doesn't even handle flags right. it selects all of them in a single cursor movement.
    const my_str = "🇷🇸🇮🇴🇷🇸🇮🇴🇷🇸🇮🇴🇷🇸🇮🇴";
    var cursor: GraphemeCursor = .init(0, my_str.len, true);

    for (&[_]usize{ 0, 8, 16 }) |pos| {
        cursor.setCursor(pos);
        const is_boundary_res = cursor.isBoundary(.from(my_str), 0);
        try std.testing.expectEqual(ResultTag.ok, is_boundary_res.tag);
        try std.testing.expectEqual(true, is_boundary_res.value.ok);
    }
    for (&[_]usize{ 4, 12 }) |pos| {
        cursor.setCursor(pos);
        const is_boundary_res = cursor.isBoundary(.from(my_str), 0);
        try std.testing.expectEqual(ResultTag.ok, is_boundary_res.tag);
        try std.testing.expectEqual(false, is_boundary_res.value.ok);
    }

    // now try but with bad context
    cursor.setCursor(16);
    {
        const is_boundary_res = cursor.isBoundary(.from(my_str[0..4]), 0);
        try std.testing.expectEqual(ResultTag.err, is_boundary_res.tag);
        try std.testing.expectEqual(GraphemeIncompleteTag.invalid_offset, is_boundary_res.value.err.tag);
    }
    {
        const is_boundary_res = cursor.isBoundary(.from(my_str[16..20]), 16);
        try std.testing.expectEqual(ResultTag.err, is_boundary_res.tag);
        try std.testing.expectEqual(GraphemeIncompleteTag.pre_context, is_boundary_res.value.err.tag);
        try std.testing.expectEqual(@as(usize, 16), is_boundary_res.value.err.pre_context_offset);
    }
    cursor.provideContext(.from(my_str[12..16]), 12);
    {
        const is_boundary_res = cursor.isBoundary(.from(my_str[16..20]), 16);
        try std.testing.expectEqual(ResultTag.err, is_boundary_res.tag);
        try std.testing.expectEqual(GraphemeIncompleteTag.pre_context, is_boundary_res.value.err.tag);
        try std.testing.expectEqual(@as(usize, 12), is_boundary_res.value.err.pre_context_offset);
    }
    cursor.provideContext(.from(my_str[8..12]), 8);
    {
        const is_boundary_res = cursor.isBoundary(.from(my_str[16..20]), 16);
        try std.testing.expectEqual(ResultTag.err, is_boundary_res.tag);
        try std.testing.expectEqual(GraphemeIncompleteTag.pre_context, is_boundary_res.value.err.tag);
        try std.testing.expectEqual(@as(usize, 8), is_boundary_res.value.err.pre_context_offset);
    }
    cursor.provideContext(.from(my_str[0..8]), 0);
    {
        const is_boundary_res = cursor.isBoundary(.from(my_str[16..20]), 16);
        try std.testing.expectEqual(ResultTag.ok, is_boundary_res.tag);
        try std.testing.expectEqual(true, is_boundary_res.value.ok);
    }
    // took four tries but we got there

    // the problem:
    // - this api is not set up to accept half codepoints
    //   - if we pass in my_str[16..17], 16 :: it will panic
    //   - if we replaceInvalidUtf8() first, it will "work" but return indices partway through a valid codepoint
    //   - so it takes some effort to use correctly
}

test "cursor" {
    const family_emoji = "👨‍👩‍👧‍👧";
    const my_str = "He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!" ++ family_emoji;

    var cursor: GraphemeCursor = .init(0, my_str.len, true);

    cursor.setCursor(1);
    try std.testing.expectEqual(1, cursor.curCursor());

    {
        const is_boundary_res = cursor.isBoundary(.from(my_str), 0);
        try std.testing.expectEqual(ResultTag.ok, is_boundary_res.tag);
        try std.testing.expectEqual(true, is_boundary_res.value.ok);
    }

    cursor.setCursor(2);
    try std.testing.expectEqual(2, cursor.curCursor());

    {
        const is_boundary_res = cursor.isBoundary(.from(my_str), 0);
        try std.testing.expectEqual(ResultTag.ok, is_boundary_res.tag);
        try std.testing.expectEqual(false, is_boundary_res.value.ok);
    }

    {
        const prev_boundary_res = cursor.prevBoundary(.from(my_str), 0);
        try std.testing.expectEqual(ResultTag.ok, prev_boundary_res.tag);
        try std.testing.expectEqual(ResultTag.ok, prev_boundary_res.value.ok.tag);
        try std.testing.expectEqual(@as(usize, 1), prev_boundary_res.value.ok.value.ok);
    }

    {
        const next_boundary_res = cursor.nextBoundary(.from(my_str), 0);
        try std.testing.expectEqual(ResultTag.ok, next_boundary_res.tag);
        try std.testing.expectEqual(ResultTag.ok, next_boundary_res.value.ok.tag);
        try std.testing.expectEqual(@as(usize, 4), next_boundary_res.value.ok.value.ok);
    }

    {
        cursor.setCursor(my_str.len);
        const prev_boundary_res = cursor.prevBoundary(.from(my_str), 0);
        try std.testing.expectEqual(ResultTag.ok, prev_boundary_res.tag);
        try std.testing.expectEqual(ResultTag.ok, prev_boundary_res.value.ok.tag);
        try std.testing.expectEqual(my_str.len - family_emoji.len, prev_boundary_res.value.ok.value.ok);
    }
}
