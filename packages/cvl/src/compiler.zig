const std = @import("std");
const src = @embedFile("tests/0.cvl");
const parser = @import("parser.zig");

const Type = struct {
    const Index = enum(u64) {
        basic_unknown,
        basic_void,
        err,
        basic_infer,
        ty,
        _,
    };
};
const BasicBlock = struct {
    arg_types: []Type.Index,
};
const Decl = struct {
    const Index = enum(u64) {
        none = std.math.maxInt(u64),
        _,
    };

    dependencies: []Decl.Index,
    srcloc: parser.SrcLoc,

    resolved_type: ?Type.Index,
    resolved_value_ptr: ?*const anyopaque,
};
const Instr = struct {
    const Index = enum(u64) { _ };

    // args: []Instr.Index
    // next: Instr.Index
};
const Expr = struct {
    ty: Type.Index,
    value: union(enum) {
        compiletime: Decl.Index,
        runtime: Instr.Index,
        err,
    },
};

/// per-scope
const Scope = struct {
    env: *Env,

    fn handleExpr(scope: *Scope, slot: Type.Index, tree: *const parser.AstTree, expr: parser.AstExpr) Error!Expr {
        return handleExpr_inner2(scope, slot, tree, expr);
    }
};
/// per-target
const Env = struct {
    gpa: std.mem.Allocator,
    has_error: bool = false,
    decls: std.ArrayListUnmanaged(Decl),

    pub fn addErr(self: *Env, srcloc: parser.SrcLoc, comptime msg: []const u8, fmt: anytype) void {
        self.has_error = true;
        _ = srcloc;
        std.log.err("[compiler] " ++ msg, fmt);
    }
    pub fn addErrAsExpr(env: *Env, srcloc: parser.SrcLoc, comptime msg: []const u8, fmt: anytype) Expr {
        env.addErr(srcloc, msg, fmt);
        return .{
            .ty = .err,
            .value = .{ .compiletime = .none },
        };
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
    pub fn addDecl(self: *Env, decl: Decl) Error!Decl.Index {
        const res = self.decls.items.len;
        try self.decls.append(self.gpa, decl);
        return @enumFromInt(res);
    }
};
const Error = error{
    OutOfMemory,
};
inline fn handleExpr_inner2(scope: *Scope, slot: Type.Index, tree: *const parser.AstTree, expr: parser.AstExpr) Error!Expr {
    switch (tree.tag(expr)) {
        .call => {
            // a: b is equivalent to {%1 = {infer T}: a; T.call(a, b)}
            const method_ast, const arg_ast = tree.children(expr, 2);
            _ = arg_ast;

            // if we wanted to, we could pass the slot as:
            // `(arg: infer T) => Slot`, then make the arg slot T
            const method_expr = try scope.handleExpr(scope.env.makeInfer(.basic_unknown), tree, method_ast);
            // now get type.arg_type
            // then call type.call(arg_expr)
            _ = method_expr;
            return scope.env.addErrAsExpr(tree.src(expr), "TODO call expr", .{});
        },
        .access => {
            // a.b is equivalent to {%1 = {infer T}: a; T.access(a, b)}
            const obj_ast, const prop_ast = tree.children(expr, 2);

            // if we wanted, slot could be `{[infer T]: Slot}` then make prop slot T
            const obj_expr = try scope.handleExpr(scope.env.makeInfer(.basic_unknown), tree, obj_ast);
            // get type.prop_type
            // call type.access(prop_expr)
            _ = obj_expr;
            _ = prop_ast;
            return scope.env.addErrAsExpr(tree.src(expr), "TODO access expr", .{});
        },
        .builtin => {
            _ = tree.children(expr, 0);
            return .{
                .ty = .ty,
                .value = .{ .compiletime = try scope.env.addDecl(.{
                    .srcloc = tree.src(expr),

                    .dependencies = &.{},
                    .resolved_type = .ty,
                    .resolved_value_ptr = @ptrFromInt(1),
                }) },
            };
        },
        .code => {
            // handle each expr in sequence
            var child = tree.firstChild(expr);
            while (child) |c| {
                const next = tree.next(c).?;
                const is_last = tree.tag(next) == .srcloc;

                if (is_last) return scope.handleExpr(slot, tree, c);
                _ = try scope.handleExpr(.basic_void, tree, c);

                child = next;
            }
            unreachable; // there is always at least one expr in a code
        },
        else => |t| return scope.env.addErrAsExpr(tree.src(expr), "TODO expr: {s}", .{@tagName(t)}),
    }
}

test "compiler" {
    if (true) return error.SkipZigTest;

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

    var env: Env = .{
        .gpa = gpa,
        .decls = .empty,
    };
    defer env.decls.deinit(env.gpa);
    var scope: Scope = .{
        .env = &env,
    };
    const res = try scope.handleExpr(env.makeInfer(.basic_unknown), &tree, fn_body);
    _ = res;
}
