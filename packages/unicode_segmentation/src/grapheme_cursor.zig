// bindings for
// https://docs.rs/unicode-segmentation/1.8.0/unicode_segmentation/struct.GraphemeCursor.html
//
// choose:
// - use wasm? use riscv32? compile for every target? sure

pub const GraphemeCursor = struct {
    pub const create = unicode_segmentation__GraphemeCursor__new;
    pub const destroy = unicode_segmentation__GraphemeCursor__drop;
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

    pub fn from(str: []const u8) AndStr {
        return .{ .ptr = str.ptr, .len = str.len };
    }
};
pub fn Result(comptime Ok: type, comptime Err: type) type {
    return extern struct {
        tag: enum(u8) { ok, err },
        value: extern union { ok: Ok, err: Err },
    };
}
pub fn Option(comptime Child: type) type {
    return extern struct {
        tag: enum(u8) { some, none },
        value: extern union { some: Child, none: void },
    };
}
pub const GraphemeIncomplete = extern struct {
    // https://docs.rs/unicode-segmentation/1.8.0/unicode_segmentation/enum.GraphemeIncomplete.html
    result: enum(u8) {
        pre_context,
        prev_chunk,
        next_chunk,
        invalid_offset,
    },
    pre_context_offset: usize,
};
pub const IsBoundaryResult = extern struct {
    // Result<bool, GraphemeIncomplete>
    result: enum(u8) { is_boundary, is_not_boundary, err },
    incomplete_grapheme: GraphemeIncomplete,
};
pub const NextPrevBoundaryResult = extern struct {
    // Result<Option<usize>, GraphemeIncomplete>
    result: enum(u8) { success, err },
    success_result: usize,
    incomplete_grapheme: GraphemeIncomplete,
};

extern fn unicode_segmentation__GraphemeCursor__new(offset: usize, len: usize, is_extended: bool) *GraphemeCursor;
extern fn unicode_segmentation__GraphemeCursor__drop(self: *GraphemeCursor) void;
extern fn unicode_segmentation__GraphemeCursor__set_cursor(self: *GraphemeCursor, offset: usize) void;
extern fn unicode_segmentation__GraphemeCursor__cur_cursor(self: *GraphemeCursor) usize;
extern fn unicode_segmentation__GraphemeCursor__provide_context(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) void;
extern fn unicode_segmentation__GraphemeCursor__is_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) IsBoundaryResult;
extern fn unicode_segmentation__GraphemeCursor__next_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) NextPrevBoundaryResult;
extern fn unicode_segmentation__GraphemeCursor__prev_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) NextPrevBoundaryResult;
