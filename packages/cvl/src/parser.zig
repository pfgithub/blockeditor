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
        err, // [err [...extra junk string_offset string_len]]
        err_skip, // ignore the contents of this
        ref,
        access, // a.b.c => [access [access a @0 b] @1 c]
        key,

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
const Parser = struct {
    gpa: std.mem.Allocator,

    source: []const u8,
    srcloc: u32 = 0,
    out_nodes: std.MultiArrayList(AstNode) = .empty,
    seen_strings: std.ArrayHashMapUnmanaged(StringMapKey, void, StringContext, true) = .empty,
    strings: std.ArrayListUnmanaged(u8) = .empty,
    has_errors: bool = false,
    has_fatal_error: ?enum { oom, src_too_long } = null,
    string_active: bool = false,

    pub fn init(src: []const u8, gpa: std.mem.Allocator) Parser {
        if (src.len > std.math.maxInt(u32) - 1000) {
            return .{ .gpa = gpa, .source = "", .has_errors = true, .has_fatal_error = .oom };
        }
        return .{
            .gpa = gpa,
            .source = src,
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
        return .{ .src = p.srcloc, .node = p.out_nodes.len };
    }
    /// 0 is returned for eof, or if a null byte is encountered in the file
    fn peek(p: *Parser) u8 {
        const rem = p.remaining();
        if (rem.len == 0) return 0;
        return rem[0];
    }
    fn remaining(p: *Parser) []const u8 {
        return p.source[p.srcloc..];
    }
    fn eat(p: *Parser, target: []const u8) void {
        std.debug.assert(p.tryEat(target));
    }
    fn tryEat(p: *Parser, target: []const u8) bool {
        const rem = p.remaining();
        if (!std.mem.startsWith(u8, rem, target)) return false;
        p.srcloc += @intCast(target.len);
        return true;
    }
    fn asHex(c: u8) ?u4 {
        return switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => null,
        };
    }

    fn parseStrInner(p: *Parser, start_src: u32) void {
        var str = p.stringBegin();
        const start = p.here();
        var has_errored = false;
        while (true) {
            const rem = p.remaining();
            const next_interesting = for (rem, 0..) |c, i| {
                if (c == '\"') break i;
                if (c == '\\') break i;
                if (c < ' ') break i;
            } else rem.len;
            p.eat(rem[0..next_interesting]);
            if (!has_errored) str.appendSlice(rem[0..next_interesting]);
            switch (p.peek()) {
                '\"' => break,
                '\\' => {
                    p.eat("\\");
                    switch (p.peek()) {
                        'x' => blk: {
                            p.eat("x");
                            var h: [2]u8 = undefined;
                            for (&h) |*hv| {
                                const b1 = p.peek();
                                const h1 = asHex(b1);
                                if (h1 == null) {
                                    if (!has_errored) {
                                        str.discard();
                                        p.wrapErr(start.node, p.here().src, "Expected 0-9a-zA-Z in hex escape", .{});
                                        has_errored = true;
                                    }
                                    break :blk;
                                }
                                p.eat(&.{b1});
                                hv.* = h1.?;
                            }
                            if (!has_errored) str.append(h[0] << 4 | h[1]);
                        },
                        'u' => blk: {
                            const u_esc_src = p.here().src;
                            p.eat("u");
                            if (!p.tryEat("{")) {
                                if (!has_errored) {
                                    str.discard();
                                    p.wrapErr(start.node, p.here().src, "Expected \"\\u{{...}}\"", .{});
                                    has_errored = true;
                                }
                                break :blk;
                            }
                            var u: [6]u32 = undefined;
                            const len = for (&u, 0..) |*uv, i| {
                                const b1 = p.peek();
                                const h1 = asHex(b1);
                                if (h1 == null) break i;
                                p.eat(&.{b1});
                                uv.* = h1.?;
                            } else 6;
                            if (len == 0) {
                                if (!has_errored) {
                                    str.discard();
                                    p.wrapErr(start.node, p.here().src, "Expected at least one hex char inside unicode escape", .{});
                                    has_errored = true;
                                }
                                break :blk;
                            }
                            if (!p.tryEat("}")) {
                                if (!has_errored) {
                                    str.discard();
                                    p.wrapErr(start.node, p.here().src, "Expected '}}' to end unicode escape", .{});
                                    has_errored = true;
                                }
                                break :blk;
                            }
                            var dec: u32 = 0;
                            for (u[0..len]) |c| {
                                dec <<= 4;
                                dec |= c;
                            }
                            const casted: u21 = std.math.cast(u21, dec) orelse {
                                if (!has_errored) {
                                    str.discard();
                                    p.wrapErr(start.node, u_esc_src, "Invalid unicode codepoint: U+{X}", .{dec});
                                    has_errored = true;
                                }
                                break :blk;
                            };
                            var enc_res: [4]u8 = undefined;
                            const enc_len = std.unicode.utf8Encode(casted, &enc_res) catch |e| switch (e) {
                                error.Utf8CannotEncodeSurrogateHalf => {
                                    if (!has_errored) {
                                        str.discard();
                                        p.wrapErr(start.node, u_esc_src, "Surrogate half U+{X} is not allowed.", .{dec});
                                        has_errored = true;
                                    }
                                    break :blk;
                                },
                                error.CodepointTooLarge => {
                                    if (!has_errored) {
                                        str.discard();
                                        p.wrapErr(start.node, u_esc_src, "Invalid unicode codepoint: U+{X}", .{dec});
                                        has_errored = true;
                                    }
                                    break :blk;
                                },
                            };
                            if (!has_errored) str.appendSlice(enc_res[0..enc_len]);
                        },
                        '\"', '\\' => |c| {
                            p.eat(&.{c});
                            if (!has_errored) str.append(c);
                        },
                        '(' => {
                            if (!has_errored) p.postString(str.end());
                            std.debug.assert(p.tryParseExpr());
                            str = p.stringBegin();
                        },
                        else => |char| {
                            if (!has_errored) {
                                str.discard();
                                p.wrapErr(start.node, p.here().src, "Invalid escape char: \'{'}\'", .{std.zig.fmtEscapes(&.{char})});
                                has_errored = true;
                            }
                        },
                    }
                },
                '\n' => break,
                else => |c| {
                    if (p.remaining().len == 0) break;
                    // continue parsing the string but mark it as an error
                    const loc = p.here().src;
                    p.eat(&.{c});
                    if (!has_errored) {
                        str.discard();
                        p.wrapErr(start.node, loc, "String literal cannot contain byte '0x{x}'", .{c});
                    }
                    has_errored = true;
                },
            }
        }
        if (has_errored) return;
        p.postString(str.end());
        p.postAtom(.srcloc, start_src);
        p.wrapExpr(.string, start.node);
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
        switch (p.peek()) {
            'a'...'z', 'A'...'Z', '_' => {
                const rem = p.remaining();
                const next_interesting = for (rem, 0..) |c, i| switch (c) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                    else => break i,
                } else rem.len;
                var str = p.stringBegin();
                str.appendSlice(rem[0..next_interesting]);
                const str_val = str.end();
                p.eat(rem[0..next_interesting]);

                return str_val;
            },
            else => return null,
        }
    }
    fn tryParseExprFinal(p: *Parser) bool {
        const start = p.here();
        switch (p.peek()) {
            '"' => {
                p.eat("\"");
                p.parseStrInner(start.src);
                if (!p.tryEat("\"")) {
                    p.wrapErr(start.node, p.here().src, "Expected \" to end string", .{});
                    return true;
                }
                return true;
            },
            '(' => {
                p.eat("(");

                _ = p.tryEatWhitespace();
                while (p.tryParseMapExpr()) {
                    _ = p.tryEatWhitespace();
                    if (!p.tryEatComma()) break;
                    _ = p.tryEatWhitespace();
                }

                p.postAtom(.srcloc, start.src);
                if (!p.tryEat(")")) {
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
        if (!p.tryParseExprFinal()) return false;
        while (true) {
            _ = p.tryEatWhitespace();
            switch (p.peek()) {
                ':' => {
                    p.postAtom(.srcloc, p.here().src);
                    p.eat(":");
                    _ = p.tryEatWhitespace(); // (maybe error if no whitespace?)
                    if (p.tryParseExpr()) {
                        p.wrapExpr(.call, start.node);
                        break;
                    } else {
                        p.wrapErr(start.node, p.here().src, "Expected expr after ':'", .{});
                        break;
                    }
                },
                '.' => {
                    p.postAtom(.srcloc, p.here().src);
                    p.eat(".");
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
    fn tryParseExpr(p: *Parser) bool {
        return p.tryParseExprWithSuffixes();
    }
    fn tryParseCodeOrMapExpr(p: *Parser, mode: enum { code, map }) bool {
        const begin = p.here();

        switch (p.peek()) {
            '#' => {
                p.eat("#");
                _ = p.tryEatWhitespace();
                const ident_start = p.here();
                if (p.tryParseIdent()) |ident| {
                    p.postAtom(.srcloc, ident_start.src);
                    p.postString(ident);
                    p.wrapExpr(.ref, ident_start.node);
                } else {
                    p.wrapErr(ident_start.node, ident_start.src, "expected identifier after '#'", .{});
                }

                _ = p.tryEatWhitespace();

                if (!p.tryParseExpr()) {
                    p.wrapErr(p.here().node, p.here().src, "expected identifier after name", .{});
                }

                p.postAtom(.srcloc, begin.src);
                p.wrapExpr(.bind, begin.node);

                return true;
            },
            else => {},
        }

        if (!p.tryParseExpr()) return false;
        _ = p.tryEatWhitespace();
        const eql_loc = p.here();
        if (!p.tryEat("=")) return true;
        p.ensureExprValidAccessor(begin);
        p.postAtom(.srcloc, eql_loc.src);
        _ = p.tryEatWhitespace();
        if (!p.tryParseExpr()) {
            p.wrapErr(p.here().node, p.here().src, "Expected expr here", .{});
        }
        p.wrapExpr(switch (mode) {
            .code => .code_eql,
            .map => .map_entry,
        }, begin.node);
        return true;
    }
    fn tryParseCodeExpr(p: *Parser) bool {
        return p.tryParseCodeOrMapExpr(.code);
    }
    fn tryParseMapExpr(p: *Parser) bool {
        return p.tryParseCodeOrMapExpr(.map);
    }
    fn tryEatComma(p: *Parser) bool {
        if (p.tryEat(",")) return true;
        if (p.tryEat(";")) return true;
        return false;
    }
    fn tryEatWhitespace(p: *Parser) bool {
        const rem = p.remaining();
        const next_interesting = for (rem, 0..) |c, i| switch (c) {
            ' ', '\t', '\r', '\n' => {},
            else => break i,
        } else rem.len;
        p.eat(rem[0..next_interesting]);
        return next_interesting > 0;
    }
    fn parseMapContents(p: *Parser, start_src: u32) void {
        const start = p.here();
        p.postAtom(.srcloc, start_src);

        _ = p.tryEatWhitespace();
        while (p.tryParseMapExpr()) {
            _ = p.tryEatWhitespace();
            if (!p.tryEatComma()) break;
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
    if (p.srcloc < p.source.len) {
        p.wrapErr(start.node, p.srcloc, "More remaining", .{});
    }
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
    try snap(@src(), "@0 [err [err_skip [string \"Hello, world!\" @0]] @1 \"Expected \\\" to end string\"]", try testParser(&out, .{}, "|\"Hello, world!|"));
    try snap(@src(), "@0 [err [err_skip] @1 \"String literal cannot contain byte '0x1b'\"]", try testParser(&out, .{}, "|\"Hello, world!|\x1b\""));
    try snap(@src(), "@0 [ref @0 \"abc\"]", try testParser(&out, .{}, "|abc"));
    try snap(@src(), "[err [err_skip [map @0 [ref @0 \"abc\"]]] @1 \"More remaining\"]", try testParser(&out, .{}, "|abc|}"));
    try snap(@src(), "@0 [ref @1 \"abc\"] [ref @2 \"def\"] [ref @3 \"ghi\"]", try testParser(&out, .{}, "|  |abc, |def   ;|ghi "));
    try snap(@src(),
        \\@0 [call [access [access [ref @1 "std"] @2 [key @3 "math"]] @4 [key @5 "pow"]] @6 [string "abc" @7]]
    , try testParser(&out, .{}, "|  |std|.|math|.|pow|: |\"abc\" "));
    try snap(@src(),
        \\@0 [map_entry [key @1 "key"] @2 [ref @3 "value"]]
    , try testParser(&out, .{}, "|  |key |= |value "));
    try snap(@src(), "@0 [string \"\\x1b[3m\\xe1\\x88\\xb4\\\"\" @0]", try testParser(&out, .{}, "|\"\\x1b[3m\\u{1234}\\\"\""));
    try snap(@src(),
        \\@0 [string "hello " [code [ref @2 "user"] @1] "" @0]
    , try testParser(&out, .{},
        \\|"hello \|(|user)"
    ));
    try snap(@src(),
        \\@0 [bind [ref @1 "builtin"] [ref @2 "__builtin__"] @0]
    , try testParser(&out, .{}, "|#|builtin |__builtin__"));

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
