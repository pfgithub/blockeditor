const std = @import("std");
const Core = @import("Core.zig");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const tracy = @import("anywhere").tracy;
const zgui = @import("anywhere").zgui;
pub const ts = @import("tree_sitter");

extern fn tree_sitter_zig() *ts.Language;
extern fn tree_sitter_markdown() *ts.Language;

fn tsinputRead(block_val: *const bi.text_component.TextDocument, byte_offset: u32, _: ts.Point) []const u8 {
    if (byte_offset >= block_val.length()) return "";
    return block_val.read(block_val.positionFromDocbyte(byte_offset));
}
fn textComponentToTsInput(block_val: *const bi.text_component.TextDocument) ts.Input {
    return .from(.utf8, block_val, tsinputRead);
}

pub fn AnySized(comptime Size: comptime_int, comptime Align: comptime_int) type {
    return struct {
        data: [Size]u8 align(Align),
        ty: if (std.debug.runtime_safety) [*:0]const u8 else void,

        pub fn from(comptime T: type, value: T) @This() {
            std.debug.assert(@sizeOf(T) <= Size);
            std.debug.assert(@alignOf(T) <= Align);
            var result_bytes: [Size]u8 = [_]u8{0} ** Size;
            const bytes = std.mem.asBytes(&value);
            @memcpy(result_bytes[0..bytes.len], bytes);
            return .{ .data = result_bytes, .ty = if (std.debug.runtime_safety) @typeName(T) else void };
        }
        pub fn asPtr(self: *@This(), comptime T: type) *T {
            if (std.debug.runtime_safety) std.debug.assert(self.ty == @typeName(T));
            return std.mem.bytesAsValue(T, &self.data);
        }
        pub fn as(self: @This(), comptime T: type) T {
            if (std.debug.runtime_safety) std.debug.assert(self.ty == @typeName(T));
            return std.mem.bytesAsValue(T, &self.data).*;
        }
    };
}
test AnySized {
    const Any = AnySized(16, 16);

    var my_any = Any.from(u32, 25);
    try std.testing.expectEqual(@as(u32, 25), my_any.as(u32));
    my_any.asPtr(u32).* += 12;
    try std.testing.expectEqual(@as(u32, 25 + 12), my_any.as(u32));
}

pub const Language = struct {
    ts_language: *ts.Language,
    zig_language_data: *anyopaque,
    zig_language_vtable: *const LanguageVtable,
    pub fn cast(self: Language, comptime Target: type) *Target {
        std.debug.assert(self.zig_language_vtable.type_name == @typeName(Target));
        return @ptrCast(@alignCast(self.zig_language_data));
    }
};
const LanguageVtable = struct {
    type_name: [*:0]const u8,
    setNode: *const fn (self: Language, ctx: *Context, node: ts.Node, node_parent: ?ts.Node) void,
    highlightCurrentNode: *const fn (self: Language, ctx: *Context, docbyte: u32) Core.SynHlColorScope,
};

pub const HlZig = struct {
    ts_language: *ts.Language,
    znh: ZigNodeHighlighter,
    cached_node: ?NodeCacheInfo,

    pub fn init(gpa: std.mem.Allocator) HlZig {
        const ts_language = tree_sitter_zig();
        return .{ .ts_language = ts_language, .znh = .init(gpa, ts_language), .cached_node = null };
    }
    pub fn deinit(self: *HlZig) void {
        self.znh.deinit();
    }

    fn setNode(self_any: Language, ctx: *Context, node: ts.Node, node_parent: ?ts.Node) void {
        const self = self_any.cast(HlZig);
        self.cached_node = getCacheForNode(&self.znh, ctx, node);
        _ = node_parent;
    }
    fn highlightCurrentNode(self_any: Language, ctx: *Context, offset_into_node: u32) Core.SynHlColorScope {
        const self = self_any.cast(HlZig);
        return renderCache(ctx, self.cached_node.?, offset_into_node);
    }

    const vtable = LanguageVtable{
        .type_name = @typeName(HlZig),
        .setNode = setNode,
        .highlightCurrentNode = highlightCurrentNode,
    };
    pub fn language(self: *HlZig) Language {
        return .{
            .ts_language = self.ts_language,
            .zig_language_data = @ptrCast(self),
            .zig_language_vtable = &vtable,
        };
    }
};

pub const Context = struct {
    alloc: std.mem.Allocator,
    parser: ts.Parser,
    language: *ts.Language,
    zig_language: Language,
    cached_tree: ts.Tree,
    document: db_mod.TypedComponentRef(bi.text_component.TextDocument),
    tree_needs_reparse: bool,

    /// refs document
    pub fn init(self: *Context, document: db_mod.TypedComponentRef(bi.text_component.TextDocument), language: Language, alloc: std.mem.Allocator) void {
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
    pub fn deinit(self: *Context) void {
        self.cached_tree.deinit();
        self.parser.deinit();
        self.document.value.on_before_simple_operation.removeListener(.from(self, beforeUpdateCallback));
        self.document.unref();
    }

    fn beforeUpdateCallback(self: *Context, op: bi.text_component.TextDocument.EmitSimpleOperation) void {
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
    pub fn getTree(self: *Context) ts.Tree {
        if (self.tree_needs_reparse) {
            self.tree_needs_reparse = false;

            self.cached_tree = self.parser.parse(self.cached_tree, textComponentToTsInput(self.document.value));
        }
        return self.cached_tree;
    }

    pub fn highlight(self: *Context) TreeSitterSyntaxHighlighter {
        return TreeSitterSyntaxHighlighter.init(self, self.getTree().rootNode());
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

    pub fn charAt(self: *Context, pos: u32) u8 {
        if (pos >= self.document.value.length()) return '\x00';
        return self.document.value.read(self.document.value.positionFromDocbyte(pos))[0];
    }
};

pub const TreeSitterSyntaxHighlighter = struct {
    is_fake: bool,
    ctx: *Context,
    cursor: ts.TreeCursor,
    last_set_node: ?ts.Node,

    pub fn initPlaintext() TreeSitterSyntaxHighlighter {
        return .{ .is_fake = true, .ctx = undefined, .cursor = undefined, .last_set_node = undefined };
    }
    pub fn init(ctx: *Context, root_node: ts.Node) TreeSitterSyntaxHighlighter {
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

    pub fn advanceAndRead(self: *TreeSitterSyntaxHighlighter, idx: usize) Core.SynHlColorScope {
        if (self.is_fake) return .unstyled;

        const tctx = tracy.trace(@src());
        defer tctx.end();

        if (idx >= self.ctx.document.value.length()) return .invalid;

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
    node_id_to_enum_id_map: []const NodeInfo,
    fn_call_id: ts.FieldId,
    alloc: std.mem.Allocator,

    last_node_cache: ?LastNodeCache = null,

    pub fn init(alloc: std.mem.Allocator, language: *ts.Language) ZigNodeHighlighter {
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
        return .{
            .node_id_to_enum_id_map = node_id_to_enum_id_map,
            .fn_call_id = language.fieldIdForName("function_call"),
            .alloc = alloc,
        };
    }
    pub fn deinit(self: *ZigNodeHighlighter) void {
        self.alloc.free(self.node_id_to_enum_id_map);
    }

    pub fn nodeSymbolToInfo(hl: *ZigNodeHighlighter, info: u16) NodeInfo {
        if (info > hl.node_id_to_enum_id_map.len) return ._none;
        return hl.node_id_to_enum_id_map[info];
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
fn renderCache(ctx: *Context, cache: NodeCacheInfo, byte_index: u32) Core.SynHlColorScope {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    return switch (cache) {
        .color_scope => |scope| scope,
        .special => |special| blk: {
            const offset: i32 = @as(i32, @intCast(byte_index)) - @as(i32, @intCast(special.start_byte));
            const char = ctx.charAt(byte_index);
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
fn getCacheForNode(hl: *ZigNodeHighlighter, ctx: *Context, node: ts.Node) NodeCacheInfo {
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
                const c1 = ctx.charAt(start_byte + 1);
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
        const char = context.charAt(@intCast(i));

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

    var lang_zig = HlZig.init(gpa);
    defer lang_zig.deinit();

    var ctx: Context = undefined;
    ctx.init(src_component, lang_zig.language(), gpa);
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
