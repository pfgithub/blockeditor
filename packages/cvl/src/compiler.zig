const std = @import("std");
const src = @embedFile("tests/0.cvl");
const parser = @import("parser.zig");
const anywhere = @import("anywhere");

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
        pub const ty: Type = .{ .vtable = &vtable, .data = .from(void, &{}) };
        const vtable: Type.Vtable = autoVtable(Type.Vtable, @This());

        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.gpa, "type", .{});
        }
        fn access(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr, srcloc: parser.SrcLoc) Error!Expr {
            _ = slot;
            std.debug.assert(obj == .compiletime);
            _ = prop;

            return scope.env.addErrAsExpr(srcloc, "TODO access type", .{});
        }
    };
    const Builtin = struct {
        pub const ty: Type = .{ .vtable = &vtable, .data = .from(void, &{}) };
        const vtable: Type.Vtable = autoVtable(Type.Vtable, @This());

        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.gpa, "#builtin", .{});
        }
        fn access(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr, srcloc: parser.SrcLoc) Error!Expr {
            _ = slot;
            std.debug.assert(obj == .compiletime);
            const arg = try scope.handleExpr(.key, prop);
            if (scope.env.expectComptimeOrElse(arg)) |val| return val;
            return scope.env.addErrAsExpr(srcloc, "TODO access #bulitin", .{});
        }
    };
    const Err = struct {
        pub const ty: Type = .{ .vtable = &vtable, .data = .from(void, &{}) };
        const vtable: Type.Vtable = autoVtable(Type.Vtable, @This());

        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.gpa, "error", .{});
        }
        fn access(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr, srcloc: parser.SrcLoc) Error!Expr {
            _ = scope;
            _ = slot;
            _ = prop;
            return .{ .ty = .err, .value = obj, .srcloc = srcloc };
        }
        fn call(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type.Index, method: Expr.Value, arg: parser.AstExpr, srcloc: parser.SrcLoc) Error!Expr {
            _ = scope;
            _ = slot;
            _ = arg;
            return .{ .ty = .err, .value = method, .srcloc = srcloc };
        }
    };
    const Key = struct {
        pub const ComptimeValue = union(enum) {
            /// these are unique, there is only one decl with this string
            str: []const u8,
            symbol: struct {
                name: []const u8,
                ty: ?Type.Index,
            },
        };
    };
};

const Type = struct {
    vtable: *const Vtable,
    data: anywhere.util.AnyPtr,
    const Index = enum(u64) {
        basic_unknown,
        basic_void,
        err,
        basic_infer,
        ty,
        builtin,
        key,
        _,
    };
    const Vtable = struct {
        name: *const fn (self: anywhere.util.AnyPtr, env: *Env) Error![]const u8,
        access: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr, srcloc: parser.SrcLoc) Error!Expr = null,
        call: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type.Index, method: Expr.Value, arg: parser.AstExpr, srcloc: parser.SrcLoc) Error!Expr = null,
    };
    pub fn name(self: Type, env: *Env) Error![]const u8 {
        return self.vtable.name(self.data, env);
    }
    pub fn access(self: Type, scope: *Scope, slot: Type.Index, obj: Expr.Value, prop: parser.AstExpr, srcloc: parser.SrcLoc) Error!Expr {
        if (self.vtable.access == null) return scope.env.addErrAsExpr(scope.tree.src(prop), "Type '{s}' does not support access", .{try self.name(scope.env)});
        return self.vtable.access.?(self.data, scope, slot, obj, prop, srcloc);
    }
    pub fn call(self: Type, scope: *Scope, slot: Type.Index, method: Expr.Value, arg: parser.AstExpr, srcloc: parser.SrcLoc) Error!Expr {
        if (self.vtable.call == null) return scope.env.addErrAsExpr(scope.tree.src(arg), "Type '{s}' does not support call", .{try self.name(scope.env)});
        return self.vtable.access.?(self.data, scope, slot, method, arg, srcloc);
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
    resolved_value_ptr: ?anywhere.util.AnyPtr,
};
const Instr = struct {
    const Index = enum(u64) { _ };

    // args: []Instr.Index
    // next: Instr.Index
};
const Expr = struct {
    ty: Type.Index,
    value: Value,
    srcloc: parser.SrcLoc,
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
            .builtin => Types.Builtin.ty,
            else => @panic("TODO getType()"),
        };
    }
};
/// per-target
const Env = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    has_error: bool = false,
    decls: std.ArrayListUnmanaged(Decl),
    compiler_srclocs: std.ArrayListUnmanaged(std.builtin.SourceLocation),

    pub fn addErr(self: *Env, srcloc: parser.SrcLoc, comptime msg: []const u8, fmt: anytype) void {
        self.has_error = true;
        _ = srcloc;
        std.log.err("[compiler] " ++ msg, fmt);
    }
    pub fn addErrAsExpr(env: *Env, srcloc: parser.SrcLoc, comptime msg: []const u8, fmt: anytype) Expr {
        env.addErr(srcloc, msg, fmt);
        return .{
            .ty = .err,
            .value = .err,
            .srcloc = srcloc,
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
    pub fn srclocFromSrc(self: *Env, bsrc: std.builtin.SourceLocation) !parser.SrcLoc {
        const id: u32 = @intCast(self.compiler_srclocs.items.len);
        try self.compiler_srclocs.append(self.gpa, bsrc);
        return .{ .file_id = std.math.maxInt(u32), .offset = id };
    }
    pub fn declExpr(self: *Env, srcloc: parser.SrcLoc, decl: Decl.Index) Error!Expr {
        const resolved = self.resolveDeclType(decl);
        return .{
            .ty = resolved.resolved_type.?,
            .value = .{ .compiletime = decl },
            .srcloc = srcloc,
        };
    }
    pub fn resolveDeclType(self: *Env, decl: Decl.Index) Decl {
        const res = self.decls.items[@intFromEnum(decl)];
        if (res.resolved_type == null) @panic("TODO resolve resolved_type for decl");
        return res;
    }
    pub fn resolveDeclValue(self: *Env, decl: Decl.Index) Decl {
        const res = self.getDeclType(decl);
        if (res.resolved_value_ptr == null) @panic("TODO resolve value_ptr for decl");
        return res;
    }

    fn expectComptimeOrElse(self: *Env, expr: Expr) ?Expr {
        switch (expr.value) {
            .err => return expr,
            .runtime => return self.addErrAsExpr(expr.srcloc, "Expected a comptime value", .{}),
            .compiletime => return null,
        }
    }
};
// per-compiler invocation
const Global = struct {};
const Error = error{
    OutOfMemory,
};
inline fn handleExpr_inner2(scope: *Scope, slot: Type.Index, expr: parser.AstExpr) Error!Expr {
    const tree = scope.tree;
    const srcloc = tree.src(expr);
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
            return ty.call(scope, slot, method_expr.value, arg_ast, srcloc);
        },
        .access => {
            // a.b is equivalent to {%1 = {infer T}: a; T.access(a, b)}
            const obj_ast, const prop_ast = tree.children(expr, 2);

            // if we wanted, slot could be `{[infer T]: Slot}` then make prop slot T
            const obj_expr = try scope.handleExpr(scope.env.makeInfer(.basic_unknown), obj_ast);
            // get type.prop_type
            // call type.access(prop_expr)

            const ty = scope.getType(obj_expr.ty);
            return ty.access(scope, slot, obj_expr.value, prop_ast, srcloc);
        },
        .builtin => {
            _ = tree.children(expr, 0);
            // TODO: only add the decl once
            return scope.env.declExpr(srcloc, try scope.env.addDecl(.{
                .srcloc = try scope.env.srclocFromSrc(@src()), // TODO: use Types.Builtin's srcloc

                .dependencies = &.{},
                .resolved_type = .builtin,
                .resolved_value_ptr = .from(void, &{}),
            }));
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
        .key => {
            const offset, const len = tree.children(expr, 2);
            const str = tree.readStr(offset, len);
            // TODO: only have one decl per unique comptime_key.
            // thay way symbols can also be comptime_keys (although they also want to have type info)
            // and comparison is '=='

            const resolved_value_ptr = try scope.env.arena.create(Types.Key.ComptimeValue);
            resolved_value_ptr.* = .{ .str = str };
            return scope.env.declExpr(srcloc, try scope.env.addDecl(.{
                .srcloc = try scope.env.srclocFromSrc(@src()), // not sure what to use for this srcloc if we will have one per key
                .dependencies = &.{},
                .resolved_type = .key,
                .resolved_value_ptr = .from(Types.Key.ComptimeValue, resolved_value_ptr),
            }));
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

    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();
    var env: Env = .{
        .gpa = gpa,
        .arena = arena_backing.allocator(),
        .decls = .empty,
        .compiler_srclocs = .empty,
    };
    defer env.decls.deinit(env.gpa);
    defer env.compiler_srclocs.deinit(env.gpa);
    var scope: Scope = .{
        .env = &env,
        .tree = &tree,
    };
    const res = try scope.handleExpr(env.makeInfer(.basic_unknown), fn_body);
    _ = res;
}
