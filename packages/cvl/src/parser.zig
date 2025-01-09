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

fn printAstRaw(tags: []const AstNode.Tag, values: []const AstNode.Value, w: std.io.AnyWriter) !void {
    for (tags, values) |tag, value| {
        try w.print("[{s} {x}]", .{ @tagName(tag), if (tag.isAtom()) value.atom_value else value.expr_len });
    }
}
fn orderU32(context: u32, item: u32) std.math.Order {
    return std.math.order(context, item);
}

fn printAst(tree: *const AstTree, root: AstExpr, w: std.io.AnyWriter, positions: []const u32) !void {
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
    try w.print("[{s}", .{@tagName(tree.tag(root))});
    switch (tree.isAtom(root)) {
        true => {
            try w.print(" 0x{X}", .{tree.atomValue(root)});
        },
        false => {
            var fch = tree.firstChild(root);
            while (fch) |ch| {
                // string printing
                switch (tree.tag(ch)) {
                    .string_offset => {
                        // print string
                        const str_offset = tree.atomValue(ch);
                        fch = tree.next(ch);
                        std.debug.assert(fch != null);
                        std.debug.assert(tree.tag(fch.?) == .string_len);
                        const str_len = tree.atomValue(fch.?);
                        try w.print(" \"{}\"", .{std.zig.fmtEscapes(tree.string_buf[str_offset..][0..str_len])});
                    },
                    else => {
                        // default handling
                        try w.print(" ", .{});
                        try printAst(tree, ch, w, positions);
                    },
                }
                fch = tree.next(fch.?);
            }
        },
    }
    try w.print("]", .{});
}

const AstNode = struct {
    const Tag = enum(u8) {
        // expr
        map, // [a, b, c]
        decl, // #a b : [decl a b]
        code, // {a; b; c} : [code [a] [b] [c]] ||| {a; b;} : [code [a] [b] [void]]
        builtin_std, // [builtin_std]
        map_entry, // "a": "b" : [map_entry [string "a"] [string "b"]]
        string, // [string [string_offset string_len]]
        call, // a b : [call [a] [b]]
        err, // [err [...extra junk string_offset string_len]]
        err_skip, // ignore the contents of this
        ref,

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
                    @panic("todo parse escape sequence");
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
        p.postAtom(.srcloc, start_src);
        p.postString(str.end());
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
    fn tryParseExpr(p: *Parser) bool {
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

                p.postAtom(.srcloc, start.src);
                p.postString(str_val);
                p.wrapExpr(.ref, start.node);
                return true;
            },
            else => {
                return false; // no expr
            },
        }
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
        while (p.tryParseExpr()) {
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

fn testParser(gpa: std.mem.Allocator, val: ?[]const u8, src_in: []const u8) !void {
    var src = std.ArrayList(u8).init(gpa);
    defer src.deinit();
    var positions = std.ArrayList(u32).init(gpa);
    defer positions.deinit();
    if (val != null) {
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
        try printAst(&tree, .{ .idx = 0, .parent_end = @intCast(tree.tags.len) }, fmt_buf.writer(gpa).any(), positions.items);
    }
    if (val == null) return; // fuzz
    try std.testing.expectEqualStrings(val.?, fmt_buf.items);
}

fn doTestParser(gpa: std.mem.Allocator) !void {
    try testParser(gpa, "[map @0 [string @0 \"Hello, world!\"]]", "|\"Hello, world!\"");
    try testParser(gpa, "[map @0 [err [err_skip [string @0 \"Hello, world!\"]] @1 \"Expected \\\" to end string\"]]", "|\"Hello, world!|");
    try testParser(gpa, "[map @0 [err [err_skip] @1 \"String literal cannot contain byte '0x1b'\"]]", "|\"Hello, world!|\x1b\"");
    try testParser(gpa, "[map @0 [ref @0 \"abc\"]]", "|abc");
    try testParser(gpa, "[err [err_skip [map @0 [ref @0 \"abc\"]]] @1 \"More remaining\"]", "|abc|}");
    try testParser(gpa, "[map @0 [ref @1 \"abc\"] [ref @2 \"def\"] [ref @3 \"ghi\"]]", "|  |abc, |def   ;|ghi ");
}
fn fuzzParser(input: []const u8) anyerror!void {
    try testParser(std.testing.allocator, null, input);
}
test Parser {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, doTestParser, .{});
}
test "parser fuzz" {
    try std.testing.fuzz(fuzzParser, .{});
}

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
