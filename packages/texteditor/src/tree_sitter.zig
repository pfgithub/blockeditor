const std = @import("std");
const Core = @import("Core.zig");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const tracy = @import("anywhere").tracy;
const zgui = @import("anywhere").zgui;
pub const ts = @import("tree_sitter");

// TODO
// https://github.com/tree-sitter/tree-sitter/issues/739

extern fn tree_sitter_zig() ?*ts.Language;
extern fn tree_sitter_markdown() ?*ts.Language;

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
            .language = lang,
        };
        self.znh.init(alloc, lang);
        errdefer self.znh.deinit();

        document.value.on_before_simple_operation.addListener(.from(self, beforeUpdateCallback));
        errdefer document.value.on_before_simple_operation.removeListener(.from(self, beforeUpdateCallback));
    }
    pub fn deinit(self: *Context) void {
        self.znh.deinit();
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
};

pub const TreeSitterSyntaxHighlighter = struct {
    root_node: ts.Node,
    znh: *ZigNodeHighlighter,
    cursor: ts.TreeCursor,

    pub fn init(znh: *ZigNodeHighlighter, root_node: ts.Node) TreeSitterSyntaxHighlighter {
        var cursor: ts.TreeCursor = .init(znh.alloc, root_node);
        cursor.goDeepLhs();

        return .{
            .root_node = root_node,
            .znh = znh,
            .cursor = cursor,
        };
    }
    pub fn deinit(self: *TreeSitterSyntaxHighlighter) void {
        self.cursor.deinit();
    }

    pub fn advanceAndRead(syn_hl: *TreeSitterSyntaxHighlighter, idx: usize) Core.SynHlColorScope {
        const tctx = tracy.trace(@src());
        defer tctx.end();

        if (idx >= syn_hl.znh.doc.?.length()) return .invalid;

        const hl_node_idx = syn_hl.cursor.advanceAndFindNodeForByte(@intCast(idx));
        const hl_node = syn_hl.cursor.stack.items[hl_node_idx];
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
