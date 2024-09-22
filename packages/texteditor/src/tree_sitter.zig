const std = @import("std");
const Core = @import("Core.zig");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const tracy = @import("anywhere").tracy;
const zgui = @import("anywhere").zgui;
pub const ts = @import("tree_sitter_bindings.zig");

// TODO
// https://github.com/tree-sitter/tree-sitter/issues/739

extern fn tree_sitter_zig() ?*ts.Language;

fn addPoint(start_point: ts.Point, src: []const u8) ts.Point {
    var result: ts.Point = start_point;
    for (src) |char| {
        result.column += 1;
        if (char == '\n') {
            result.row += 1;
            result.column = 0;
        }
    }
    return result;
}

fn tsinputRead(block_val: *const bi.text_component.TextDocument, byte_offset: u32, _: ts.Point) []const u8 {
    if (byte_offset >= block_val.length()) return "";
    return block_val.read(block_val.positionFromDocbyte(byte_offset));
}
fn textComponentToTsInput(block_val: *const bi.text_component.TextDocument) ts.Input {
    return .from(.utf8, block_val, tsinputRead);
}

pub const Context = struct {
    alloc: std.mem.Allocator,
    parser: ts.Parser,
    language: *ts.Language,
    cached_tree: ts.Tree,
    document: db_mod.TypedComponentRef(bi.text_component.TextDocument),
    tree_needs_reparse: bool,
    znh: ZigNodeHighlighter,

    old_slice: std.ArrayList(u8),

    /// refs document
    pub fn init(self: *Context, document: db_mod.TypedComponentRef(bi.text_component.TextDocument), alloc: std.mem.Allocator) !void {
        document.ref();
        errdefer document.unref();

        const parser = ts.Parser.init();
        errdefer parser.deinit();

        const lang = tree_sitter_zig().?;
        try parser.setLanguage(lang);

        self.document = document;

        const tree = parser.parse(null, textComponentToTsInput(document.value));
        errdefer tree.deinit();

        self.* = .{
            .alloc = alloc,
            .parser = parser,
            .document = self.document,
            .cached_tree = tree,
            .tree_needs_reparse = false,
            .znh = undefined,
            .old_slice = undefined,
            .language = lang,
        };
        self.znh.init(alloc, lang);
        errdefer self.znh.deinit();

        self.old_slice = .init(alloc);
        errdefer self.old_slice.deinit();

        document.value.on_before_simple_operation.addListener(.from(self, beforeUpdateCallback));
        errdefer document.value.on_before_simple_operation.removeListener(.from(self, beforeUpdateCallback));
    }
    pub fn deinit(self: *Context) void {
        self.znh.deinit();
        self.old_slice.deinit();
        self.cached_tree.deinit();
        self.parser.deinit();
        self.document.value.on_before_simple_operation.removeListener(.from(self, beforeUpdateCallback));
        self.document.unref();
    }

    fn beforeUpdateCallback(self: *Context, op: bi.text_component.TextDocument.EmitSimpleOperation) void {
        self.tree_needs_reparse = true;
        self.znh.clear();

        const block = self.document.value;
        const op_position = block.positionFromDocbyte(op.position);

        std.debug.assert(self.old_slice.items.len == 0);
        const res_slice = self.old_slice.addManyAsSlice(op.delete_len) catch @panic("oom");
        defer self.old_slice.clearRetainingCapacity();
        block.readSlice(op_position, res_slice);

        const start_point_lyncol = block.lynColFromPosition(op_position);
        const start_point: ts.Point = .{ .row = @intCast(start_point_lyncol.lyn), .column = @intCast(start_point_lyncol.col) };

        self.cached_tree.edit(.{
            .start_byte = @intCast(op.position),
            .old_end_byte = @intCast(op.position + op.delete_len),
            .new_end_byte = @intCast(op.position + op.insert_text.len),
            .start_point = start_point,
            .old_end_point = addPoint(start_point, res_slice),
            .new_end_point = addPoint(start_point, op.insert_text),
        });
    }

    // when we go to use the nodes, we need to update the tree
    pub fn getTree(self: *Context) ts.Tree {
        if (self.tree_needs_reparse) {
            self.tree_needs_reparse = false;

            self.cached_tree = self.parser.parse(self.cached_tree, textComponentToTsInput(self.document.value));
        }
        return self.cached_tree;
    }

    pub fn highlight(self: *Context) TreeSitterSyntaxHighlighter {
        self.znh.beginFrame(self.document.value);
        return TreeSitterSyntaxHighlighter.init(&self.znh, self.getTree().rootNode());
    }
    pub fn endHighlight(self: *Context) void {
        // self.znh.clear(); // not needed
        _ = self;
    }

    pub fn guiInspectNodeUnderCursor(self: *Context, cursor_left: u64, cursor_right: u64) void {
        var cursor: ts.TreeCursor = .init(self.alloc, self.getTree().rootNode());
        defer cursor.deinit();

        zgui.text("For range: {d}-{d}", .{ cursor_left, cursor_right });

        var node: ?ts.Node = self.getTree().rootNode().descendantForByteRange(@intCast(cursor_left), @intCast(cursor_right));
        while (node != null) {
            zgui.text("{s}", .{self.language.symbolName(node.?.symbol())});

            node = node.?.slowParent();
        }
    }

    // pub fn displayExplorer(self: *Context) void {
    //     const root_node = tree_sitter.ts_tree_root_node(self.getTree());

    //     var cursor: tree_sitter.TSTreeCursor = tree_sitter.ts_tree_cursor_new(root_node);
    //     defer tree_sitter.ts_tree_cursor_delete(&cursor);

    //     // this is alright but it would be nice to:
    //     // hover to show what part is in the thing

    //     displayExplorerSub(&cursor);
    // }
    // fn displayExplorerSub(cursor: *tree_sitter.TSTreeCursor) void {
    //     const node_type = std.mem.span(tree_sitter.ts_node_type(tree_sitter.ts_tree_cursor_current_node(cursor)));
    //     const node_field_name = std.mem.span(tree_sitter.ts_tree_cursor_current_field_name(cursor) orelse @as([]const u8, "").ptr);

    //     const node_fmt = if (node_field_name.len > 0) ( //
    //         imgui.fmt("{s}: \"{s}\"", .{ std.fmt.fmtSliceEscapeLower(node_field_name), std.fmt.fmtSliceEscapeLower(node_type) }) //
    //     ) else ( //
    //         imgui.fmt("\"{s}\"", .{std.fmt.fmtSliceEscapeLower(node_type)}) //
    //     );

    //     const has_children = tree_sitter.ts_tree_cursor_goto_first_child(cursor);
    //     defer if (has_children) std.debug.assert(tree_sitter.ts_tree_cursor_goto_parent(cursor));

    //     if (imgui.treeNodeEx(node_fmt.ptr, if (has_children) 0 else imgui.TreeNodeFlags_Leaf | imgui.TreeNodeFlags_NoTreePushOnOpen) and has_children) {
    //         defer imgui.treePop();

    //         while (true) {
    //             displayExplorerSub(cursor);
    //             if (!tree_sitter.ts_tree_cursor_goto_next_sibling(cursor)) break;
    //         }
    //     }
    // }
};

pub const TreeSitterSyntaxHighlighter = struct {
    root_node: ts.Node,
    znh: *ZigNodeHighlighter,
    cursor: ts.TreeCursor,
    last_access: u64,
    last_access_value: ?ts.Node,

    pub fn init(znh: *ZigNodeHighlighter, root_node: ts.Node) TreeSitterSyntaxHighlighter {
        var cursor: ts.TreeCursor = .init(znh.alloc, root_node);
        cursor.goDeepLhs();

        return .{
            .root_node = root_node,
            .znh = znh,
            .cursor = cursor,
            .last_access = 0,
            .last_access_value = null,
        };
    }
    pub fn deinit(self: *TreeSitterSyntaxHighlighter) void {
        self.cursor.deinit();
    }

    fn advanceAndRead2(self: *TreeSitterSyntaxHighlighter, docbyte: u64) ts.Node {
        const tctx = tracy.trace(@src());
        defer tctx.end();

        if (self.last_access == docbyte) if (self.last_access_value) |v| return v;
        if (docbyte < self.last_access) @panic("advanceAndRead must advance");
        self.last_access = docbyte;
        const res = self.advanceAndRead2_internal(docbyte);
        self.last_access_value = res;
        return res;
    }
    inline fn advanceAndRead2_internal(self: *TreeSitterSyntaxHighlighter, docbyte: u64) ts.Node {
        // first, advance if necessary
        if (docbyte >= self.cursor.currentNode().endByte()) {
            // need to advance
            // 1. find the lowest node who's parent contains the current docbyte

            while (true) {
                if (self.cursor.stack.items.len < 2) return self.root_node;
                const parent_node = self.cursor.stack.items[self.cursor.stack.items.len - 2];
                if (parent_node.docbyteInRange(docbyte)) {
                    // perfect node!
                    break;
                } else {
                    // not wide enough, go up one
                    std.debug.assert(self.cursor.gotoParent());
                    continue;
                }
            }

            // 2. advance next sibling until one covers our range
            while (docbyte >= self.cursor.currentNode().endByte()) {
                if (!self.cursor.gotoNextSibling()) {
                    // cursor has no next sibling. go parent
                    std.debug.assert(self.cursor.gotoParent());
                    return self.cursor.currentNode(); // no more siblings, but parent is known to cover our range
                }
            }

            // 3. goDeepLhs on final result, but skip by any nodes left of us
            while (self.cursor.gotoFirstChild()) {
                while (docbyte >= self.cursor.currentNode().endByte()) {
                    std.debug.assert(self.cursor.gotoNextSibling());
                }
            }

            std.debug.assert(docbyte < self.cursor.currentNode().endByte());
        }

        // then, find the node that contains the current docbyte
        var current_node_i = self.cursor.stack.items.len - 1;
        while (true) {
            const current_node = self.cursor.stack.items[current_node_i];
            if (current_node.docbyteInRange(docbyte)) {
                // perfect node!
                return current_node;
            } else {
                // not wide enough, go up one
                if (current_node_i == 0) return self.root_node;
                current_node_i -= 1;
                continue;
            }
        }
    }

    pub fn advanceAndRead(syn_hl: *TreeSitterSyntaxHighlighter, idx: usize) Core.SynHlColorScope {
        const tctx = tracy.trace(@src());
        defer tctx.end();

        if (idx >= syn_hl.znh.doc.?.length()) return .invalid;

        // TODO:
        // https://github.com/tree-sitter/tree-sitter/blob/8e8648afa9c30bf69a0020db9b130c4eb11b095e/lib/src/node.c#L328
        // modify this implementation to keep state so it's not slow for access in a loop
        // ts_tree_cursor_goto_descendant maybe this will help?
        // ts_tree_cursor_goto_first_child_for_byte <- maybe this will help?
        //    seems like we'd have to call it repeatedly or something
        //    also that function is bugged https://github.com/tree-sitter/tree-sitter/issues/2012

        // 5ms total is spent on ts_node_descendant_for_byte_range
        // 0.5ms total is spent on highlightNode
        // that's pretty bad

        if (false) return .punctuation_important;

        const hl_node = syn_hl.advanceAndRead2(idx);
        return syn_hl.znh.highlightNode(hl_node, idx);
    }
};

const w = std.zig.Tokenizer;

const keyword_lexeme = struct { @"0": []const u8, @"1": void };
fn genKeywordLexemes() []const keyword_lexeme {
    @setEvalBranchQuota(5498289);
    comptime var results: []const keyword_lexeme = &[_]keyword_lexeme{};
    inline for (std.meta.tags(std.zig.Token.Tag)) |value| {
        if (value.lexeme()) |vlex| {
            const result_add: []const keyword_lexeme = &[1]keyword_lexeme{keyword_lexeme{ .@"0" = vlex, .@"1" = {} }};
            results = @as([]const keyword_lexeme, results ++ result_add);
        }
    }
    return results;
}

const fallback_keyword_map = std.StaticStringMap(void).initComptime(genKeywordLexemes());

const simple_map = std.StaticStringMap(Core.SynHlColorScope).initComptime(.{
    // keyword
    .{ "BUILTINIDENTIFIER", .keyword },
    .{ "@", .keyword },

    // type
    .{ "BuildinTypeExpr", .keyword_primitive_type },

    // storage
    .{ "fn", .keyword_storage },

    // punctuation
    .{ "\"", .punctuation },
    .{ "\'", .punctuation },
    .{ "{", .punctuation },
    .{ "}", .punctuation },
    .{ "(", .punctuation },
    .{ ")", .punctuation },
    .{ "[", .punctuation },
    .{ "]", .punctuation },
    .{ ";", .punctuation },
    .{ ",", .punctuation },
    .{ "\\", .punctuation },
    .{ "\\\\", .punctuation },

    // white
    .{ ".", .punctuation_important },
    .{ "|", .punctuation_important },

    // literal https://ziglang.org/documentation/master/#Primitive-Values
    .{ "null", .literal },
    .{ "undefined", .literal },
    .{ "false", .literal },
    .{ "true", .literal },

    // other
    .{ "STRINGLITERALSINGLE", .literal_string },
    .{ "CHAR_LITERAL", .literal_string },
    .{ "LINESTRING", .literal_string },
});

const identifier_parents_map = std.StaticStringMap(Core.SynHlColorScope).initComptime(.{});

// this function is slow unfortunately
// we might need to cache syntax highlight results :/

const NodeTag = enum {
    EscapeSequence,
    line_comment,
    container_doc_comment,
    doc_comment,

    IDENTIFIER,
    INTEGER,
    FLOAT,
    ContainerField,
    FnProto,
    VarDecl,
    ParamDecl,
    FieldOrFnCall,

    @"var",
    @"const",

    @".?",
    @".*",
    @"{{",
    @"}}",
};
const NodeInfo = union(enum) {
    _none,
    map_to_color_scope: Core.SynHlColorScope,
    other: NodeTag,
};

const NodeCacheInfo = union(enum) {
    color_scope: Core.SynHlColorScope,
    special: struct {
        start_byte: usize,
        kind: enum { dot, number_with_prefix, escape_sequence, curly_escape, line_comment, doc_comment },
    },
};
const LastNodeCache = struct {
    node: ts.Node,
    cache: NodeCacheInfo,
};

const ZigNodeHighlighter = struct {
    // why does this thing hold .buffer in it? probably not the right place for that
    doc: ?*bi.text_component.TextDocument,
    node_id_to_enum_id_map: []const NodeInfo,
    fn_call_id: ts.FieldId,
    alloc: std.mem.Allocator,

    last_node_cache: ?LastNodeCache = null,

    pub fn init(self: *ZigNodeHighlighter, alloc: std.mem.Allocator, language: *ts.Language) void {
        const node_id_to_enum_id_map = alloc.alloc(NodeInfo, language.symbolCount()) catch @panic("oom");
        for (node_id_to_enum_id_map, 0..) |*item, i| {
            const item_str = language.symbolName(@intCast(i));

            item.* = if (std.meta.stringToEnum(NodeTag, item_str)) |node_tag| ( //
                .{ .other = node_tag } //
            ) else if (simple_map.get(item_str)) |color_scope| ( //
                .{ .map_to_color_scope = color_scope } //
            ) else if (fallback_keyword_map.get(item_str)) |_| ( //
                .{ .map_to_color_scope = .keyword } //
            ) else ( //
                ._none //
            );
        }
        self.* = .{
            .doc = null,
            .node_id_to_enum_id_map = node_id_to_enum_id_map,
            .fn_call_id = language.fieldIdForName("function_call"),
            .alloc = alloc,
        };
    }
    pub fn deinit(self: *ZigNodeHighlighter) void {
        self.alloc.free(self.node_id_to_enum_id_map);
    }
    pub fn beginFrame(self: *ZigNodeHighlighter, doc: *bi.text_component.TextDocument) void {
        self.doc = doc;
    }
    pub fn clear(self: *ZigNodeHighlighter) void {
        self.doc = null;
        self.last_node_cache = null;
    }

    pub fn nodeSymbolToInfo(hl: *ZigNodeHighlighter, info: u16) NodeInfo {
        if (info > hl.node_id_to_enum_id_map.len) return ._none;
        return hl.node_id_to_enum_id_map[info];
    }

    pub fn highlightNode(hl: *ZigNodeHighlighter, node: ts.Node, byte_index: usize) Core.SynHlColorScope {
        const tctx = tracy.trace(@src());
        defer tctx.end();

        if (hl.last_node_cache) |cache| {
            if (cache.node.eq(node)) {
                return renderCache(hl, cache.cache, byte_index);
            }
        }
        const cache = getCacheForNode(hl, node);
        hl.last_node_cache = .{ .node = node, .cache = cache };
        return renderCache(hl, cache, byte_index);
    }
    pub fn charAt(hl: *ZigNodeHighlighter, pos: u64) u8 {
        const tctx = tracy.trace(@src());
        defer tctx.end();

        if (pos >= hl.doc.?.length()) return '\x00';
        var char_arr: [1]u8 = undefined;
        hl.doc.?.readSlice(hl.doc.?.positionFromDocbyte(pos), &char_arr);
        return char_arr[0];
    }
};

fn cs(v: Core.SynHlColorScope) NodeCacheInfo {
    return .{ .color_scope = v };
}
fn renderCache(hl: *ZigNodeHighlighter, cache: NodeCacheInfo, byte_index: usize) Core.SynHlColorScope {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    return switch (cache) {
        .color_scope => |scope| scope,
        .special => |special| blk: {
            const offset: i32 = @as(i32, @intCast(byte_index)) - @as(i32, @intCast(special.start_byte));
            const char = hl.charAt(byte_index);
            break :blk switch (special.kind) {
                .dot => switch (offset) {
                    0 => .punctuation_important,
                    else => .keyword,
                },
                .escape_sequence => switch (offset) {
                    // https://ziglang.org/documentation/master/#Escape-Sequences
                    0 => .punctuation,
                    1 => switch (char) {
                        'n', 'r', 't' => .literal,
                        '\\', '\'', '\"' => .literal_string,
                        'x', 'u' => .keyword_storage,
                        else => .invalid,
                    },
                    else => switch (char) {
                        '{', '}' => .punctuation,
                        else => .literal,
                    },
                },
                .curly_escape => switch (offset) {
                    0 => switch (char) {
                        '{' => .punctuation,
                        else => .literal_string,
                    },
                    1 => switch (char) {
                        '}' => .punctuation,
                        else => .literal_string,
                    },
                    else => .literal_string,
                },
                .number_with_prefix => switch (offset) {
                    0...1 => .keyword_storage,
                    // '.' and '_' get the same formatting otherwise it looks weird
                    // maybe we could implement punctuation_string_side and punctuation_number_part
                    // for those?
                    else => .literal,
                },
                .line_comment => switch (offset) {
                    0...1 => .punctuation,
                    else => .comment,
                },
                .doc_comment => switch (offset) {
                    0...2 => .keyword,
                    else => .markdown_plain_text,
                },
            };
        },
    };
}
fn getCacheForNode(hl: *ZigNodeHighlighter, node: ts.Node) NodeCacheInfo {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const node_info = hl.nodeSymbolToInfo(node.symbol());

    switch (node_info) {
        ._none => return cs(.invalid),
        .map_to_color_scope => |scope| return cs(scope),
        .other => |tag| switch (tag) {
            .@"const", .@"var" => return cs(.keyword_storage),
            .@".?", .@".*" => return {
                return .{ .special = .{
                    .start_byte = node.startByte(),
                    .kind = .dot,
                } };
            },
            .@"{{", .@"}}" => return .{ .special = .{ .start_byte = node.startByte(), .kind = .curly_escape } },
            .EscapeSequence => {
                return .{ .special = .{
                    .start_byte = node.startByte(),
                    .kind = .escape_sequence,
                } };
            },
            .line_comment => {
                return .{ .special = .{
                    .start_byte = node.startByte(),
                    .kind = .line_comment,
                } };
            },
            .container_doc_comment, .doc_comment => {
                return .{ .special = .{
                    .start_byte = node.startByte(),
                    .kind = .doc_comment,
                } };
            },
            .INTEGER, .FLOAT => {
                const start_byte = node.startByte();
                const c1 = hl.charAt(start_byte);
                return switch (c1) {
                    'x', 'o', 'b' => .{ .special = .{
                        .start_byte = start_byte,
                        .kind = .number_with_prefix,
                    } },
                    else => cs(.literal),
                };
            },
            .IDENTIFIER => {
                // TODO: calling parent is bad! instead, parent should get passed into this fn
                // advanceAndRead2() knows it, so it can return it. it could return index into stack and let its caller figure it out
                const parent_node = node.slowParent() orelse return cs(.invalid);
                const parent_node_info = hl.nodeSymbolToInfo(parent_node.symbol());
                if (parent_node_info != .other) return cs(.variable);
                switch (parent_node_info.other) {
                    .ContainerField => return cs(.variable_constant),
                    .FnProto => return cs(.variable_function),
                    .VarDecl => {
                        const first_child = parent_node.slowChild(0) orelse return cs(.invalid);
                        const first_child_info = hl.nodeSymbolToInfo(first_child.symbol());
                        if (first_child_info == .other) {
                            return switch (first_child_info.other) {
                                .@"var" => return cs(.punctuation_important),
                                .@"const" => return cs(.variable_constant),
                                else => return cs(.invalid),
                            };
                        }
                        return cs(.invalid);
                    },
                    .ParamDecl => return cs(.variable_parameter),
                    .FieldOrFnCall => {
                        if (ts.Node.eq(parent_node.slowChildByFieldId(hl.fn_call_id), node)) {
                            return cs(.variable_function);
                        }
                        return cs(.variable);
                    },
                    else => return cs(.variable),
                }
            },
            else => return cs(.invalid),
        },
    }
}

// fn displayHlInfo(self: @compileError("TODO")) void {
//     const start_pos = self.core.cursor_position.left();
//     const end_pos = self.core.cursor_position.right();

//     // const buf = self.core.block_ref.getDataConst().?.buffer.items;

//     var node = tree_sitter.ts_node_descendant_for_byte_range(tree_sitter.ts_tree_root_node(self.core.tree_sitter_ctx.?.getTree()), @intCast(start_pos), @intCast(end_pos));

//     // imgui.text(imgui.fmt("{s}", .{
//     //     @tagName( tree_sitter_zig.highlightNodeZig(node, start_pos, buf)),
//     // }));
//     while (!tree_sitter.ts_node_is_null(node)) {
//         const symbol_name = tree_sitter.ts_node_type(node);
//         const start_byte = tree_sitter.ts_node_start_byte(node);
//         const end_byte = tree_sitter.ts_node_end_byte(node);
//         if (imgui.button(imgui.fmt("\"{s}\" : [{d}..{d}]", .{
//             std.fmt.fmtSliceEscapeLower(std.mem.span(symbol_name)),
//             start_byte,
//             end_byte,
//         }))) {
//             self.core.select(start_byte, end_byte);
//         }
//         node = tree_sitter.ts_node_parent(node);
//     }
// }

fn testHighlight(context: *Context, expected_value: []const u8) !void {
    return testHighlightOfsetted(context, 0, expected_value);
}
fn testHighlightOfsetted(context: *Context, offset: usize, expected_value: []const u8) !void {
    var hl = context.highlight();
    defer hl.deinit();

    var actual = std.ArrayList(u8).init(std.testing.allocator);
    defer actual.deinit();

    var prev_color_scope: Core.SynHlColorScope = .invalid;
    for (offset..context.document.value.length()) |i| {
        const read_res = hl.advanceAndRead(i);
        const char = hl.znh.charAt(i);

        switch (char) {
            ' ', '\n', '\r', '\t' => {
                // whitespace, skip writing scopes
            },
            else => {
                if (read_res != prev_color_scope) {
                    try actual.writer().print("<{s}>", .{@tagName(read_res)});
                }
                prev_color_scope = read_res;
            },
        }
        try actual.append(char);
    }

    try std.testing.expectEqualStrings(expected_value, actual.items);
}

test Context {
    const gpa = std.testing.allocator;

    var my_db = db_mod.BlockDB.init(gpa);
    defer my_db.deinit();
    const src_block = my_db.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
    defer src_block.unref();
    const src_component = src_block.typedComponent(bi.TextDocumentBlock) orelse unreachable;
    defer src_component.unref();

    src_component.applySimpleOperation(.{
        .position = src_component.value.positionFromDocbyte(0),
        .delete_len = 0,
        .insert_text = "const std = @import(\"std\");",
    }, null);

    var ctx: Context = undefined;
    try ctx.init(src_component, gpa);
    defer ctx.deinit();

    try testHighlight(&ctx, "<keyword_storage>const <variable_constant>std <keyword>= @import<punctuation>(\"<literal_string>std<punctuation>\");");
    try testHighlightOfsetted(&ctx, 19, "<punctuation>(\"<literal_string>std<punctuation>\");");

    src_component.applySimpleOperation(.{
        .position = src_component.value.positionFromDocbyte(0),
        .delete_len = src_component.value.length(),
        .insert_text = "const mystr = \"x_esc: \\x5A, n_esc: \\n, bks_esc: \\\\, str_esc: \\\", u_esc: \\u{ABC123}\";",
    }, null);

    try testHighlight(&ctx, "<keyword_storage>const <variable_constant>mystr <keyword>= <punctuation>\"<literal_string>x_esc: <punctuation>\\<keyword_storage>x<literal>5A<literal_string>, n_esc: <punctuation>\\<literal>n<literal_string>, bks_esc: <punctuation>\\<literal_string>\\, str_esc: <punctuation>\\<literal_string>\", u_esc: <punctuation>\\<keyword_storage>u<punctuation>{<literal>ABC123<punctuation>}\";");

    src_component.applySimpleOperation(.{
        .position = src_component.value.positionFromDocbyte(0),
        .delete_len = src_component.value.length(),
        .insert_text = "//!c1\n//c2\n///c3\nconst a = 0;",
    }, null);
    try testHighlight(&ctx, "<keyword>//!<markdown_plain_text>c1\n<punctuation>//<comment>c2\n<keyword>///<markdown_plain_text>c3\n<keyword_storage>const <variable_constant>a <keyword>= <literal>0<punctuation>;");

    src_component.applySimpleOperation(.{
        .position = src_component.value.positionFromDocbyte(0),
        .delete_len = src_component.value.length(),
        .insert_text = "const a = \"Hello {s}: {{.a = b}}\";",
    }, null);
    try testHighlightOfsetted(&ctx, 10, "<punctuation>\"<literal_string>Hello <punctuation>{<literal_string>s<punctuation>}<literal_string>: <punctuation>{<literal_string>{.a = b}<punctuation>}\";");

    // we can fuzz: document plus random insert should equal document plus random insert
    // but one before initializing ctx and one after
}
