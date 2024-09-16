const std = @import("std");
const tree_sitter = @import("tree-sitter");
const editor_core = @import("editor_core.zig");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;

// TODO
// https://github.com/tree-sitter/tree-sitter/issues/739

extern fn tree_sitter_zig() ?*tree_sitter.TSLanguage;

fn getPoint(src: []const u8) tree_sitter.TSPoint {
    return addPoint(.{ .row = 0, .column = 0 }, src);
}
fn addPoint(start_point: tree_sitter.TSPoint, src: []const u8) tree_sitter.TSPoint {
    var result: tree_sitter.TSPoint = start_point;
    for (src) |char| {
        switch (char) {
            '\n' => {
                result.row += 1;
                result.column = 0;
            },
            else => {
                result.column += 1;
            },
        }
    }
    return result;
}

fn tsinputRead(data: ?*anyopaque, byte_offset: u32, _: tree_sitter.TSPoint, bytes_read: [*c]u32) callconv(.C) [*c]const u8 {
    const block_val: *const bi.text_component.TextDocument = @ptrCast(@alignCast(data.?));
    if (byte_offset >= block_val.length()) {
        bytes_read.* = 0;
        return "";
    }
    const res = block_val.read(block_val.positionFromDocbyte(byte_offset));
    bytes_read.* = @intCast(res.len);
    return res.ptr;
}
fn textComponentToTsInput(block_val: *const bi.text_component.TextDocument) tree_sitter.TSInput {
    return .{
        .encoding = tree_sitter.TSInputEncodingUTF8,
        .payload = @constCast(@ptrCast(@alignCast(block_val))),
        .read = &tsinputRead,
    };
}


pub const Context = struct {
    alloc: std.mem.Allocator,
    parser: *tree_sitter.TSParser,
    cached_tree: *tree_sitter.TSTree,
    document: db_mod.TypedComponentRef(bi.text_component.TextDocument),
    tree_needs_reparse: bool,
    znh: ZigNodeHighlighter,

    /// refs document
    pub fn init(self: *Context, document: db_mod.TypedComponentRef(bi.text_component.TextDocument), alloc: std.mem.Allocator) !void {
        document.ref();
        errdefer document.unref();

        const parser = tree_sitter.ts_parser_new().?;
        errdefer tree_sitter.ts_parser_delete(parser);

        const lang = tree_sitter_zig().?;
        if (!tree_sitter.ts_parser_set_language(parser, lang)) {
            return error.IncompatibleLanguageVersion;
        }

        self.document = document;

        const tree = tree_sitter.ts_parser_parse(parser, null, textComponentToTsInput(document.value)).?;
        errdefer tree_sitter.ts_tree_delete(tree);

        self.* = .{
            .alloc = alloc,
            .parser = parser,
            .document = self.document,
            .cached_tree = tree,
            .tree_needs_reparse = false,
            .znh = undefined,
        };
        self.znh.init(alloc, lang);
        errdefer self.znh.deinit();

        document.value.on_after_simple_operation.addListener(.from(self, beforeUpdateCallback));
        errdefer document.value.on_after_simple_operation.removeListener(.from(self, beforeUpdateCallback));
    }
    pub fn deinit(self: *Context) void {
        self.znh.deinit();
        tree_sitter.ts_tree_delete(self.cached_tree);
        tree_sitter.ts_parser_delete(self.parser);
        self.document.value.on_after_simple_operation.removeListener(.from(self, beforeUpdateCallback));
        self.document.unref();
    }

    fn beforeUpdateCallback(self: *Context, op: bi.text_component.TextDocument.EmitSimpleOperation) void {
        if(true) @panic("TODO beforeUpdateCallback");
        self.tree_needs_reparse = true;
        self.znh.clear();
        // we need old slice
        // also .buffer.items makes no sense here, we need to call a calc fn
        const start_point = getPoint(self.document.value.buffer.items[0..op.position]);
        const old_end_point = addPoint(start_point, op.prev_slice);
        const new_end_point = addPoint(start_point, op.next_slice);
        tree_sitter.ts_tree_edit(self.cached_tree, &.{
            .start_byte = @intCast(op.position),
            .old_end_byte = @intCast(op.position + op.delete_len),
            .new_end_byte = @intCast(op.position + op.insert_text.len),
            .start_point = start_point,
            .old_end_point = old_end_point,
            .new_end_point = new_end_point,
        });
    }

    // when we go to use the nodes, we need to update the tree
    pub fn getTree(self: *Context) *tree_sitter.TSTree {
        if (self.tree_needs_reparse) {
            self.tree_needs_reparse = false;
            const source_code = self.block_ref.getDataAssumeLoadedConst().buffer.items;
            // const input: tree_sitter.TSInput = .{
            //     //   void *payload;
            //     //   const char *(*read)(
            //     //     void *payload,
            //     //     uint32_t byte_offset,
            //     //     TSPoint position,
            //     //     uint32_t *bytes_read
            //     //   );
            //     //   TSInputEncoding encoding;
            // };
            // TSTree *ts_parser_parse(
            //     TSParser *self,
            //     const TSTree *old_tree,
            //     TSInput input
            // );
            self.cached_tree = tree_sitter.ts_parser_parse_string(self.parser, self.cached_tree, source_code.ptr, @as(u32, @intCast(source_code.len))).?;
        }
        return self.cached_tree;
    }

    pub fn highlight(self: *Context) TreeSitterSyntaxHighlighter {
        self.znh.beginFrame(self.block_ref.getDataAssumeLoadedConst().buffer.items);
        return TreeSitterSyntaxHighlighter.init(&self.znh, tree_sitter.ts_tree_root_node(self.getTree()));
    }
    pub fn endHighlight(self: *Context) void {
        // self.znh.clear(); // not needed
        _ = self;
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
    root_node: tree_sitter.TSNode,
    znh: *ZigNodeHighlighter,

    pub fn init(znh: *ZigNodeHighlighter, root_node: tree_sitter.TSNode) TreeSitterSyntaxHighlighter {
        return .{
            .root_node = root_node,
            .znh = znh,
        };
    }
    pub fn deinit(self: *TreeSitterSyntaxHighlighter) void {
        _ = self;
    }

    pub fn advanceAndRead(syn_hl: *TreeSitterSyntaxHighlighter, idx: usize) editor_core.SynHlColorScope {
        std.debug.assert(idx < syn_hl.znh.buffer.?.len);

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

        const hl_node = tree_sitter.ts_node_descendant_for_byte_range(
            syn_hl.root_node,
            @intCast(idx),
            @intCast(idx + 1),
        );
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

const simple_map = std.StaticStringMap(editor_core.SynHlColorScope).initComptime(.{
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

const identifier_parents_map = std.StaticStringMap(editor_core.SynHlColorScope).initComptime(.{});

// this function is slow unfortunately
// we might need to cache syntax highlight results :/

const NodeTag = enum {
    EscapeSequence,
    line_comment,
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
};
const NodeInfo = union(enum) {
    _none,
    map_to_color_scope: editor_core.SynHlColorScope,
    other: NodeTag,
};

const NodeCacheInfo = union(enum) {
    color_scope: editor_core.SynHlColorScope,
    special: struct {
        start_byte: usize,
        kind: enum { dot, number_with_prefix, escape_sequence, line_comment, doc_comment },
    },
};
const LastNodeCache = struct {
    node: tree_sitter.TSNode,
    cache: NodeCacheInfo,
};

const ZigNodeHighlighter = struct {
    // why does this thing hold .buffer in it? probably not the right place for that
    buffer: ?[]const u8,
    node_id_to_enum_id_map: []const NodeInfo,
    fn_call_id: tree_sitter.TSFieldId,
    alloc: std.mem.Allocator,

    last_node_cache: ?LastNodeCache = null,

    pub fn init(self: *ZigNodeHighlighter, alloc: std.mem.Allocator, language: *const tree_sitter.TSLanguage) void {
        const node_id_to_enum_id_map = alloc.alloc(NodeInfo, tree_sitter.ts_language_symbol_count(language)) catch @panic("oom");
        for (node_id_to_enum_id_map, 0..) |*item, i| {
            const item_str = std.mem.span(tree_sitter.ts_language_symbol_name(language, @intCast(i)));

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
        const fn_call_name: []const u8 = "function_call";
        self.* = .{
            .buffer = null,
            .node_id_to_enum_id_map = node_id_to_enum_id_map,
            .fn_call_id = tree_sitter.ts_language_field_id_for_name(language, fn_call_name.ptr, @intCast(fn_call_name.len)),
            .alloc = alloc,
        };
    }
    pub fn deinit(self: *ZigNodeHighlighter) void {
        self.alloc.free(self.node_id_to_enum_id_map);
    }
    pub fn beginFrame(self: *ZigNodeHighlighter, buffer: []const u8) void {
        self.buffer = buffer;
    }
    pub fn clear(self: *ZigNodeHighlighter) void {
        self.buffer = null;
        self.last_node_cache = null;
    }

    pub fn nodeSymbolToInfo(hl: *ZigNodeHighlighter, info: u16) NodeInfo {
        if (info > hl.node_id_to_enum_id_map.len) return ._none;
        return hl.node_id_to_enum_id_map[info];
    }

    pub fn highlightNode(hl: *ZigNodeHighlighter, node: tree_sitter.TSNode, byte_index: usize) editor_core.SynHlColorScope {
        if (hl.last_node_cache) |cache| {
            if (tree_sitter.ts_node_eq(cache.node, node)) {
                return renderCache(hl, cache.cache, byte_index);
            }
        }
        const cache = getCacheForNode(hl, node);
        hl.last_node_cache = .{ .node = node, .cache = cache };
        return renderCache(hl, cache, byte_index);
    }
};

fn cs(v: editor_core.SynHlColorScope) NodeCacheInfo {
    return .{ .color_scope = v };
}
fn renderCache(hl: *ZigNodeHighlighter, cache: NodeCacheInfo, byte_index: usize) editor_core.SynHlColorScope {
    return switch (cache) {
        .color_scope => |scope| scope,
        .special => |special| blk: {
            const offset: i32 = @as(i32, @intCast(byte_index)) - @as(i32, @intCast(special.start_byte));
            const char = hl.buffer.?[byte_index];
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
                .number_with_prefix => switch (offset) {
                    0...1 => .keyword_storage,
                    // '.' and '_' get the same formatting otherwise it looks weird
                    // maybe we could implement punctuation_string_side and punctuation_number_part
                    // for those?
                    else => .literal,
                },
                .line_comment => switch (offset) {
                    0...2 => .punctuation,
                    else => .comment,
                },
                .doc_comment => switch (offset) {
                    0...3 => .keyword,
                    else => .comment,
                },
            };
        },
    };
}
fn getCacheForNode(hl: *ZigNodeHighlighter, node: tree_sitter.TSNode) NodeCacheInfo {
    if (tree_sitter.ts_node_is_null(node)) return cs(.invalid);
    const node_info = hl.nodeSymbolToInfo(tree_sitter.ts_node_symbol(node));

    switch (node_info) {
        ._none => return cs(.invalid),
        .map_to_color_scope => |scope| return cs(scope),
        .other => |tag| switch (tag) {
            .@"const", .@"var" => return cs(.keyword_storage),
            .@".?", .@".*" => return {
                return .{ .special = .{
                    .start_byte = tree_sitter.ts_node_start_byte(node),
                    .kind = .dot,
                } };
            },
            .EscapeSequence => {
                return .{ .special = .{
                    .start_byte = tree_sitter.ts_node_start_byte(node),
                    .kind = .escape_sequence,
                } };
            },
            .line_comment => {
                return .{ .special = .{
                    .start_byte = tree_sitter.ts_node_start_byte(node),
                    .kind = .line_comment,
                } };
            },
            .doc_comment => {
                return .{ .special = .{
                    .start_byte = tree_sitter.ts_node_start_byte(node),
                    .kind = .doc_comment,
                } };
            },
            .INTEGER, .FLOAT => {
                const start_byte = tree_sitter.ts_node_start_byte(node);
                const c1 = if (start_byte + 1 < hl.buffer.?.len) hl.buffer.?[start_byte + 1] else '\x00';
                return switch (c1) {
                    'x', 'o', 'b' => .{ .special = .{
                        .start_byte = start_byte,
                        .kind = .number_with_prefix,
                    } },
                    else => cs(.literal),
                };
            },
            .IDENTIFIER => {
                const parent_node = tree_sitter.ts_node_parent(node);
                if (tree_sitter.ts_node_is_null(parent_node)) return cs(.invalid);
                const parent_node_info = hl.nodeSymbolToInfo(tree_sitter.ts_node_symbol(parent_node));
                if (parent_node_info != .other) return cs(.variable);
                switch (parent_node_info.other) {
                    .ContainerField => return cs(.variable_constant),
                    .FnProto => return cs(.variable_function),
                    .VarDecl => {
                        const first_child = tree_sitter.ts_node_child(parent_node, 0);
                        if (tree_sitter.ts_node_is_null(first_child)) return cs(.invalid);
                        const first_child_info = hl.nodeSymbolToInfo(tree_sitter.ts_node_symbol(first_child));
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
                        if (tree_sitter.ts_node_eq(
                            tree_sitter.ts_node_child_by_field_id(parent_node, hl.fn_call_id),
                            node,
                        )) {
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

test Context {
    const gpa = std.testing.allocator;

    var my_db = db_mod.BlockDB.init(gpa);
    defer my_db.deinit();
    const src_block = my_db.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
    defer src_block.unref();
    // triggers segfault; todo debug
    // const src_component = src_block.typedComponent(bi.TextDocumentBlock) orelse unreachable;
    // defer src_component.unref();

    // var ctx: Context = undefined;
    // try ctx.init(src_component, gpa);
    // defer ctx.deinit();
}