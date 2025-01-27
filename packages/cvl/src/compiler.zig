const std = @import("std");
const src = @embedFile("tests/0.cvl");
const parser = @import("parser.zig");

const Type = struct {
    const Index = enum(u64) {
        basic_unknown,
        basic_void,
        basic_err,
        basic_infer,
        _,
    };
};
const BasicBlock = struct {
    arg_types: []Type.Index,
};
const Decl = struct {
    const Index = enum(u64) { _ };
};
const Instr = struct {
    const Index = enum(u64) { _ };
};
const Expr = struct {
    ty: Type.Index,
    value: union(enum) {
        compiletime: Decl.Index,
        runtime: Instr.Index,
        err,
    },
};

const Env = struct {
    has_error: bool = false,
    pub fn err(self: *Env, srcloc: parser.SrcLoc, comptime msg: []const u8, fmt: anytype) ExprError {
        self.has_error = true;
        _ = srcloc;
        std.log.err("[compiler] " ++ msg, fmt);
        return ExprError.ContainsError;
    }

    pub fn makeInfer(self: *Env, child: Type.Index) Type.Index {
        _ = self;
        _ = child;
        return .basic_infer;
    }
    pub fn readInfer(self: *Env, infer_idx: Type.Index) ?Type.Index {
        _ = self;
        _ = infer_idx;
        @panic("TODO");
    }
};
const ExprError = error{
    ContainsError,
};
fn handleExpr(env: *Env, slot: Type.Index, tree: *const parser.AstTree, expr: parser.AstExpr) ExprError!Expr {
    return handleExpr_inner2(env, slot, tree, expr);
}
inline fn handleExpr_inner2(env: *Env, slot: Type.Index, tree: *const parser.AstTree, expr: parser.AstExpr) ExprError!Expr {
    switch (tree.tag(expr)) {
        .call => {
            const method_ast = tree.firstChild(expr).?;
            const arg_ast = tree.next(method_ast).?;
            std.debug.assert(tree.tag(tree.next(arg_ast)) == .srcloc);

            // if we wanted to, we could pass the slot as:
            // `(arg: infer T) => slot`, then make the arg slot T
            const method_expr = handleExpr(env, env.makeInfer(.basic_unknown), tree, method_ast);
            // now get type.arg_type
            // then call type.call(arg_expr)
            _ = method_expr;
        },
        .code => {
            // handle each expr in sequence
            var child = tree.firstChild(expr);
            while (child) |c| {
                const next = tree.next(c).?;
                const is_last = tree.tag(next) == .srcloc;

                if (is_last) return handleExpr(env, slot, tree, c);
                _ = try handleExpr(env, .basic_void, tree, c);

                child = next;
            }
            unreachable; // there is always at least one expr in a code
        },
        else => |t| return env.err(tree.src(expr), "TODO expr: {s}", .{@tagName(t)}),
    }
}

test "compiler" {
    const gpa = std.testing.allocator;
    var tree = parser.parse(gpa, src);
    defer tree.deinit();
    try std.testing.expect(!tree.owner.has_errors);

    // it is parsed. now handle the root file decl
    const root = tree.root();
    const first_decl = tree.firstChild(root).?;
    const fn_def = tree.next(tree.firstChild(first_decl).?).?;
    const fn_body = tree.next(tree.firstChild(fn_def).?).?;
    // std.log.err("val: {s}", .{@tagName(tree.tag(fn_body))});
    // it's a code expr

    var env: Env = .{};
    _ = try handleExpr(&env, env.makeInfer(.basic_unknown), &tree, fn_body);
}
