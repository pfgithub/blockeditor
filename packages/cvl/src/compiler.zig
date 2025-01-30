const std = @import("std");
const src = @embedFile("tests/0.cvl");
const parser = @import("parser.zig");

fn autoVtable(comptime Vtable: type, comptime Src: type) Vtable {
    var res: Vtable = undefined;
    for (@typeInfo(Vtable).@"struct".fields) |field| {
        if (@hasDecl(Src, field.name)) {
            @field(res, field.name) = &@field(Src, field.name);
        } else if (field.default_value) |default_v| {
            @field(res, field.name) = @as(*const field.type, @alignCast(@ptrCast(default_v))).*;
        } else {
            @compileError("vtable missing required field: " ++ field.name);
        }
    }
    return res;
}

const Types = struct {
    const Ty = struct {
        pub const ty: Type = .{ .vtable = &vtable, .data = null };
        const vtable: Type.Vtable = autoVtable(Type.Vtable, @This());

        fn name(_: ?*const anyopaque, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.gpa, "type", .{});
        }
        fn access(_: ?*const anyopaque, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr) Error!Expr {
            _ = obj;
            _ = slot;
            return scope.env.addErrAsExpr(scope.tree.src(prop), "TODO access type", .{});
        }
    };
    const Err = struct {
        pub const ty: Type = .{ .vtable = &vtable, .data = null };
        const vtable: Type.Vtable = autoVtable(Type.Vtable, @This());

        fn name(_: ?*const anyopaque, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.gpa, "error", .{});
        }
        fn access(_: ?*const anyopaque, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr) Error!Expr {
            _ = scope;
            _ = slot;
            _ = prop;
            return .{ .ty = .err, .value = obj };
        }
        fn call(_: ?*const anyopaque, scope: *Scope, slot: Type.Index, method: Expr.Value, arg: parser.AstExpr) Error!Expr {
            _ = scope;
            _ = slot;
            _ = arg;
            return .{ .ty = .err, .value = method };
        }
    };
};

const Type = struct {
    vtable: *const Vtable,
    data: ?*const anyopaque,
    const Index = enum(u64) {
        basic_unknown,
        basic_void,
        err,
        basic_infer,
        ty,
        _,
    };
    const Vtable = struct {
        name: *const fn (self: ?*const anyopaque, env: *Env) Error![]const u8,
        access: ?*const fn (self: ?*const anyopaque, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr) Error!Expr = null,
        call: ?*const fn (self: ?*const anyopaque, scope: *Scope, slot: Type.Index, method: Expr.Value, arg: parser.AstExpr) Error!Expr = null,
    };
    pub fn name(self: Type, env: *Env) Error![]const u8 {
        return self.vtable.name(self.data, env);
    }
    pub fn access(self: Type, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr) Error!Expr {
        if (self.vtable.access == null) return scope.env.addErrAsExpr(scope.tree.src(prop), "Type '{s}' does not support access", .{try self.name(scope.env)});
        return self.vtable.access.?(self.data, scope, slot, obj, prop);
    }
    pub fn call(self: Type, scope: *Scope, slot: Type.Index, method: Expr.Value, arg: parser.AstExpr) Error!Expr {
        if (self.vtable.call == null) return scope.env.addErrAsExpr(scope.tree.src(arg), "Type '{s}' does not support call", .{try self.name(scope.env)});
        return self.vtable.access.?(self.data, scope, slot, method, arg);
    }
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
    value: Value,
    const Value = union(enum) {
        compiletime: Decl.Index,
        runtime: Instr.Index,
        err,
    };
};

/// per-scope
const Scope = struct {
    env: *Env,
    tree: *const parser.AstTree,

    fn handleExpr(scope: *Scope, slot: Type.Index, expr: parser.AstExpr) Error!Expr {
        return handleExpr_inner2(scope, slot, expr);
    }
    pub fn getType(scope: *Scope, ty: Type.Index) Type {
        _ = scope;
        return switch (ty) {
            .ty => Types.Ty.ty,
            .err => Types.Err.ty,
            else => @panic("TODO getType()"),
        };
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
inline fn handleExpr_inner2(scope: *Scope, slot: Type.Index, expr: parser.AstExpr) Error!Expr {
    const tree = scope.tree;
    switch (tree.tag(expr)) {
        .call => {
            // a: b is equivalent to {%1 = {infer T}: a; T.call(a, b)}
            const method_ast, const arg_ast = tree.children(expr, 2);

            // if we wanted to, we could pass the slot as:
            // `(arg: infer T) => Slot`, then make the arg slot T
            const method_expr = try scope.handleExpr(scope.env.makeInfer(.basic_unknown), method_ast);
            // now get type.arg_type
            // then call type.call(arg_expr)
            const ty = scope.getType(method_expr.ty);
            return ty.call(scope, slot, method_expr.value, arg_ast);
        },
        .access => {
            // a.b is equivalent to {%1 = {infer T}: a; T.access(a, b)}
            const obj_ast, const prop_ast = tree.children(expr, 2);

            // if we wanted, slot could be `{[infer T]: Slot}` then make prop slot T
            const obj_expr = try scope.handleExpr(scope.env.makeInfer(.basic_unknown), obj_ast);
            // get type.prop_type
            // call type.access(prop_expr)

            const ty = scope.getType(obj_expr.ty);
            return ty.access(scope, slot, obj_expr.value, prop_ast);
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

                if (is_last) return scope.handleExpr(slot, c);
                _ = try scope.handleExpr(.basic_void, c);

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
        .tree = &tree,
    };
    const res = try scope.handleExpr(env.makeInfer(.basic_unknown), fn_body);
    _ = res;
}
