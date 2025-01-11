// parses to rpn
const std = @import("std");

const AstTree = struct {
    tags: []const AstNode.Tag,
    values: []const AstNode.Value,
    string_buf: []const u8,

    fn tag(t: *const AstTree, node: AstExpr) AstNode.Tag {
        return t.tags[node.idx];
    }
    fn isAtom(t: *const AstTree, node: AstExpr) bool {
        return t.tag(node).isAtom();
    }
    fn atomValue(t: *const AstTree, node: AstExpr) u32 {
        std.debug.assert(t.isAtom(node));
        return t.values[node.idx].atom_value;
    }
    fn exprLen(t: *const AstTree, node: AstExpr) u32 {
        std.debug.assert(!t.isAtom(node));
        return t.values[node.idx].expr_len;
    }

    fn firstChild(t: *const AstTree, node: AstExpr) ?AstExpr {
        std.debug.assert(!t.isAtom(node));
        const expr_len = t.exprLen(node);
        if (expr_len == 0) return null;
        return .{ .idx = node.idx + 1, .parent_end = node.idx + 1 + expr_len };
    }
    fn next(t: *const AstTree, node: AstExpr) ?AstExpr {
        const idx = switch (t.isAtom(node)) {
            true => node.idx + 1,
            false => node.idx + 1 + t.exprLen(node),
        };
        if (idx >= node.parent_end) {
            std.debug.assert(idx == node.parent_end);
            return null;
        }
        return .{ .idx = idx, .parent_end = node.parent_end };
    }
};
const AstExpr = packed struct(u64) {
    idx: u32,
    parent_end: u32,
};

fn flipResult(tags: []AstNode.Tag, values: []AstNode.Value, src_index: usize, shift_right: usize) usize {
    const my_tag = tags[src_index];
    const my_value = values[src_index];
    const ch_len: usize = if (my_tag.isAtom()) 0 else my_value.expr_len;
    if (ch_len != 0) {
        var i = src_index - 1;
        while (true) {
            i -= flipResult(tags, values, i, shift_right + 1);
            if (i <= src_index - ch_len) break;
            i -= 1;
        }
    }
    tags[src_index + shift_right - ch_len] = my_tag;
    values[src_index + shift_right - ch_len] = my_value;
    return ch_len;
}

fn dumpAstNodes(tags: []const AstNode.Tag, values: []const AstNode.Value, w: std.io.AnyWriter) !void {
    for (tags, values) |tag, value| {
        try w.print("[{s} {x}]", .{ @tagName(tag), if (tag.isAtom()) value.atom_value else value.expr_len });
    }
}
fn orderU32(context: u32, item: u32) std.math.Order {
    return std.math.order(context, item);
}

const Printer = struct {
    tree: *const AstTree,
    w: std.io.AnyWriter,
    is_err: bool = false,
    indent: usize = 0,

    fn fmt(p: *Printer, comptime f: []const u8, a: anytype) void {
        p.w.print(f, a) catch {
            p.is_err = true;
        };
    }
    fn newline(p: *Printer) void {
        p.w.writeByteNTimes(' ', 4 * p.indent);
    }

    fn printExpr(p: *Printer, fc: AstExpr) void {
        switch (p.tree.tag(fc)) {
            else => |k| {
                p.fmt("<todo: {s}>", .{@tagName(k)});
            },
        }
    }

    fn printMapContents(p: *Printer, parent: AstExpr) void {
        var fch = p.tree.firstChild(parent);
        while (fch) |fc| : (fch = p.tree.firstChild(fch.?)) {
            p.printExpr(fc);
            p.fmt(";", .{});
            p.newline();
        }
    }
    // validate this by reprinting and asserting the dest ast is === to the src ast excluding srclocs
    // for(src_ast_k, src_ast_v, dest_ast_k, dest_ast_v) |sa, sb, da, db| { std.debug.assert(sa == da); if(sa != .srcloc) std.debug.assert(sb == db); }
    fn printAst(p: *Printer, root: AstExpr) void {
        if (p.tree.tag(root) != .map) {
            p.is_err = true;
            return;
        }
        p.printMapContents(root);
    }
};

fn dumpAst(tree: *const AstTree, root: AstExpr, w: std.io.AnyWriter, positions: []const u32, skip_outer: bool) !void {
    // custom value handling
    switch (tree.tag(root)) {
        .srcloc => {
            const idx = std.sort.binarySearch(u32, positions, tree.atomValue(root), orderU32) orelse {
                // not found
                try w.print("@<{d}>", .{tree.atomValue(root)});
                return;
            };
            try w.print("@{d}", .{idx});
            return;
        },
        else => {},
    }
    if (!skip_outer) try w.print("[{s}", .{@tagName(tree.tag(root))});
    switch (tree.isAtom(root)) {
        true => {
            try w.print(" 0x{X}", .{tree.atomValue(root)});
        },
        false => {
            var fch = tree.firstChild(root);
            var is_first = true;
            while (fch) |ch| {
                if (!is_first or !skip_outer) try w.print(" ", .{});
                is_first = false;
                // string printing
                switch (tree.tag(ch)) {
                    .string_offset => {
                        // print string
                        const str_offset = tree.atomValue(ch);
                        fch = tree.next(ch);
                        std.debug.assert(fch != null);
                        std.debug.assert(tree.tag(fch.?) == .string_len);
                        const str_len = tree.atomValue(fch.?);
                        try w.print("\"{}\"", .{std.zig.fmtEscapes(tree.string_buf[str_offset..][0..str_len])});
                    },
                    else => {
                        // default handling
                        try dumpAst(tree, ch, w, positions, false);
                    },
                }
                fch = tree.next(fch.?);
            }
        },
    }
    if (!skip_outer) try w.print("]", .{});
}

const AstNode = struct {
    const Tag = enum(u8) {
        // expr
        map, // [a, b, c]
        bind, // #a b : [decl a b]
        code, // {a; b; c} : [code [a] [b] [c]] ||| {a; b;} : [code [a] [b] [void]]
        builtin_std, // [builtin_std]
        map_entry, // "a": "b" : [map_entry [string "a"] [string "b"]]
        code_eql,
        string, // [string [string_offset string_len]]
        call, // a b : [call [a] [b]]
        err, // only intended for errors which should prevent any further compilation steps within the node. other errors should go in a list (TODO)
        err_skip, // ignore the contents of this
        ref,
        access, // a.b.c => [access [access a @0 b] @1 c]
        key,
        slot,
        defer_expr,

        // atom
        string_offset,
        string_len,
        srcloc,

        fn isAtom(tag: Tag) bool {
            return switch (tag) {
                .string_offset => true,
                .string_len => true,
                .srcloc => true,
                else => false,
            };
        }
    };
    const Value = union {
        atom_value: u32,
        expr_len: u32,
    };
    tag: Tag,
    value: Value,
};
const Token = enum {
    identifier,
    number, // not "123.456" or "-345", those are multiple tokens. we could support them maybe?
    symbols, // eg '=' or ':='
    sep, // ',' or ';'
    // '(', '[', '{', '}', ']', ')', '\'', ':', '.'
    lparen,
    lbracket,
    lcurly,
    rcurly,
    rbracket,
    rparen,
    single_quote,
    double_quote,
    colon,
    dot,
    whitespace_inline,
    whitespace_newline,
    eof,
    bracket,
    equals,
    colon_equals,
    inline_comment,
    hashtag,
    kw_defer,
    string_identifier_start,

    // string only
    string,
    string_backslash,

    // for tokenizer only
    _maybe_keyword,

    pub const izer = Tokenizer;
    pub fn name(t: Token) []const u8 {
        return @tagName(t);
    }
};
const reserved_symbols_map = std.StaticStringMap(Token).initComptime(.{
    .{ "=", .equals },
    .{ ":=", .colon_equals },
    .{ ":", .colon },
    .{ "//", .inline_comment },
    .{ "#", ._maybe_keyword },
});
const keywords_map = std.StaticStringMap(Token).initComptime(.{
    .{ "defer", .kw_defer },
});
const Tokenizer = struct {
    // TODO: consider enforcing correct indentation of code
    token: Token,
    token_start_srcloc: u32,
    token_end_srcloc: u32,

    source: []const u8,

    has_error: ?struct { pos: u32, byte: u8, msg: Emsg },
    in_string: bool,
    const Emsg = enum { invalid_byte, invalid_identifier, newline_not_allowed_in_string };

    fn init(src: []const u8, state: State) Tokenizer {
        std.debug.assert(src.len < std.math.maxInt(u32));
        var res: Tokenizer = .{
            .source = src,
            .token = .eof,
            .token_start_srcloc = 0,
            .token_end_srcloc = 0,
            .has_error = null,
            .in_string = false,
        };
        res.next(state);
        return res;
    }

    inline fn _setSingleByteToken(self: *Tokenizer, token: Token) void {
        self.token_end_srcloc += 1;
        self.token = token;
    }
    pub const State = enum { root, inside_string };
    fn next(self: *Tokenizer, state: State) void {
        defer {
            // std.log.err("tkz: {s} \"{}\"", .{ @tagName(self.token), std.zig.fmtEscapes(self.slice()) });
        }
        if (state == .inside_string) std.debug.assert(self.in_string);
        while (true) {
            self.token_start_srcloc = self.token_end_srcloc;
            var rem = self.source[self.token_end_srcloc..];
            if (rem.len == 0) {
                self.token = .eof;
                return;
            }
            switch (state) {
                .root => switch (rem[0]) {
                    ' ', '\t', '\r', '\n' => {
                        self.token = .whitespace_inline;
                        self.token_end_srcloc += for (rem, 0..) |byte, i| switch (byte) {
                            ' ', '\t', '\r' => {},
                            '\n' => {
                                if (self.in_string) {
                                    if (self.has_error == null) self.has_error = .{ .pos = @intCast(self.token_start_srcloc + i), .byte = '\n', .msg = .newline_not_allowed_in_string };
                                }
                                self.token = .whitespace_newline;
                            },
                            else => break @intCast(i),
                        } else @intCast(rem.len);
                    },
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => |c| {
                        self.token_end_srcloc += for (rem[1..], 1..) |byte, i| switch (byte) {
                            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                            else => break @intCast(i),
                        } else @intCast(rem.len);
                        if (std.ascii.isDigit(c)) {
                            self.token = .number;
                        } else {
                            self.token = .identifier;
                        }
                    },
                    ',', ';' => self._setSingleByteToken(.sep),
                    '"' => self._setSingleByteToken(.double_quote),
                    '\'' => self._setSingleByteToken(.single_quote),
                    '.' => self._setSingleByteToken(.dot),
                    '(' => self._setSingleByteToken(.lparen),
                    '[' => self._setSingleByteToken(.lbracket),
                    '{' => self._setSingleByteToken(.lcurly),
                    '}' => self._setSingleByteToken(.rcurly),
                    ']' => self._setSingleByteToken(.rbracket),
                    ')' => self._setSingleByteToken(.rparen),
                    '~', '`', '!', '@', '#', '$', '%', '^', '&', '*', '-', '=', '+', '\\', '|', '<', '>', '/', '?', ':' => {
                        self.token_end_srcloc += for (rem[1..], 1..) |byte, i| switch (byte) {
                            '~', '`', '!', '@', '#', '$', '%', '^', '&', '*', '-', '=', '+', '\\', '|', '<', '>', '/', '?' => {},
                            else => break @intCast(i),
                        } else @intCast(rem.len);
                        self.token = reserved_symbols_map.get(self.slice()) orelse .symbols;
                        if (self.token == .inline_comment) {
                            const rem2 = self.source[self.token_end_srcloc..];
                            self.token_end_srcloc += for (rem2, 0..) |byte, i| switch (byte) {
                                '\n' => break @intCast(i + 1),
                                '\r' => {},
                                else => {
                                    if (byte < ' ' or byte == 0x7F) {
                                        if (self.has_error == null) self.has_error = .{ .byte = byte, .pos = @intCast(self.token_end_srcloc + i), .msg = .invalid_byte };
                                    }
                                },
                            } else @intCast(rem2.len);
                        } else if (self.token == ._maybe_keyword) {
                            const rem2 = self.source[self.token_end_srcloc..];
                            if (rem2.len > 0 and rem2[0] == '"') {
                                // string identifier
                                self.token = .string_identifier_start;
                                self.token_end_srcloc += 1;
                            } else {
                                self.token_end_srcloc += for (rem2[0..], 0..) |byte, i| switch (byte) {
                                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                                    else => break @intCast(i),
                                } else @intCast(rem.len);
                                if (keywords_map.get(self.slice()[1..])) |kw| {
                                    self.token = kw;
                                } else {
                                    if (self.slice().len > 1) self.has_error = .{ .pos = self.token_start_srcloc, .byte = '\x00', .msg = .invalid_identifier };
                                    self.token_end_srcloc = self.token_start_srcloc + 1;
                                    self.token = .symbols;
                                }
                            }
                        }
                    },
                    else => |b| {
                        @branchHint(.cold);
                        // mark an error and ignore the byte
                        if (self.has_error == null) self.has_error = .{ .pos = self.token_start_srcloc, .byte = b, .msg = .invalid_byte };
                        self.token_start_srcloc += 1;
                        self.token_end_srcloc = self.token_start_srcloc;
                        continue;
                    },
                },
                .inside_string => switch (rem[0]) {
                    '"' => self._setSingleByteToken(.double_quote),
                    '\\' => self._setSingleByteToken(.string_backslash),
                    '\n' => {
                        @branchHint(.cold);
                        self.next(.root);
                        std.debug.assert(self.token == .whitespace_newline);
                        std.debug.assert(self.has_error != null);
                        self.token = .double_quote; // so the string doesn't end up spanning multiple lines
                    },
                    else => |b| {
                        if (b < ' ' or b == 0x7F) {
                            @branchHint(.cold);
                            // mark an error and ignore the byte
                            if (self.has_error == null) self.has_error = .{ .pos = self.token_start_srcloc, .byte = b, .msg = .invalid_byte };
                            self.token_start_srcloc += 1;
                            self.token_end_srcloc = self.token_start_srcloc;
                            continue;
                        }
                        // ok
                        self.token_end_srcloc += for (rem[1..], 1..) |byte, i| switch (byte) {
                            '"', '\\', 0...' ' - 1, 0x7F => break @intCast(i),
                            else => {},
                        } else @intCast(rem.len);
                        self.token = .string;
                    },
                },
            }
            break;
        }
    }
    fn slice(self: *Tokenizer) []const u8 {
        return self.source[self.token_start_srcloc..self.token_end_srcloc];
    }
};
const Parser = struct {
    gpa: std.mem.Allocator,

    tokenizer: Tokenizer,
    out_nodes: std.MultiArrayList(AstNode) = .empty,
    seen_strings: std.ArrayHashMapUnmanaged(StringMapKey, void, StringContext, true) = .empty,
    strings: std.ArrayListUnmanaged(u8) = .empty,
    has_errors: bool = false,
    has_fatal_error: ?enum { oom, src_too_long } = null,
    string_active: bool = false,

    pub fn init(src: []const u8, gpa: std.mem.Allocator) Parser {
        if (src.len > std.math.maxInt(u32) - 1000) {
            return .{ .gpa = gpa, .tokenizer = .init("", .root), .has_errors = true, .has_fatal_error = .oom };
        }
        return .{
            .gpa = gpa,
            .tokenizer = .init(src, .root),
        };
    }
    pub fn deinit(self: *Parser) void {
        self.out_nodes.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.seen_strings.deinit(self.gpa);
    }

    fn postAtom(p: *Parser, atom: AstNode.Tag, value: u32) void {
        p.out_nodes.append(p.gpa, .{
            .tag = atom,
            .value = .{ .atom_value = value },
        }) catch p.oom();
    }
    fn wrapExpr(p: *Parser, expr: AstNode.Tag, start_node: usize) void {
        p.out_nodes.append(p.gpa, .{
            .tag = expr,
            .value = .{ .expr_len = @intCast(p.here().node - start_node) },
        }) catch p.oom();
    }
    fn wrapErr(p: *Parser, node: usize, srcloc: u32, comptime msg: []const u8, args: anytype) void {
        @branchHint(.cold);
        var str = p.stringBegin();
        str.print(msg, args);
        return p._wrapErrFormatted(node, srcloc, &str);
    }
    fn _wrapErrFormatted(p: *Parser, node: usize, srcloc: u32, str: *StringBuilder) void {
        p.wrapExpr(.err_skip, node); // wrap the previous junk in an error node so it can be easily skipped over
        p.postAtom(.srcloc, srcloc);
        p.postString(str.end());
        p.wrapExpr(.err, node);
    }
    fn oom(p: *Parser) void {
        p.has_errors = true;
        if (p.has_fatal_error == null) p.has_fatal_error = .oom;
    }

    const Here = struct { src: u32, node: usize };
    fn here(p: *Parser) Here {
        return .{ .src = p.tokenizer.token_start_srcloc, .node = p.out_nodes.len };
    }
    /// 0 is returned for eof, or if a null byte is encountered in the file
    fn asHex(c: u8) ?u4 {
        return switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => null,
        };
    }

    fn parseStrInner(p: *Parser, start_src: u32) void {
        const start = p.here();
        p.postString(p.parseStrInner_returnLastSegment(true));
        p.postAtom(.srcloc, start_src);
        p.wrapExpr(.string, start.node);
    }
    fn parseStrInner_returnLastSegment(p: *Parser, allow_paren_escape: bool) StringMapKey {
        var str = p.stringBegin();
        while (true) switch (p.tokenizer.token) {
            .string => {
                const txt = p.tokenizer.slice();
                p.assertEatToken(.string, .inside_string);
                str.appendSlice(txt);
            },
            // maybe instead of string_backslash we could have:
            // - escape_hex: '\xNN'
            // - escape_unicode: '\u{NNNN}'
            // - escape_backslash: '\\'
            // - escape_double_quote: '\"'
            // - escape_n: '\n',
            // - escape_r: '\r',
            // - escape_invalid: '\' : tokenizer marks an error and we just treat it as a strseg
            .string_backslash => {
                // string escape. tokenizer doesn't support this so here's a mess:
                p.tokenizer.token_start_srcloc = p.tokenizer.token_end_srcloc;
                const rem = p.tokenizer.source[p.tokenizer.token_start_srcloc..];
                if (rem.len > 0 and rem[0] == '(' and allow_paren_escape) {
                    p.tokenizer.next(.root);
                    std.debug.assert(p.tokenizer.token == .lparen);
                    p.postString(str.end());
                    std.debug.assert(p.tryParseExpr());
                    str = p.stringBegin();
                } else {
                    p.tokenizer.next(.inside_string);
                    switch (p.tokenizer.token) {
                        .string => {
                            @panic("TODO impl string x, u, r, n escapes");
                            // and indicate '(' is not allowed here if needed
                        },
                        .string_backslash => {
                            p.tokenizer.next(.inside_string);
                            str.append('\\');
                        },
                        .double_quote => {
                            p.tokenizer.next(.inside_string);
                            str.append('"');
                        },
                        .eof => {
                            // oop
                            break; // error handled outside of parseStrInner
                        },
                        else => unreachable,
                    }
                }
            },
            .double_quote, .eof => break,
            else => |a| std.debug.panic("unreachable: {s}", .{@tagName(a)}),
        };
        return str.end();
    }
    fn stringBegin(p: *Parser) StringBuilder {
        std.debug.assert(!p.string_active);
        p.string_active = true;
        return .{
            .p = p,
            .start = @intCast(p.strings.items.len),
        };
    }
    const StringBuilder = struct {
        p: *Parser,
        start: u32,

        // the first appendSlice could save txt to prevent an unnecessary copy
        // then if there's another one or a print(), commit it
        fn appendSlice(str: *StringBuilder, txt: []const u8) void {
            std.debug.assert(str.p.string_active);
            str.p.strings.appendSlice(str.p.gpa, txt) catch str.p.oom();
        }
        fn append(str: *StringBuilder, byte: u8) void {
            std.debug.assert(str.p.string_active);
            str.p.strings.append(str.p.gpa, byte) catch str.p.oom();
        }
        fn print(str: *StringBuilder, comptime fmt: []const u8, args: anytype) void {
            std.debug.assert(str.p.string_active);
            str.p.strings.writer(str.p.gpa).print(fmt, args) catch str.p.oom();
        }
        fn discard(str: *StringBuilder) void {
            std.debug.assert(str.p.string_active);
            str.p.strings.items.len = str.start;
            str.p.string_active = false;
            str.* = undefined;
        }
        fn end(str: *StringBuilder) StringMapKey {
            std.debug.assert(str.p.string_active);
            const res: StringMapKey = .{
                .offset = str.start,
                .len = @intCast(str.p.strings.items.len - str.start),
            };
            const gpres = str.p.seen_strings.getOrPutContext(str.p.gpa, res, .{ .strings_buf = str.p.strings.items }) catch {
                str.p.oom();
                str.discard();
                return .{ .offset = 0, .len = 0 };
            };
            if (gpres.found_existing) {
                // already exists. discard the new value
                str.p.strings.items.len = str.start;
            }
            str.p.string_active = false;
            str.* = undefined;
            return gpres.key_ptr.*;
        }
    };
    fn postString(p: *Parser, str_data: StringMapKey) void {
        p.postAtom(.string_offset, str_data.offset);
        p.postAtom(.string_len, str_data.len);
    }
    fn tryParseIdent(p: *Parser) ?StringMapKey {
        const tok_txt = p.tokenizer.slice();
        if (!p.tryEatToken(.identifier, .root)) {
            p.tokenizer.in_string = true;
            defer p.tokenizer.in_string = false;
            if (p.tryEatToken(.string_identifier_start, .inside_string)) {
                const last_seg = p.parseStrInner_returnLastSegment(false);
                if (!p.tryEatToken(.double_quote, .root)) {
                    // we're not really supposed to post an error in a random place like this
                    // this should be added to the error list instead
                    p.wrapErr(p.here().node, p.here().src, "Expected \" to end string identifier, found {s}", .{p.tokenizer.token.name()});
                }
                return last_seg;
            }
            return null;
        }
        var str = p.stringBegin();
        str.appendSlice(tok_txt);
        return str.end();
    }
    fn tryParseExprFinal(p: *Parser) bool {
        const start = p.here();
        switch (p.tokenizer.token) {
            .double_quote => {
                p.tokenizer.in_string = true;
                defer p.tokenizer.in_string = false;
                p.assertEatToken(.double_quote, .inside_string);
                p.parseStrInner(start.src);
                if (!p.tryEatToken(.double_quote, .root)) {
                    p.wrapErr(start.node, p.here().src, "Expected \" to end string, found {s}", .{p.tokenizer.token.name()});
                }
                return true;
            },
            .lparen => {
                p.assertEatToken(.lparen, .root);

                _ = p.tryEatWhitespace();
                while (p.tryParseCodeExpr()) {
                    _ = p.tryEatWhitespace();
                    if (!p.tryEatToken(.sep, .root)) break;
                    _ = p.tryEatWhitespace();
                }

                p.postAtom(.srcloc, start.src);
                if (!p.tryEatToken(.rparen, .root)) {
                    p.wrapErr(start.node, p.here().src, "Expected ')' to end code block", .{});
                }
                p.wrapExpr(.code, start.node);
                return true;
            },
            else => {
                if (p.tryParseIdent()) |ident| {
                    p.postAtom(.srcloc, start.src);
                    p.postString(ident);
                    p.wrapExpr(.ref, start.node);
                    return true;
                }
                return false; // no expr
            },
        }
    }
    fn tryParseExprWithSuffixes(p: *Parser) bool {
        const start = p.here();
        if (!p.tryParseExprFinal()) {
            if (p.tokenizer.token == .dot) {
                // continue to suffix parsing
                p.wrapExpr(.slot, start.node);
            } else {
                return false;
            }
        }
        while (true) {
            _ = p.tryEatWhitespace();
            switch (p.tokenizer.token) {
                .colon => {
                    p.postAtom(.srcloc, p.here().src);
                    p.assertEatToken(.colon, .root);
                    _ = p.tryEatWhitespace(); // (maybe error if no whitespace?)
                    if (p.tryParseExpr()) {
                        p.wrapExpr(.call, start.node);
                        break;
                    } else {
                        p.wrapErr(start.node, p.here().src, "Expected expr after ':'", .{});
                        break;
                    }
                },
                .dot => {
                    p.postAtom(.srcloc, p.here().src);
                    p.assertEatToken(.dot, .root);
                    _ = p.tryEatWhitespace();
                    const afterdot = p.here();
                    if (!p.tryParseExprFinal()) {
                        p.wrapErr(p.here().node, p.here().src, "Expected expr after '.'", .{});
                    }
                    p.ensureExprValidAccessor(afterdot);
                    p.wrapExpr(.access, start.node);
                    continue;
                },
                else => break,
            }
        }
        return true;
    }
    fn ensureExprValidAccessor(p: *Parser, start: Here) void {
        var err = AstNode.Tag.err;
        const last_posted_expr = if (p.out_nodes.len > 0) &p.out_nodes.items(.tag)[p.out_nodes.len - 1] else &err;
        switch (last_posted_expr.*) {
            .ref => {
                // change to 'key'
                last_posted_expr.* = .key;
            },
            else => |t| {
                p.wrapErr(start.node, start.src, "Invalid expr type for access: {s}", .{@tagName(t)});
            },
        }
    }
    fn ensureValidDeclLhs(p: *Parser, start: Here) void {
        var err = AstNode.Tag.err;
        const last_posted_expr = if (p.out_nodes.len > 0) &p.out_nodes.items(.tag)[p.out_nodes.len - 1] else &err;
        switch (last_posted_expr.*) {
            .ref => {
                // ok
            },
            else => |t| {
                p.wrapErr(start.node, start.src, "Invalid expr type for decl ref: {s}", .{@tagName(t)});
            },
        }
    }
    fn tryParseExpr(p: *Parser) bool {
        return p.tryParseExprWithSuffixes();
    }
    fn tryParseCodeOrMapExpr(p: *Parser, mode: enum { code, map }) bool {
        const begin = p.here();

        switch (p.tokenizer.token) {
            .kw_defer => {
                p.assertEatToken(.kw_defer, .root);
                _ = p.tryEatWhitespace();
                if (!p.tryParseExpr()) {
                    p.wrapErr(begin.node, begin.src, "expected expression after 'defer'", .{});
                }
                p.postAtom(.srcloc, begin.src);
                p.wrapExpr(.defer_expr, begin.node);
                if (mode != .code) {
                    p.wrapErr(begin.node, begin.src, "defer is not allowed here", .{});
                }

                return true;
            },
            else => {},
        }

        if (!p.tryParseExpr()) return false;
        _ = p.tryEatWhitespace();
        const eql_loc = p.here();
        switch (p.tokenizer.token) {
            .equals, .colon_equals => |t| {
                p.assertEatToken(t, .root);
                p.postAtom(.srcloc, eql_loc.src);
                _ = p.tryEatWhitespace();
                if (!p.tryParseExpr()) {
                    p.wrapErr(p.here().node, p.here().src, "Expected expr here", .{});
                }
                p.wrapExpr(switch (t) {
                    .colon_equals => .bind,
                    else => switch (mode) {
                        .code => .code_eql,
                        .map => .map_entry,
                    },
                }, begin.node);
                return true;
            },
            else => return true,
        }
    }
    fn tryParseCodeExpr(p: *Parser) bool {
        return p.tryParseCodeOrMapExpr(.code);
    }
    fn tryParseMapExpr(p: *Parser) bool {
        return p.tryParseCodeOrMapExpr(.map);
    }
    fn assertEatToken(p: *Parser, token: Token, next: Tokenizer.State) void {
        std.debug.assert(p.tokenizer.token == token);
        p.tokenizer.next(next);
    }
    fn tryEatToken(p: *Parser, token: Token, next: Tokenizer.State) bool {
        if (p.tokenizer.token == token) {
            p.assertEatToken(token, next);
            return true;
        }
        return false;
    }
    fn tryEatWhitespace(p: *Parser) bool {
        var success = false;
        while (p.tokenizer.token == .whitespace_inline or p.tokenizer.token == .whitespace_newline or p.tokenizer.token == .inline_comment) {
            success = true;
            p.tokenizer.next(.root);
        }
        return success;
    }
    fn parseMapContents(p: *Parser, start_src: u32) void {
        const start = p.here();
        p.postAtom(.srcloc, start_src);

        _ = p.tryEatWhitespace();
        while (p.tryParseMapExpr()) {
            _ = p.tryEatWhitespace();
            if (!p.tryEatToken(.sep, .root)) break;
            _ = p.tryEatWhitespace();
        }

        p.wrapExpr(.map, start.node);
    }
    fn parseFile(p: *Parser) void {
        const start = p.here();
        p.parseMapContents(start.src);
    }
};

fn testParser(out: *std.ArrayList(u8), opt: struct { no_lines: bool = false }, src_in: []const u8) ![]const u8 {
    const gpa = out.allocator;
    var src = std.ArrayList(u8).init(gpa);
    defer src.deinit();
    var positions = std.ArrayList(u32).init(gpa);
    defer positions.deinit();
    if (!opt.no_lines) {
        var src_rem = src_in;
        while (src_rem.len > 0) {
            const next = std.mem.indexOfScalar(u8, src_rem, '|') orelse src_rem.len;
            try src.appendSlice(src_rem[0..next]);
            src_rem = src_rem[next..];
            if (src_rem.len > 0) {
                std.debug.assert(src_rem[0] == '|');
                try positions.append(@intCast(src.items.len));
                src_rem = src_rem[1..];
            }
        }
    } else {
        try src.appendSlice(src_in);
    }

    const sample_src = src.items;
    var p = Parser.init(sample_src, gpa);
    defer p.deinit();
    const start = p.here();
    p.parseFile();
    if (p.tokenizer.token_start_srcloc < p.tokenizer.source.len) {
        p.wrapErr(start.node, p.tokenizer.token_start_srcloc, "Unexpected token: {s}", .{p.tokenizer.token.name()});
    }
    if (p.tokenizer.has_error) |tkz_err| switch (tkz_err.msg) {
        .newline_not_allowed_in_string => p.wrapErr(start.node, tkz_err.pos, "Newline not allowed inside string", .{}),
        .invalid_identifier => p.wrapErr(start.node, tkz_err.pos, "Invalid identifier", .{}),
        .invalid_byte => if (tkz_err.byte >= ' ' and tkz_err.byte < 0x7F) {
            p.wrapErr(start.node, tkz_err.pos, "Invalid character: '{'}'", .{std.zig.fmtEscapes(&.{tkz_err.byte})});
        } else if (tkz_err.byte >= 0x80) {
            p.wrapErr(start.node, tkz_err.pos, "Unicode characters are not allowed outside of strings", .{});
        } else {
            p.wrapErr(start.node, tkz_err.pos, "Invalid byte in file: 0x{X:0>2}", .{tkz_err.byte});
        },
    };
    // now serialize and test snapshot
    const tree: AstTree = .{ .tags = p.out_nodes.items(.tag), .values = p.out_nodes.items(.value), .string_buf = p.strings.items };
    if (p.out_nodes.len > 0 and p.has_fatal_error == null) {
        std.debug.assert(flipResult(@constCast(tree.tags), @constCast(tree.values), p.out_nodes.len - 1, 0) == p.out_nodes.len - 1);
    }

    var fmt_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer fmt_buf.deinit(gpa);

    if (p.has_fatal_error) |fe| {
        if (fe == .oom) return error.OutOfMemory;
        try fmt_buf.appendSlice(gpa, @tagName(fe));
    } else if (tree.tags.len > 0) {
        const node: AstExpr = .{ .idx = 0, .parent_end = @intCast(tree.tags.len) };
        const skip_outer = tree.tag(node) == .map;
        try dumpAst(&tree, node, fmt_buf.writer(gpa).any(), positions.items, skip_outer);
    }

    out.clearRetainingCapacity();
    try out.appendSlice(fmt_buf.items);
    return out.items;
}

const snap = @import("anywhere").util.testing.snap;
fn doTestParser(gpa: std.mem.Allocator) !void {
    var out = std.ArrayList(u8).init(gpa);
    defer out.deinit();
    try snap(@src(), "@0 [string \"Hello, world!\" @0]", try testParser(&out, .{}, "|\"Hello, world!\""));
    try snap(@src(), "@0 [err [err_skip [string \"Hello, world!\" @0]] @1 \"Expected \\\" to end string, found eof\"]", try testParser(&out, .{}, "|\"Hello, world!|"));
    try snap(@src(),
        \\[err [err_skip [map @0 [string "Hello, world!" @0]]] @1 "Invalid byte in file: 0x1B"]
    , try testParser(&out, .{}, "|\"Hello, world!|\x1b\""));
    try snap(@src(), "@0 [ref @0 \"abc\"]", try testParser(&out, .{}, "|abc"));
    try snap(@src(), "[err [err_skip [map @0 [ref @0 \"abc\"]]] @1 \"Unexpected token: rcurly\"]", try testParser(&out, .{}, "|abc|}"));
    try snap(@src(), "@0 [ref @1 \"abc\"] [ref @2 \"def\"] [ref @3 \"ghi\"]", try testParser(&out, .{}, "|  |abc, |def   ;|ghi "));
    try snap(@src(),
        \\@0 [call [access [access [ref @1 "std"] @2 [key @3 "math"]] @4 [key @5 "pow"]] @6 [string "abc" @7]]
    , try testParser(&out, .{}, "|  |std|.|math|.|pow|: |\"abc\" "));
    try snap(@src(),
        \\@0 [map_entry [access [slot] @1 [key @2 "key"]] @3 [ref @4 "value"]]
    , try testParser(&out, .{}, "|  |.|key |= |value "));
    // TODO: string escapes
    // try snap(@src(), "@0 [string \"\\x1b[3m\\xe1\\x88\\xb4\\\"\" @0]", try testParser(&out, .{}, "|\"\\x1b[3m\\u{1234}\\\"\""));
    try snap(@src(),
        \\@0 [string "hello " [code [ref @2 "user"] @1] "" @0]
    , try testParser(&out, .{},
        \\|"hello \|(|user)"
    ));
    try snap(@src(),
        \\[err [err_skip [map @0 [string "hello " [code [ref @2 "user"] @1] "" @0]]] @<9> "Newline not allowed inside string"]
    , try testParser(&out, .{},
        \\|"hello \|(
        \\  |user
        \\)"
    ));
    try snap(@src(),
        \\@0 [bind [ref @0 "builtin"] @1 [ref @2 "__builtin__"]]
    , try testParser(&out, .{}, "|builtin |:= |__builtin__"));
    try snap(@src(),
        \\@0 [call [code [call [access [slot] @1 [key @2 "implicit"]] @3 [access [slot] @4 [key @5 "arg1"]]] @0] @6 [access [slot] @7 [key @8 "arg2"]]]
    , try testParser(&out, .{}, "|(|.|implicit|: |.|arg1)|: |.|arg2"));
    try snap(@src(),
        \\@0 [code [defer_expr [ref @2 "error"] @1] @0]
    , try testParser(&out, .{}, "|(|#defer |error)"));
    try snap(@src(),
        \\@0 [access [ref @0 "my identifier"] @1 [key @2 "my field"]]
    , try testParser(&out, .{}, "|#\"my identifier\"|.|#\"my field\""));

    // extending a = b syntax
    // a = b defines a map_entry
    // in a struct definition we want to be able to define:
    // - fields, with a type and default value. field name is a 'key' (or a symbol for private fields)
    // - public decls, accessible with T.decl. field name is a 'key' or a symbol
    // - name bindings, accessible inside the struct with the name. field name is a 'var'
    // in a code, we want to be able to define:
    // - name binding decls, accessible within the code with the name.
    // - name binding non-decls

    // std.struct [  ]
}
test Parser {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, doTestParser, .{});
}
// fn fuzzParser(input: []const u8) anyerror!void {
//     try testParser(std.testing.allocator, .{}, input);
// }
// test "parser fuzz" {
//     try std.testing.fuzz(fuzzParser, .{});
// }

const StringMapKey = struct {
    offset: u32,
    len: u32,
};
pub const StringContext = struct {
    strings_buf: []const u8,

    pub fn hash(self: @This(), s: StringMapKey) u32 {
        return @as(u32, @truncate(std.hash.Wyhash.hash(0, self.strings_buf[s.offset..][0..s.len])));
    }
    pub fn eql(self: @This(), fetch_key: StringMapKey, item_key: StringMapKey, _: usize) bool {
        return std.mem.eql(u8, self.strings_buf[item_key.offset..][0..item_key.len], self.strings_buf[fetch_key.offset..][0..fetch_key.len]);
    }
};
