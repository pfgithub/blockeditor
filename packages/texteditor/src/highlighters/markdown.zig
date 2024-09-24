const ts = @import("tree_sitter");
const std = @import("std");
const Highlighter = @import("../Highlighter.zig");
const Core = @import("../Core.zig");

extern fn tree_sitter_markdown() *ts.Language;

const NodeCacheInfo = union(enum) {
    unknown: void,
};

pub const HlMd = struct {
    cached_node: ?NodeCacheInfo,

    pub fn init() HlMd {
        const ts_language = tree_sitter_markdown();
        return .{ .ts_language = ts_language, .cached_node = null };
    }
    
    fn setNode(self_any: Highlighter.Language, ctx: *Highlighter, node: ts.Node, node_parent: ?ts.Node) void {
        const self = self_any.cast(HlMd);
        _ = ctx;
        _ = node;
        _ = node_parent;
        self.cached_node = .unknown;
    }
    fn highlightCurrentNode(self_any: Highlighter.Language, ctx: *Highlighter, offset_into_node: u32) Highlighter.SynHlColorScope {
        const self = self_any.cast(HlMd);
        _ = self;
        _ = ctx;
        _ = offset_into_node;
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