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
pub const GraphemeIncomplete = extern struct {
    // https://docs.rs/unicode-segmentation/1.8.0/unicode_segmentation/enum.GraphemeIncomplete.html
    tag: enum(u8) {
        pre_context,
        prev_chunk,
        next_chunk,
        invalid_offset,
    },
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

test "sizes" {
    assertCorrect();
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
