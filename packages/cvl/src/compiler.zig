const std = @import("std");
const example_src = @embedFile("tests/0.cvl");
const parser = @import("parser.zig");
const anywhere = @import("anywhere");
const SrcLoc = parser.SrcLoc;

fn autoVtable(comptime Vtable: type, comptime Src: type) *const Vtable {
    return comptime blk: {
        var res: Vtable = undefined;
        for (@typeInfo(Vtable).@"struct".fields) |field| {
            if (@hasDecl(Src, field.name)) {
                @field(res, field.name) = &@field(Src, field.name);
            } else if (field.default_value) |default_v| {
                @field(res, field.name) = @as(*const field.type, @alignCast(@ptrCast(default_v))).*;
            } else {
                @compileError("vtable for " ++ @typeName(Src) ++ " missing required field: " ++ field.name);
            }
        }
        const res_dupe = res;
        break :blk &res_dupe;
    };
}

const Types = struct {
    const Unknown = struct {
        pub const ty: Type = .from(@This(), &.{});
        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "unknown", .{});
        }
    };
    const Infer = struct {
        extends: Type,
        fn name(self_any: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            const self = self_any.toConst(Infer);
            return try std.fmt.allocPrint(env.arena, "infer({s})", .{try self.extends.name(env)});
        }
    };
    const Void = struct {
        pub const ComptimeValue = void;
        pub const ty: Type = .from(@This(), &.{});
        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "void", .{});
        }
    };
    const Ty = struct {
        pub const ComptimeValue = Type;
        pub const ty: Type = .from(@This(), &.{});

        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "type", .{});
        }
        fn access(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
            _ = slot;
            std.debug.assert(obj == .compiletime);
            _ = prop;

            return scope.env.addErr(srcloc, "TODO access type", .{});
        }
    };
    const Builtin = struct {
        pub const ty: Type = .from(@This(), &.{});

        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "#builtin", .{});
        }
        // for lsp, we need to provide a list of keys
        fn access(_: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
            _ = slot;
            std.debug.assert(obj.value == .compiletime);
            const arg = try scope.handleExpr(Types.Key.ty, prop);
            const ctk = try scope.env.expectComptimeKey(arg);
            if (ctk == try scope.env.comptimeKeyFromString("asm")) {
                // when we call a function, we know if we are calling at comptime or runtime.
                // so we can choose how to emit code based on that.
                // unlike the previous version, we won't ever return a value and then
                // execute it. instead, we always return a comptime value if we can
                // and insert at runtime if we can't.
                // still need to figure out the borders & moving from comptime to
                // runtime.
                return scope.env.castExpr(obj, .from(Types.Bound, try anywhere.util.dupeOne(scope.env.arena, Types.Bound{ .child = obj.ty, .ctk = try scope.env.comptimeKeyFromString("asm") })), srcloc);
            }
            return scope.env.addErr(srcloc, "TODO access #bulitin", .{});
        }
    };
    const Key = struct {
        pub const ty: Type = .from(@This(), &.{});
        fn name(_: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            return try std.fmt.allocPrint(env.arena, "key", .{});
        }

        // for strings <= 7 bytes long, we can store them directly in the u64
        // longer than 7 maybe they can go in a comptime array unless they're runtime
        pub const ComptimeValue = enum(u64) { _ };
        // pub const ComptimeValue = union(enum) {
        //     /// these are unique, there is only one decl with this string
        //     str: []const u8,
        //     symbol: struct {
        //         name: []const u8,
        //         ty: ?Type,
        //     },
        // };
    };
    const Bound = struct {
        child: Type,
        ctk: Types.Key.ComptimeValue,

        fn name(self_any: anywhere.util.AnyPtr, env: *Env) Error![]const u8 {
            const self = self_any.toConst(Bound);
            return try std.fmt.allocPrint(env.arena, "bound({s}, {s})", .{ try self.child.name(env), env.comptime_keys.items[@intFromEnum(self.ctk)].string });
        }
    };
};

const Type = struct {
    vtable: *const Vtable,
    data: anywhere.util.AnyPtr,
    const Vtable = struct {
        name: *const fn (self: anywhere.util.AnyPtr, env: *Env) Error![]const u8,
        access: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr = null,
        call: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, method: Expr, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr = null,
        /// used by bound_fn. this will be from a symbol key.
        bound_call: ?*const fn (self: anywhere.util.AnyPtr, scope: *Scope, slot: Type, method: Expr, binding: Types.Key.ComptimeValue, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr = null,
    };
    pub fn name(self: Type, env: *Env) Error![]const u8 {
        return self.vtable.name(self.data, env);
    }
    pub fn access(self: Type, scope: *Scope, slot: Type, obj: Expr, prop: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
        if (self.vtable.access == null) return scope.env.addErr(scope.tree.src(prop), "Type '{s}' does not support access", .{try self.name(scope.env)});
        return self.vtable.access.?(self.data, scope, slot, obj, prop, srcloc);
    }
    pub fn call(self: Type, scope: *Scope, slot: Type, method: Expr, arg: parser.AstExpr, srcloc: SrcLoc) Error!Expr {
        if (self.vtable.call == null) return scope.env.addErr(scope.tree.src(arg), "Type '{s}' does not support call", .{try self.name(scope.env)});
        return self.vtable.access.?(self.data, scope, slot, method, arg, srcloc);
    }
    pub fn from(comptime T: type, val: *const T) Type {
        return .{ .vtable = comptime autoVtable(Type.Vtable, T), .data = .from(T, val) };
    }
    pub fn is(self: Type, comptime T: type) bool {
        return self.vtable == comptime autoVtable(Type.Vtable, T);
    }
};
const BasicBlock = struct {
    arg_types: []Type,
};
const Decl = struct {
    const Index = enum(u64) {
        none = std.math.maxInt(u64),
        _,
    };

    dependencies: []Decl.Index,
    srcloc: SrcLoc,

    resolved_type: ?Type,
    resolved_value_ptr: ?anywhere.util.AnyPtr,
};
const Instr = struct {
    const Index = enum(u64) { _ };

    // args: []Instr.Index
    // next: Instr.Index
};
const Expr = struct {
    ty: Type,
    value: Value,
    srcloc: SrcLoc,
    const Value = union(enum) {
        compiletime: Decl.Index,
        runtime: Instr.Index,
    };
};

/// per-scope
const Scope = struct {
    env: *Env,
    tree: *const parser.AstTree,

    fn handleExpr(scope: *Scope, slot: Type, expr: parser.AstExpr) Error!Expr {
        return handleExpr_inner2(scope, slot, expr);
    }
};
/// per-target
const Env = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    has_error: bool = false,
    decls: std.ArrayListUnmanaged(Decl),
    compiler_srclocs: std.ArrayListUnmanaged(std.builtin.SourceLocation),
    comptime_keys: std.ArrayListUnmanaged(ComptimeKeyValue),
    string_to_comptime_key_map: std.ArrayHashMapUnmanaged(Types.Key.ComptimeValue, void, void, true),

    const ComptimeKeyValue = union(enum) {
        string: []const u8,
        symbol: []const u8,
    };
    const CtkCtx = struct {
        env: *Env,
        pub fn hash(self: CtkCtx, key: []const u8) u32 {
            _ = self;
            return std.array_hash_map.hashString(key);
        }
        pub fn eql(self: CtkCtx, a: []const u8, b: Types.Key.ComptimeValue, _: usize) bool {
            const val = self.env.comptime_keys.items[@intCast(@intFromEnum(b))];
            if (val != .string) return false;
            return std.mem.eql(u8, a, val.string);
        }
    };
    fn comptimeKeyFromString(env: *Env, str: []const u8) Error!Types.Key.ComptimeValue {
        try env.comptime_keys.ensureUnusedCapacity(env.gpa, 1);
        const gpres = try env.string_to_comptime_key_map.getOrPutAdapted(env.gpa, str, CtkCtx{ .env = env });
        if (!gpres.found_existing) {
            gpres.key_ptr.* = @enumFromInt(env.comptime_keys.items.len);
            env.comptime_keys.appendAssumeCapacity(.{ .string = env.arena.dupe(u8, str) catch @panic("oom") });
            gpres.value_ptr.* = {};
        }
        return gpres.key_ptr.*;
    }

    pub fn addErr(self: *Env, srcloc: SrcLoc, comptime msg: []const u8, fmt: anytype) Error {
        self.has_error = true;
        _ = srcloc;
        std.log.err("[compiler] " ++ msg, fmt);
        return error.ContainsError;
    }

    pub fn makeInfer(self: *Env, child: Type) Error!Type {
        return .from(Types.Infer, try anywhere.util.dupeOne(self.arena, Types.Infer{ .extends = child }));
    }
    pub fn readInfer(self: *Env, infer_idx: Type) ?Type {
        _ = self;
        _ = infer_idx;
        @panic("TODO");
    }
    pub fn addDecl(self: *Env, decl: Decl) Error!Decl.Index {
        const res = self.decls.items.len;
        try self.decls.append(self.gpa, decl);
        return @enumFromInt(res);
    }
    pub fn srclocFromSrc(self: *Env, bsrc: std.builtin.SourceLocation) !SrcLoc {
        const id: u32 = @intCast(self.compiler_srclocs.items.len);
        try self.compiler_srclocs.append(self.gpa, bsrc);
        return .{ .file_id = std.math.maxInt(u32), .offset = id };
    }
    pub fn declExpr(self: *Env, srcloc: SrcLoc, decl: Decl.Index) Error!Expr {
        const resolved = try self.resolveDeclType(decl);
        return .{
            .ty = resolved.resolved_type.?,
            .value = .{ .compiletime = decl },
            .srcloc = srcloc,
        };
    }
    pub fn resolveDeclType(self: *Env, decl: Decl.Index) Error!Decl {
        const res = self.decls.items[@intFromEnum(decl)];
        if (res.resolved_type == null) @panic("TODO resolve resolved_type for decl");
        return res;
    }
    pub fn resolveDeclValue(self: *Env, decl: Decl.Index) Error!Decl {
        const res = try self.resolveDeclType(decl);
        if (res.resolved_value_ptr == null) @panic("TODO resolve value_ptr for decl");
        return res;
    }
    pub fn castExpr(self: *Env, src: Expr, res_ty: Type, res_srcloc: SrcLoc) Expr {
        _ = self;
        return .{ .ty = res_ty, .value = src.value, .srcloc = res_srcloc };
    }
    fn expectComptimeKey(self: *Env, expr: Expr) !Types.Key.ComptimeValue {
        switch (expr.value) {
            .runtime => return self.addErr(expr.srcloc, "Expected a comptime value, got a runtime value", .{}),
            .compiletime => |ct| {
                if (!expr.ty.is(Types.Key)) return self.addErr(expr.srcloc, "Expected comptime key, got {s}", .{try expr.ty.name(self)});
                const val = try self.resolveDeclValue(ct);
                std.debug.assert(val.resolved_type != null);
                std.debug.assert(val.resolved_type.?.is(Types.Key));
                std.debug.assert(val.resolved_value_ptr != null);
                return val.resolved_value_ptr.?.to(Types.Key.ComptimeValue).*;
            },
        }
    }
};
// per-compiler invocation
const Global = struct {};
const Error = error{
    OutOfMemory,
    ContainsError,
};
inline fn handleExpr_inner2(scope: *Scope, slot: Type, expr: parser.AstExpr) Error!Expr {
    const tree = scope.tree;
    const srcloc = tree.src(expr);
    switch (tree.tag(expr)) {
        .call => {
            // a: b is equivalent to {%1 = {infer T}: a; T.call(a, b)}
            const method_ast, const arg_ast = tree.children(expr, 2);

            // if we wanted to, we could pass the slot as:
            // `(arg: infer T) => Slot`, then make the arg slot T
            const method_expr = try scope.handleExpr(try scope.env.makeInfer(Types.Unknown.ty), method_ast);
            // now get type.arg_type
            // then call type.call(arg_expr)
            return method_expr.ty.call(scope, slot, method_expr, arg_ast, srcloc);
        },
        .access => {
            // a.b is equivalent to {%1 = {infer T}: a; T.access(a, b)}
            const obj_ast, const prop_ast = tree.children(expr, 2);

            // if we wanted, slot could be `{[infer T]: Slot}` then make prop slot T
            const obj_expr = try scope.handleExpr(try scope.env.makeInfer(Types.Unknown.ty), obj_ast);
            // get type.prop_type
            // call type.access(prop_expr)

            return obj_expr.ty.access(scope, slot, obj_expr, prop_ast, srcloc);
        },
        .builtin => {
            _ = tree.children(expr, 0);
            // TODO: only add the decl once
            return scope.env.declExpr(srcloc, try scope.env.addDecl(.{
                .srcloc = try scope.env.srclocFromSrc(@src()), // TODO: use Types.Builtin's srcloc

                .dependencies = &.{},
                .resolved_type = Types.Builtin.ty,
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
                if (scope.handleExpr(Types.Void.ty, c)) |_| {} else |_| {}

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
            resolved_value_ptr.* = try scope.env.comptimeKeyFromString(str);
            return scope.env.declExpr(srcloc, try scope.env.addDecl(.{
                .srcloc = try scope.env.srclocFromSrc(@src()), // not sure what to use for this srcloc if we will have one per key
                .dependencies = &.{},
                .resolved_type = Types.Key.ty,
                .resolved_value_ptr = .from(Types.Key.ComptimeValue, resolved_value_ptr),
            }));
        },
        else => |t| return scope.env.addErr(tree.src(expr), "TODO expr: {s}", .{@tagName(t)}),
    }
}

test "compiler" {
    if (true) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var tree = parser.parse(gpa, example_src);
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
        .comptime_keys = .empty,
        .string_to_comptime_key_map = .empty,
    };
    defer env.string_to_comptime_key_map.deinit(gpa);
    defer env.comptime_keys.deinit(gpa);
    defer env.decls.deinit(env.gpa);
    defer env.compiler_srclocs.deinit(env.gpa);
    var scope: Scope = .{
        .env = &env,
        .tree = &tree,
    };
    const res = try scope.handleExpr(try env.makeInfer(Types.Unknown.ty), fn_body);
    _ = res;
}

// notes:
// - runtime backing
// - an int[0, 255] at comptime is backed by comptime_int, but at runtime is backed by u8
// - that's fine, it just means when taking a comptime decl and emitting it at runtime,
//   we have to define transforms.
