const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const c = @cImport({
    @cDefine("TRACY_ENABLE", "true");
    @cInclude("TracyC.h");
});

pub const enable_allocation = false;
pub const enable_callstack = false;

// TODO: make this configurable
const callstack_depth = 10;

pub const Ctx = extern struct {
    value: c.struct____tracy_c_zone_context,

    pub inline fn end(self: Ctx) void {
        c.___tracy_emit_zone_end(self.value);
    }

    pub inline fn addText(self: Ctx, text: []const u8) void {
        c.___tracy_emit_zone_text(self.value, text.ptr, text.len);
    }

    pub inline fn setName(self: Ctx, name: []const u8) void {
        c.___tracy_emit_zone_name(self.value, name.ptr, name.len);
    }

    pub inline fn setColor(self: Ctx, color: u32) void {
        c.___tracy_emit_zone_color(self.value, color);
    }

    pub inline fn setValue(self: Ctx, value: u64) void {
        c.___tracy_emit_zone_value(self.value, value);
    }
};

pub inline fn trace(comptime src: std.builtin.SourceLocation) Ctx {
    const global = struct {
        const loc: c.struct____tracy_source_location_data = .{
            .name = null,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };
    };

    if (enable_callstack) {
        return .{ .value = c.___tracy_emit_zone_begin_callstack(&global.loc, callstack_depth, 1) };
    } else {
        return .{ .value = c.___tracy_emit_zone_begin(&global.loc, 1) };
    }
}

/// name must be static lifetime
pub inline fn traceNamed(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Ctx {
    const global = struct {
        const loc: c.struct____tracy_source_location_data = .{
            .name = name.ptr,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };
    };

    if (enable_callstack) {
        return .{ .value = c.___tracy_emit_zone_begin_callstack(&global.loc, callstack_depth, 1) };
    } else {
        return .{ .value = c.___tracy_emit_zone_begin(&global.loc, 1) };
    }
}

pub fn tracyAllocator(allocator: std.mem.Allocator) TracyAllocator(null) {
    return TracyAllocator(null).init(allocator);
}

pub fn TracyAllocator(comptime name: ?[:0]const u8) type {
    return struct {
        parent_allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(parent_allocator: std.mem.Allocator) Self {
            return .{
                .parent_allocator = parent_allocator,
            };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = allocFn,
                    .resize = resizeFn,
                    .remap = remapFn,
                    .free = freeFn,
                },
            };
        }

        fn allocFn(ptr: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const tctx = trace(@src());
            defer tctx.end();

            const self: *Self = @ptrCast(@alignCast(ptr));
            const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
            if (result) |data| {
                if (len != 0) {
                    if (name) |n| {
                        allocNamed(data, len, n);
                    } else {
                        alloc(data, len);
                    }
                }
            } else {
                messageColor("allocation failed", 0xFF0000);
            }
            return result;
        }

        fn resizeFn(ptr: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const tctx = trace(@src());
            defer tctx.end();

            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
                if (name) |n| {
                    freeNamed(buf.ptr, n);
                    allocNamed(buf.ptr, new_len, n);
                } else {
                    free(buf.ptr);
                    alloc(buf.ptr, new_len);
                }

                return true;
            }

            // during normal operation the compiler hits this case thousands of times due to this
            // emitting messages for it is both slow and causes clutter
            return false;
        }
        fn remapFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            _ = ptr;
            _ = memory;
            _ = alignment;
            _ = new_len;
            _ = ret_addr;
            return null; // TODO call the backing allocator and use the tracy fns
        }

        fn freeFn(ptr: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
            const tctx = trace(@src());
            defer tctx.end();

            const self: *Self = @ptrCast(@alignCast(ptr));
            self.parent_allocator.rawFree(buf, buf_align, ret_addr);
            // this condition is to handle free being called on an empty slice that was never even allocated
            // example case: `std.process.getSelfExeSharedLibPaths` can return `&[_][:0]u8{}`
            if (buf.len != 0) {
                if (name) |n| {
                    freeNamed(buf.ptr, n);
                } else {
                    free(buf.ptr);
                }
            }
        }
    };
}

// This function only accepts comptime-known strings, see `messageCopy` for runtime strings
pub inline fn message(comptime msg: [:0]const u8) void {
    c.___tracy_emit_messageL(msg.ptr, if (enable_callstack) callstack_depth else 0);
}

// This function only accepts comptime-known strings, see `messageColorCopy` for runtime strings
pub inline fn messageColor(comptime msg: [:0]const u8, color: u32) void {
    c.___tracy_emit_messageLC(msg.ptr, color, if (enable_callstack) callstack_depth else 0);
}

pub inline fn messageCopy(msg: []const u8) void {
    c.___tracy_emit_message(msg.ptr, msg.len, if (enable_callstack) callstack_depth else 0);
}

pub inline fn messageColorCopy(msg: []const u8, color: u32) void {
    c.___tracy_emit_messageC(msg.ptr, msg.len, color, if (enable_callstack) callstack_depth else 0);
}

pub inline fn frameMark() void {
    c.___tracy_emit_frame_mark(null);
}

pub inline fn frameMarkNamed(comptime name: [:0]const u8) void {
    c.___tracy_emit_frame_mark(name.ptr);
}

pub inline fn namedFrame(comptime name: [:0]const u8) Frame(name) {
    frameMarkStart(name);
    return .{};
}

pub inline fn emitFrameImage(image: *const anyopaque, w: u16, h: u16, offset: u8, flip: c_int) void {
    c.___tracy_emit_frame_image(image, w, h, offset, flip);
}

pub fn Frame(comptime name: [:0]const u8) type {
    return struct {
        pub fn end(_: @This()) void {
            frameMarkEnd(name);
        }
    };
}

inline fn frameMarkStart(comptime name: [:0]const u8) void {
    c.___tracy_emit_frame_mark_start(name.ptr);
}

inline fn frameMarkEnd(comptime name: [:0]const u8) void {
    c.___tracy_emit_frame_mark_end(name.ptr);
}

inline fn alloc(ptr: [*]u8, len: usize) void {
    if (enable_callstack) {
        c.___tracy_emit_memory_alloc_callstack(ptr, len, callstack_depth, 0);
    } else {
        c.___tracy_emit_memory_alloc(ptr, len, 0);
    }
}

inline fn allocNamed(ptr: [*]u8, len: usize, comptime name: [:0]const u8) void {
    if (enable_callstack) {
        c.___tracy_emit_memory_alloc_callstack_named(ptr, len, callstack_depth, 0, name.ptr);
    } else {
        c.___tracy_emit_memory_alloc_named(ptr, len, 0, name.ptr);
    }
}

inline fn free(ptr: [*]u8) void {
    if (enable_callstack) {
        c.___tracy_emit_memory_free_callstack(ptr, callstack_depth, 0);
    } else {
        c.___tracy_emit_memory_free(ptr, 0);
    }
}

inline fn freeNamed(ptr: [*]u8, comptime name: [:0]const u8) void {
    if (enable_callstack) {
        c.___tracy_emit_memory_free_callstack_named(ptr, callstack_depth, 0, name.ptr);
    } else {
        c.___tracy_emit_memory_free_named(ptr, 0, name.ptr);
    }
}
