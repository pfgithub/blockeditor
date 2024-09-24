const ts = @import("tree_sitter");
const std = @import("std");
const Highlighter = @import("../Highlighter.zig");
const Core = @import("../Core.zig");

extern fn tree_sitter_markdown() *ts.Language;

// for markdown, we want a bit more control over rendering than just being a regular tree sitter grammar
// - in a code fence, we want to render a code fence around the area.
// - in a blockquote, we want to render a line left of the block quoted contents
// we can also consider using queries. queries allow filtering the query cursor range to certain bytes.

const NodeCacheInfo = union(enum) {
    unknown: void,
};

pub const HlMd = struct {
    ts_language: *ts.Language,
    cached_node: ?NodeCacheInfo,

    pub fn init() HlMd {
        const ts_language = tree_sitter_markdown();
        return .{ .ts_language = ts_language, .cached_node = null };
    }
    pub fn deinit(self: HlMd) void {
        _ = self;
    }

    fn setNode(self_any: Highlighter.Language, ctx: *Highlighter, node: ts.Node, node_parent: ?ts.Node) void {
        const self = self_any.cast(HlMd);
        _ = ctx;
        _ = node;
        _ = node_parent;
        self.cached_node = .unknown;
    }
    fn highlightCurrentNode(self_any: Highlighter.Language, ctx: *Highlighter, byte_index: u32) Highlighter.SynHlColorScope {
        const self = self_any.cast(HlMd);
        _ = self;
        _ = ctx;
        _ = byte_index;
        return .unstyled;
    }

    const vtable = Highlighter.Language.Vtable{
        .type_name = @typeName(HlMd),
        .setNode = setNode,
        .highlightCurrentNode = highlightCurrentNode,
    };
    pub fn language(self: *HlMd) Highlighter.Language {
        return .{
            .ts_language = self.ts_language,
            .zig_language_data = @ptrCast(self),
            .zig_language_vtable = &vtable,
        };
    }
};
