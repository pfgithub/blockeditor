const std = @import("std");
const Core = @import("Core.zig");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const zgui = @import("anywhere").zgui;
const ts = @import("tree_sitter");

const Highlighter = @This();

fn tsinputRead(block_val: *const bi.text_component.TextDocument, byte_offset: u32, _: ts.Point) []const u8 {
    if (byte_offset >= block_val.length()) return "";
    return block_val.read(block_val.positionFromDocbyte(byte_offset));
}
fn textComponentToTsInput(block_val: *const bi.text_component.TextDocument) ts.Input {
    return .from(.utf8, block_val, tsinputRead);
}

alloc: std.mem.Allocator,
parser: ts.Parser,
language: *ts.Language,
zig_language: Language,
cached_tree: ts.Tree,
document: db_mod.TypedComponentRef(bi.text_component.TextDocument),
tree_needs_reparse: bool,

/// refs document
pub fn init(self: *Highlighter, document: db_mod.TypedComponentRef(bi.text_component.TextDocument), language: Language, alloc: std.mem.Allocator) void {
    document.ref();
    const parser = ts.Parser.init();
    const lang = language.ts_language;
    parser.setLanguage(lang) catch |e| switch (e) {
        error.VersionMismatch => @panic("Version Mismatch"),
    };
    self.document = document;
    const tree = parser.parse(null, textComponentToTsInput(document.value));
    self.* = .{
        .alloc = alloc,
        .parser = parser,
        .document = self.document,
        .cached_tree = tree,
        .tree_needs_reparse = false,
        .language = lang,
        .zig_language = language,
    };

    document.value.on_before_simple_operation.addListener(.from(self, beforeUpdateCallback));
    errdefer document.value.on_before_simple_operation.removeListener(.from(self, beforeUpdateCallback));
}
pub fn deinit(self: *Highlighter) void {
    self.cached_tree.deinit();
    self.parser.deinit();
    self.document.value.on_before_simple_operation.removeListener(.from(self, beforeUpdateCallback));
    self.document.unref();
}

fn beforeUpdateCallback(self: *Highlighter, op: bi.text_component.TextDocument.EmitSimpleOperation) void {
    self.tree_needs_reparse = true;

    const block = self.document.value;
    const op_position = block.positionFromDocbyte(op.position);
    const op_end_position = block.positionFromDocbyte(op.position + op.delete_len);

    const start_point_lyncol = block.lynColFromPosition(op_position);
    const start_point: ts.Point = .{ .row = @intCast(start_point_lyncol.lyn), .column = @intCast(start_point_lyncol.col) };
    const end_point_lyncol = block.lynColFromPosition(op_end_position);
    const end_point: ts.Point = .{ .row = @intCast(end_point_lyncol.lyn), .column = @intCast(end_point_lyncol.col) };

    var new_end_point: ts.Point = start_point;
    for (op.insert_text) |char| {
        new_end_point.column += 1;
        if (char == '\n') {
            new_end_point.row += 1;
            new_end_point.column = 0;
        }
    }

    self.cached_tree.edit(.{
        .start_byte = @intCast(op.position),
        .old_end_byte = @intCast(op.position + op.delete_len),
        .new_end_byte = @intCast(op.position + op.insert_text.len),
        .start_point = start_point,
        .old_end_point = end_point,
        .new_end_point = new_end_point,
    });
}

// when we go to use the nodes, we need to update the tree
pub fn getTree(self: *Highlighter) ts.Tree {
    if (self.tree_needs_reparse) {
        self.tree_needs_reparse = false;

        self.cached_tree = self.parser.parse(self.cached_tree, textComponentToTsInput(self.document.value));
    }
    return self.cached_tree;
}

pub fn highlight(self: *Highlighter) TreeSitterSyntaxHighlighter {
    return TreeSitterSyntaxHighlighter.init(self, self.getTree().rootNode());
}
pub fn endHighlight(self: *Highlighter) void {
    // self.znh.clear(); // not needed
    _ = self;
}

pub fn guiInspectNodeUnderCursor(self: *Highlighter, cursor_left: u64, cursor_right: u64) void {
    var cursor: ts.TreeCursor = .init(self.alloc, self.getTree().rootNode());
    defer cursor.deinit();

    zgui.text("For range: {d}-{d}", .{ cursor_left, cursor_right });

    var node: ?ts.Node = self.getTree().rootNode().descendantForByteRange(@intCast(cursor_left), @intCast(cursor_right));
    while (node != null) {
        zgui.text("{s}", .{self.language.symbolName(node.?.symbol())});

        node = node.?.slowParent();
    }
}

pub fn charAt(self: *Highlighter, pos: u32) u8 {
    if (pos >= self.document.value.length()) return '\x00';
    return self.document.value.read(self.document.value.positionFromDocbyte(pos))[0];
}

pub const Language = struct {
    ts_language: *ts.Language,
    zig_language_data: *anyopaque,
    zig_language_vtable: *const Vtable,
    pub fn cast(self: Language, comptime Target: type) *Target {
        std.debug.assert(self.zig_language_vtable.type_name == @typeName(Target));
        return @ptrCast(@alignCast(self.zig_language_data));
    }
    pub const Vtable = struct {
        type_name: [*:0]const u8,
        setNode: *const fn (self: Language, ctx: *Highlighter, node: ts.Node, node_parent: ?ts.Node) void,
        highlightCurrentNode: *const fn (self: Language, ctx: *Highlighter, docbyte: u32) Highlighter.SynHlColorScope,
    };
};

pub const TreeSitterSyntaxHighlighter = struct {
    is_fake: bool,
    ctx: *Highlighter,
    cursor: ts.TreeCursor,
    last_set_node: ?ts.Node,

    pub fn initPlaintext() TreeSitterSyntaxHighlighter {
        return .{ .is_fake = true, .ctx = undefined, .cursor = undefined, .last_set_node = undefined };
    }
    pub fn init(ctx: *Highlighter, root_node: ts.Node) TreeSitterSyntaxHighlighter {
        var cursor: ts.TreeCursor = .init(ctx.alloc, root_node);
        cursor.goDeepLhs();

        return .{
            .is_fake = false,
            .ctx = ctx,
            .cursor = cursor,
            .last_set_node = null,
        };
    }
    pub fn deinit(self: *TreeSitterSyntaxHighlighter) void {
        if (self.is_fake) return;
        self.cursor.deinit();
    }

    pub fn advanceAndRead(self: *TreeSitterSyntaxHighlighter, idx: usize) SynHlColorScope {
        if (self.is_fake) return .unstyled;

        if (idx >= self.ctx.document.value.length()) return .invalid;
        if (idx < self.cursor.last_access) return .unstyled; // did not advance; return wrong information

        const hl_node_idx = self.cursor.advanceAndFindNodeForByte(@intCast(idx));
        const hl_node = self.cursor.stack.items[hl_node_idx];

        if (self.last_set_node == null or !self.last_set_node.?.eq(hl_node)) {
            const hl_node_parent: ?ts.Node = if (hl_node_idx == 0) null else self.cursor.stack.items[hl_node_idx - 1];
            self.ctx.zig_language.zig_language_vtable.setNode(self.ctx.zig_language, self.ctx, hl_node, hl_node_parent);
            self.last_set_node = hl_node;
        }

        return self.ctx.zig_language.zig_language_vtable.highlightCurrentNode(self.ctx.zig_language, self.ctx, @intCast(idx));
    }
};

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
