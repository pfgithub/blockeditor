const std = @import("std");
pub const tree_sitter = @import("tree-sitter");

pub const Point = tree_sitter.TSPoint;
pub const Input = struct {
    input: tree_sitter.TSInput,

    pub fn from(encoding: enum { utf8 }, payload: anytype, comptime read_fn: fn (data: @TypeOf(payload), byte_offset: u32, point: Point) []const u8) Input {
        return .{ .input = .{
            .encoding = switch (encoding) {
                .utf8 => tree_sitter.TSInputEncodingUTF8,
            },
            .payload = @ptrCast(@constCast(payload)),
            .read = &struct {
                fn read(data: ?*anyopaque, byte_offset: u32, point: Point, bytes_read: [*c]u32) callconv(.C) [*c]const u8 {
                    const res = read_fn(@ptrCast(@alignCast(data)), byte_offset, point);
                    bytes_read.* = @intCast(res.len);
                    return res.ptr;
                }
            }.read,
        } };
    }
};

pub const Parser = struct {
    parser: *tree_sitter.TSParser,

    pub inline fn init() Parser {
        return .{ .parser = tree_sitter.ts_parser_new().? };
    }
    pub inline fn deinit(self: Parser) void {
        tree_sitter.ts_parser_delete(self.parser);
    }

    pub inline fn setLanguage(self: Parser, lang: *Language) !void {
        if (!tree_sitter.ts_parser_set_language(self.parser, @ptrCast(lang))) return error.VersionMismatch;
    }

    pub inline fn parse(self: Parser, old_tree: ?Tree, input: Input) Tree {
        return .{ .tree = tree_sitter.ts_parser_parse(self.parser, if (old_tree) |t| t.tree else null, input.input).? };
    }
};

pub const Tree = struct {
    tree: *tree_sitter.TSTree,
    pub inline fn deinit(self: Tree) void {
        tree_sitter.ts_tree_delete(self.tree);
    }

    pub inline fn edit(self: Tree, edit_val: InputEdit) void {
        tree_sitter.ts_tree_edit(self.tree, &edit_val);
    }
    pub inline fn rootNode(self: Tree) Node {
        return .{ .node = tree_sitter.ts_tree_root_node(self.tree) };
    }
};
pub const InputEdit = tree_sitter.TSInputEdit;

pub const Language = opaque {
    pub inline fn language(self: *Language) *tree_sitter.TSLanguage {
        return @ptrCast(self);
    }
    pub inline fn symbolName(self: *Language, symbol: Symbol) [:0]const u8 {
        return std.mem.span(tree_sitter.ts_language_symbol_name(self.language(), symbol));
    }
    pub inline fn symbolCount(self: *Language) u32 {
        return tree_sitter.ts_language_symbol_count(self.language());
    }
    pub inline fn fieldIdForName(self: *Language, field_name: []const u8) FieldId {
        return tree_sitter.ts_language_field_id_for_name(self.language(), field_name.ptr, @intCast(field_name.len));
    }
};
pub const Symbol = tree_sitter.TSSymbol;
pub const FieldId = tree_sitter.TSFieldId;

pub const Node = struct {
    // WISHLIST: don't allow node to be null. impl `.from(v: tree_sitter.Node) -> ?Node`,
    // and rename `node: ` to `node_not_null: ` to catch all initializaitons.
    // remove `.isNull()`

    node: tree_sitter.TSNode = .{},
    pub inline fn startByte(self: Node) u32 {
        return tree_sitter.ts_node_start_byte(self.node);
    }
    pub inline fn endByte(self: Node) u32 {
        return tree_sitter.ts_node_end_byte(self.node);
    }
    pub inline fn docbyteInRange(self: Node, docbyte: u64) bool {
        return docbyte >= self.startByte() and docbyte < self.endByte();
    }
    pub inline fn eq(self: Node, other: Node) bool {
        return tree_sitter.ts_node_eq(self.node, other.node);
    }

    pub inline fn symbol(self: Node) Symbol {
        return tree_sitter.ts_node_symbol(self.node);
    }
    pub inline fn descendantForByteRange(self: Node, left: u32, right: u32) Node {
        return .{ .node = tree_sitter.ts_node_descendant_for_byte_range(self.node, left, right) };
    }
    /// do not use! slow! also may be broken and in need of a tree sitter update
    pub inline fn slowParent(self: Node) Node {
        return .{ .node = tree_sitter.ts_node_parent(self.node) };
    }
    /// do not use! slow! internally calls parent()!
    pub inline fn slowChild(self: Node, child_index: u32) Node {
        return .{ .node = tree_sitter.ts_node_child(self.node, child_index) };
    }
    /// probably don't use this!
    pub inline fn slowChildByFieldId(self: Node, field_id: FieldId) Node {
        return .{ .node = tree_sitter.ts_node_child_by_field_id(self.node, field_id) };
    }
    pub inline fn isNull(self: Node) bool {
        return tree_sitter.ts_node_is_null(self.node);
    }
};
pub const TreeCursor = struct {
    stack: std.ArrayList(Node),
    cursor: tree_sitter.TSTreeCursor,

    pub inline fn init(gpa: std.mem.Allocator, root_node: Node) TreeCursor {
        var res_stack = std.ArrayList(Node).init(gpa);
        res_stack.append(root_node) catch @panic("oom");
        return .{ .stack = res_stack, .cursor = tree_sitter.ts_tree_cursor_new(root_node.node) };
    }
    pub inline fn deinit(self: *TreeCursor) void {
        tree_sitter.ts_tree_cursor_delete(&self.cursor);
        self.stack.deinit();
    }
    pub inline fn gotoFirstChild(self: *TreeCursor) bool {
        if (tree_sitter.ts_tree_cursor_goto_first_child(&self.cursor)) {
            self.stack.append(self._currentNode_raw()) catch @panic("oom");
            return true;
        } else return false;
    }
    pub inline fn gotoParent(self: *TreeCursor) bool {
        if (tree_sitter.ts_tree_cursor_goto_parent(&self.cursor)) {
            _ = self.stack.pop();
            return true;
        } else return false;
    }
    pub inline fn gotoNextSibling(self: *TreeCursor) bool {
        if (tree_sitter.ts_tree_cursor_goto_next_sibling(&self.cursor)) {
            _ = self.stack.pop();
            self.stack.append(self._currentNode_raw()) catch @panic("oom");
            return true;
        } else return false;
    }

    pub inline fn goDeepLhs(self: *TreeCursor) void {
        while (self.gotoFirstChild()) {}
    }

    pub inline fn _currentNode_raw(self: *TreeCursor) Node {
        return .{ .node = tree_sitter.ts_tree_cursor_current_node(&self.cursor) };
    }
    pub inline fn currentNode(self: *TreeCursor) Node {
        std.debug.assert(self.stack.getLast().eq(self._currentNode_raw()));
        return self.stack.getLast();
    }
};
