const std = @import("std");

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

// we would like to make isBoundary, prevBoundary, and nextBoundary:
// - only require one call, pass in context & method to get str
// - take care of codepoint boundaries at the edge of the context window
// - replace invalid utf-8 with '?' before passing to rust

pub const ManagedCursor = struct {
    backing: GraphemeCursor,

    pub fn init(document_len: usize) ManagedCursor {
        return .{ .backing = .init(0, document_len, true) };
    }
};
const GDirection = enum { left, right };
const GenericDocument = struct {
    data: *anyopaque,
    len: usize,

    /// pointer has to stay valid until next read() call
    /// to read one byte at a time but not from a slice, [1]u8 could be put in the document and returned out
    read: *const fn (self: GenericDocument, offset: usize, direction: GDirection) []const u8,

    pub fn from(comptime T: type, val: *const T, len: usize) GenericDocument {
        return .{ .data = @constCast(@ptrCast(val)), .len = len, .read = &T.read };
    }
    pub fn cast(self: GenericDocument, comptime T: type) *T {
        return @ptrCast(@alignCast(self.data));
    }
    pub fn isBoundary(doc: GenericDocument, cursor_pos: usize) bool {
        var cursor: GraphemeCursor = .init(cursor_pos, doc.len, true);
        _ = &cursor;

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

test "genericdocument flag test" {
    const my_str = "🇷🇸🇮🇴🇷🇸🇮🇴🇷🇸🇮🇴🇷🇸🇮🇴";
    const my_doc = struct {
        const my_doc = @This();
        str: []const u8,
        fn read(self_g: GenericDocument, offset: usize, direction: GDirection) []const u8 {
            const self = self_g.cast(my_doc);
            return switch (direction) {
                .right => self.str[offset .. offset + 1],
                .left => self.str[offset - 1 .. offset],
            };
        }
    };
    const docv = my_doc{ .str = my_str };
    const doc = GenericDocument.from(my_doc, &docv, my_str.len);

    for (0..16 + 1) |i| {
        const expected = i % 8 == 0;
        try std.testing.expectEqual(expected, doc.isBoundary(i));
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
    const my_str = "He\u{301}! …मनीष!👨‍👩‍👧‍👧/🇷🇸🇮🇴/!";

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
}
