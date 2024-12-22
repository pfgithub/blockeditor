const std = @import("std");
const B2 = @import("beui_experiment.zig");
const Theme = @import("Theme.zig");

// this is the backing wm
// but the caller will manage:
// - remove windows by id that no longer exist
pub const XY = enum { x, y };
pub const LR = enum {
    left,
    right,
    pub fn idx(self: LR) u1 {
        return @intFromBool(self == .right);
    }
};
pub const Dir = enum {
    left,
    top,
    right,
    bottom,
    pub fn toXY(self: Dir) XY {
        return switch (self) {
            .left, .right => .x,
            .top, .bottom => .y,
        };
    }
    pub fn idx(self: Dir) u1 {
        return switch (self) {
            .left, .top => 0,
            .right, .bottom => 1,
        };
    }
};
pub const WM = struct {
    pub const FrameID = packed struct(u64) {
        gen: u32,
        ptr: enum(u32) {
            not_set = std.math.maxInt(u32) - 1,
            top_level = std.math.maxInt(u32),
            _,
        },
        pub const not_set = FrameID{ .gen = 0, .ptr = .not_set };
        pub const top_level = FrameID{ .gen = 0, .ptr = .top_level };

        pub fn format(value: FrameID, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("@{d}.{d}", .{ value.gen, @intFromEnum(value.ptr) });
        }
        fn fromTest(a: u32, b: u32) FrameID {
            return .{ .gen = a, .ptr = @enumFromInt(b) };
        }
    };
    pub const Frame = struct {
        gen: u32,
        parent: FrameID,
        id: FrameID,
        self: FrameContent,
        collapsed: bool = false,
        fn _setParent(self: *Frame, parent: FrameID) void {
            std.debug.assert(self.parent == FrameID.not_set);
            std.debug.assert(parent != FrameID.not_set);
            self.parent = parent;
        }
        pub fn clear(self: *Frame) void {
            self.* = .{ .gen = self.gen + 1, .parent = .not_set, .id = .not_set, .self = .none };
        }
    };
    const FrameContent = union(enum) {
        tabbed: struct {
            children: std.ArrayListUnmanaged(FrameID),
        },
        split: struct {
            direction: XY,
            children: std.ArrayListUnmanaged(FrameID),
        },
        final: struct {
            // window: B2.ID,
        },
        window: struct {
            child: FrameID,
        },
        dragging: struct {
            child: FrameID,
        },
        /// unreachable
        none,
        pub fn children(self: *FrameContent) []FrameID {
            switch (self.*) {
                inline .tabbed, .split => |s| return s.children.items,
                .final => return &.{},
                .window => |*w| return @as(*[1]FrameID, &w.child),
                .dragging => |*w| return @as(*[1]FrameID, &w.child),
                .none => unreachable,
            }
        }
        pub fn deinit(self: *FrameContent, gpa: std.mem.Allocator) void {
            switch (self.*) {
                inline .tabbed, .split => |*s| s.children.deinit(gpa),
                else => {},
            }
        }
    };
    gpa: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(Frame),
    unused_frames: std.ArrayListUnmanaged(FrameID),
    dragging: FrameID = .not_set,

    top_level_windows: std.ArrayListUnmanaged(FrameID),

    pub fn init(gpa: std.mem.Allocator) WM {
        return .{
            .gpa = gpa,
            .frames = .empty,
            .unused_frames = .empty,
            .top_level_windows = .empty,
        };
    }
    pub fn deinit(self: *WM) void {
        for (self.frames.items) |*f| {
            // if we swith to a memorypool, this will have to change
            if (f.self != .none) f.self.deinit(self.gpa);
        }

        // deinit things
        self.unused_frames.deinit(self.gpa);
        self.frames.deinit(self.gpa);
        self.top_level_windows.deinit(self.gpa);
    }

    pub fn addFrame(self: *WM, value: FrameContent) FrameID {
        const id: FrameID = if (self.unused_frames.popOrNull()) |reuse| blk: {
            break :blk reuse;
        } else blk: {
            const res: FrameID = .{ .gen = 0, .ptr = @enumFromInt(self.frames.items.len) };
            self.frames.append(self.gpa, undefined) catch @panic("oom");
            break :blk res;
        };
        self.getFrame(id).* = .{
            .gen = id.gen,
            .parent = .not_set,
            .id = id,
            .self = value,
        };

        for (self.getFrame(id).self.children()) |child| {
            self.getFrame(child)._setParent(id);
        }
        return id;
    }
    pub fn addWindow(self: *WM, child: FrameID) void {
        const window_id = self.addFrame(.{ .window = .{ .child = child } });
        self.top_level_windows.append(self.gpa, window_id) catch @panic("oom");
        self.getFrame(window_id).parent = .top_level;
    }
    fn existsFrame(self: *WM, frame: FrameID) bool {
        const res = &self.frames.items[@intFromEnum(frame.ptr)];
        return res.gen == frame.gen;
    }
    fn getFrame(self: *WM, frame: FrameID) *Frame {
        const res = &self.frames.items[@intFromEnum(frame.ptr)];
        if (res.gen != frame.gen) unreachable; // consider returning null in this case
        return res;
    }

    fn _removeNode(self: *WM, frame_id: FrameID) void {
        const pval = self.getFrame(frame_id);
        std.debug.assert(pval.self != .none);
        pval.self.deinit(self.gpa);
        pval.clear();
        self.unused_frames.append(self.gpa, .{ .gen = pval.gen, .ptr = frame_id.ptr }) catch @panic("oom");
    }
    fn _removeTree(self: *WM, frame_id: FrameID) void {
        const frame = self.getFrame(frame_id);
        for (frame.self.children()) |child| {
            self._removeTree(child);
        }
        self._removeNode(frame_id);
    }
    pub fn removeFrame(self: *WM, frame_id: FrameID) void {
        self._tellParentChildRemoved(frame_id);
        self._removeTree(frame_id);
    }
    fn _tellParentChildRemoved(self: *WM, child: FrameID) void {
        const child_frame = self.getFrame(child);
        const parent = child_frame.parent;
        if (parent == FrameID.top_level) unreachable; // not allowed
        const parent_frame = self.getFrame(parent);
        switch (parent_frame.self) {
            inline .tabbed, .split => |*sv| {
                _ = sv.children.orderedRemove(std.mem.indexOfScalar(FrameID, sv.children.items, child) orelse unreachable);
                if (sv.children.items.len == 0) unreachable;
                if (sv.children.items.len == 1) {
                    self.getFrame(sv.children.items[0]).parent = .not_set;
                    self._replaceChild(parent_frame.parent, parent, sv.children.items[0]);
                    self._removeNode(parent);
                }
            },
            .final => unreachable, // has no children
            .window => |win| {
                // the window must be removed
                std.debug.assert(win.child == child);
                self._removeNode(parent);
                const idx = std.mem.indexOfScalar(FrameID, self.top_level_windows.items, parent) orelse unreachable;
                _ = self.top_level_windows.orderedRemove(idx);
            },
            .dragging => |win| {
                // ungrab
                std.debug.assert(win.child == child);
                self._removeNode(parent);
                std.debug.assert(self.dragging == parent);
                self.dragging = .not_set;
            },
            .none => unreachable,
        }
    }
    pub fn grabFrame(self: *WM, frame_id: FrameID) void {
        std.debug.assert(self.dragging == FrameID.not_set);
        self._tellParentChildRemoved(frame_id);
        self.getFrame(frame_id).parent = .not_set;
        self.dragging = self.addFrame(.{ .dragging = .{ .child = frame_id } });
        self.getFrame(self.dragging).parent = .top_level;
    }
    fn _replaceChild(self: *WM, parent: FrameID, prev_child: FrameID, next_child: FrameID) void {
        const children = self.getFrame(parent).self.children();
        children[std.mem.indexOfScalar(FrameID, children, prev_child) orelse unreachable] = next_child;
        self.getFrame(next_child)._setParent(parent);
    }
    pub fn dropFrameNewWindow(self: *WM) void {
        std.debug.assert(self.dragging != FrameID.not_set);
        const child = self.getFrame(self.dragging).self.dragging.child;
        self._tellParentChildRemoved(child);

        self.getFrame(child).parent = .not_set;
        self.addWindow(child);
    }
    pub fn dropFrameSplit(self: *WM, target: FrameID, target_dir: Dir) void {
        std.debug.assert(self.dragging != FrameID.not_set);
        const child = self.getFrame(self.dragging).self.dragging.child;
        self._tellParentChildRemoved(child);

        const target_parent = self.getFrame(target).parent;
        const offset: usize, const split: FrameID = if (self.getFrame(target_parent).self == .split and self.getFrame(target_parent).self.split.direction == target_dir.toXY()) blk: {
            const idxof = std.mem.indexOfScalar(FrameID, self.getFrame(target_parent).self.split.children.items, target) orelse unreachable;
            break :blk .{ idxof, target_parent };
        } else blk: {
            const split = self.addFrame(.{ .split = .{
                .direction = target_dir.toXY(),
                .children = .empty,
            } });
            self.getFrame(split).self.split.children.append(self.gpa, target) catch @panic("oom");
            self._replaceChild(target_parent, target, split);
            self.getFrame(target).parent = .not_set;
            self.getFrame(target)._setParent(split);
            break :blk .{ 0, split };
        };
        self.getFrame(split).self.split.children.insert(self.gpa, offset + target_dir.idx(), child) catch @panic("oom");
        self.getFrame(child).parent = .not_set;
        self.getFrame(child)._setParent(split);
    }
    pub fn dropFrameTab(self: *WM, target: FrameID, target_dir: LR) void {
        std.debug.assert(self.dragging != FrameID.not_set);
        const child = self.getFrame(self.dragging).self.dragging.child;
        self._tellParentChildRemoved(child);

        const target_parent = self.getFrame(target).parent;
        const offset: usize, const tabbed: FrameID = if (self.getFrame(target_parent).self == .tabbed) blk: {
            const idxof = std.mem.indexOfScalar(FrameID, self.getFrame(target_parent).self.tabbed.children.items, target) orelse unreachable;
            break :blk .{ idxof, target_parent };
        } else blk: {
            const tabbed = self.addFrame(.{ .tabbed = .{
                .children = .empty,
            } });
            self.getFrame(tabbed).self.tabbed.children.append(self.gpa, target) catch @panic("oom");
            self._replaceChild(target_parent, target, tabbed);
            self.getFrame(target).parent = .not_set;
            self.getFrame(target)._setParent(tabbed);
            break :blk .{ 0, tabbed };
        };
        self.getFrame(tabbed).self.tabbed.children.insert(self.gpa, offset + target_dir.idx(), child) catch @panic("oom");
        self.getFrame(child).parent = .not_set;
        self.getFrame(child)._setParent(tabbed);
    }
    pub fn bringToFront(self: *WM, target: FrameID) void {
        // find parent
        const parentmost = self.findRoot(target);
        switch (self.getFrame(parentmost).self) {
            .window => {
                const idx = std.mem.indexOfScalar(FrameID, self.top_level_windows.items, parentmost) orelse unreachable;
                _ = self.top_level_windows.orderedRemove(idx);
                self.top_level_windows.appendAssumeCapacity(parentmost);
            },
            else => unreachable,
        }
    }
    pub fn findRoot(self: *WM, target: FrameID) FrameID {
        var parentmost: FrameID = target;
        while (self.getFrame(parentmost).parent != FrameID.top_level) {
            parentmost = self.getFrame(parentmost).parent;
        }
        std.debug.assert(self.getFrame(parentmost).parent == FrameID.top_level);
        return parentmost;
    }

    fn testingRenderToString(self: *WM, buf: *std.ArrayList(u8)) ![]const u8 {
        buf.clearAndFree();

        for (self.top_level_windows.items) |tlw| {
            try self._renderFrameToString(tlw, .top_level, buf, 1);
            try buf.appendSlice("\n");
        }

        if (self.dragging != FrameID.not_set) {
            try self._renderFrameToString(self.dragging, .top_level, buf, 1);
            try buf.appendSlice("\n");
        }

        if (std.mem.endsWith(u8, buf.items, "\n")) return buf.items[0 .. buf.items.len - 1];
        return buf.items;
    }
    fn _printIndent(out: *std.ArrayList(u8), indent: usize) !void {
        try out.append('\n');
        try out.appendNTimes(' ', indent * 4);
    }
    fn _renderFrameToString(self: *WM, frame_id: FrameID, expect_parent: FrameID, out: *std.ArrayList(u8), indent: usize) !void {
        const frame = self.getFrame(frame_id);
        try std.testing.expectEqual(frame.id, frame_id);
        if (expect_parent != frame.parent) {
            try out.writer().print("(expected parent = {}, got parent = {} for item {})", .{ expect_parent, frame.parent, frame_id });
        }

        try out.writer().print("{}.{s}", .{ frame_id, @tagName(frame.self) });
        switch (frame.self) {
            .tabbed => |s| {
                if (s.children.items.len < 2) unreachable;
                try out.writer().print(":", .{});
                for (s.children.items) |child| {
                    try _printIndent(out, indent);
                    try self._renderFrameToString(child, frame_id, out, indent + 1);
                }
            },
            .split => |s| {
                if (s.children.items.len < 2) unreachable;
                try out.writer().print(".{s}:", .{@tagName(s.direction)});
                for (s.children.items) |child| {
                    try _printIndent(out, indent);
                    try self._renderFrameToString(child, frame_id, out, indent + 1);
                }
            },
            .final => {},
            .window => |w| {
                try out.appendSlice(": ");
                try self._renderFrameToString(w.child, frame_id, out, indent);
            },
            .dragging => |d| {
                try out.appendSlice(": ");
                try self._renderFrameToString(d.child, frame_id, out, indent);
            },
            .none => unreachable,
        }
    }
};

test WM {
    var my_wm = WM.init(std.testing.allocator);
    defer my_wm.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqualStrings("", try my_wm.testingRenderToString(&buf));
    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@0.1.window: @0.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@0.1.window: @0.0.final
        \\@0.3.window: @0.2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(.fromTest(0, 0));
    try std.testing.expectEqualStrings(
        \\@0.3.window: @0.2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(.fromTest(0, 2));
    try std.testing.expectEqualStrings(
        \\
    , try my_wm.testingRenderToString(&buf));

    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@1.3.window: @1.2.final
        \\@1.1.window: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(1, 2));
    try std.testing.expectEqualStrings(
        \\@1.1.window: @1.0.final
        \\@2.3.dragging: @1.2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameSplit(.fromTest(1, 0), .left);
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    @1.2.final
        \\    @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    @1.2.final
        \\    @1.0.final
        \\@0.5.window: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(0, 4));
    my_wm.dropFrameSplit(.fromTest(1, 0), .right);
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    @1.2.final
        \\    @1.0.final
        \\    @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(1, 0));
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    @1.2.final
        \\    @0.4.final
        \\@2.5.dragging: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameNewWindow();
    try std.testing.expectEqualStrings(
        \\@1.1.window: @3.3.split.x:
        \\    @1.2.final
        \\    @0.4.final
        \\@3.5.window: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(1, 2));
    try std.testing.expectEqualStrings(
        \\@1.1.window: @0.4.final
        \\@3.5.window: @1.0.final
        \\@4.3.dragging: @1.2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameTab(.fromTest(1, 0), .left);
    try std.testing.expectEqualStrings(
        \\@1.1.window: @0.4.final
        \\@3.5.window: @5.3.tabbed:
        \\    @1.2.final
        \\    @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(0, 4));
    try std.testing.expectEqualStrings(
        \\@3.5.window: @5.3.tabbed:
        \\    @1.2.final
        \\    @1.0.final
        \\@2.1.dragging: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameTab(.fromTest(1, 0), .right);
    try std.testing.expectEqualStrings(
        \\@3.5.window: @5.3.tabbed:
        \\    @1.2.final
        \\    @1.0.final
        \\    @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(0, 4));
    try std.testing.expectEqualStrings(
        \\@3.5.window: @5.3.tabbed:
        \\    @1.2.final
        \\    @1.0.final
        \\@3.1.dragging: @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameSplit(.fromTest(1, 2), .bottom);
    try std.testing.expectEqualStrings(
        \\@3.5.window: @5.3.tabbed:
        \\    @4.1.split.y:
        \\        @1.2.final
        \\        @0.4.final
        \\    @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(1, 0));
    try std.testing.expectEqualStrings(
        \\@3.5.window: @4.1.split.y:
        \\    @1.2.final
        \\    @0.4.final
        \\@6.3.dragging: @1.0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameSplit(.fromTest(0, 4), .left);
    try std.testing.expectEqualStrings(
        \\@3.5.window: @4.1.split.y:
        \\    @1.2.final
        \\    @7.3.split.x:
        \\        @1.0.final
        \\        @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@3.5.window: @4.1.split.y:
        \\    @1.2.final
        \\    @7.3.split.x:
        \\        @1.0.final
        \\        @0.4.final
        \\@0.7.window: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(.fromTest(4, 1));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
        \\@4.5.dragging: @4.1.split.y:
        \\    @1.2.final
        \\    @7.3.split.x:
        \\        @1.0.final
        \\        @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.dropFrameTab(.fromTest(0, 6), .right);
    try std.testing.expectEqualStrings(
        \\@0.7.window: @5.5.tabbed:
        \\    @0.6.final
        \\    @4.1.split.y:
        \\        @1.2.final
        \\        @7.3.split.x:
        \\            @1.0.final
        \\            @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(.fromTest(1, 2));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @5.5.tabbed:
        \\    @0.6.final
        \\    @7.3.split.x:
        \\        @1.0.final
        \\        @0.4.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(.fromTest(7, 3));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
        \\@1.4.window: @8.3.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.bringToFront(.fromTest(0, 7));
    try std.testing.expectEqualStrings(
        \\@1.4.window: @8.3.final
        \\@0.7.window: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.bringToFront(.fromTest(0, 6));
    try std.testing.expectEqualStrings(
        \\@1.4.window: @8.3.final
        \\@0.7.window: @0.6.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.bringToFront(.fromTest(8, 3));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
        \\@1.4.window: @8.3.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.bringToFront(.fromTest(1, 4));
    try std.testing.expectEqualStrings(
        \\@0.7.window: @0.6.final
        \\@1.4.window: @8.3.final
    , try my_wm.testingRenderToString(&buf));
}

// could make this <Manager> <addWindow /> <addWindow> <addWindow /> </addWindow> ... </Manager>
// (rather than being a global thing managed by beui itself)
// but that means you would have to be passing around *Manager pointers or you would need to use a context provider
// and wm is going to handle stuff like dropdown menus, ... so basically everything needs it
pub const Manager = struct {
    wm: WM,
    /// stored for both the 'window' and the item directly inside it
    top_level_window_positions_and_sizes: std.AutoArrayHashMapUnmanaged(WM.FrameID, struct { pos: @Vector(2, f32), size: @Vector(2, f32) }),

    id_to_final_map: B2.IdArrayMapUnmanaged(WM.FrameID),
    final_to_id_map: std.AutoArrayHashMapUnmanaged(WM.FrameID, B2.ID),
    this_frame: std.ArrayListUnmanaged(struct {
        id_unowned: B2.ID,
        frame_id: WM.FrameID,
        title: []const u8,
        cb: B2.Component(B2.StandardCallInfo, void, *B2.RepositionableDrawList),
    }),

    /// empty except inside endFrame() call
    render_windows_ctx: RenderWindowResult,
    final_rdl: ?*B2.RepositionableDrawList,

    /// not owned
    current_window: ?B2.ID,

    active: ?FrameCfg,

    pub const FrameCfg = struct {
        size: @Vector(2, f32),
        id: B2.ID,
    };
    pub const RenderWindowResult = std.AutoHashMapUnmanaged(WM.FrameID, RenderWindowCtx);
    pub const RenderWindowCtx = struct {
        title: []const u8,
        result: union(enum) {
            filled: struct {
                size: @Vector(2, f32),
                reservation: B2.RepositionableDrawList.Reservation,
            },
            empty: struct {},
        },
    };

    pub fn init(gpa: std.mem.Allocator) Manager {
        return .{
            .wm = .init(gpa),
            .top_level_window_positions_and_sizes = .empty,
            .id_to_final_map = .empty,
            .final_to_id_map = .empty,
            .this_frame = .empty,
            .render_windows_ctx = .empty,
            .current_window = null,
            .active = null,
            .final_rdl = null,
        };
    }
    pub fn deinit(self: *Manager) void {
        for (self.id_to_final_map.keys()) |*id| {
            id.deinitOwned(self.wm.gpa);
        }
        self.id_to_final_map.deinit(self.wm.gpa);
        self.final_to_id_map.deinit(self.wm.gpa);
        self.render_windows_ctx.deinit(self.wm.gpa);
        self.this_frame.deinit(self.wm.gpa);
        self.wm.deinit();
    }

    pub fn beginFrame(self: *Manager, cfg: FrameCfg) void {
        std.debug.assert(self.active == null);
        self.active = cfg;

        // clean id_to_final / final_to_id maps of closed windows
        {
            var i: usize = 0;
            const keys = self.final_to_id_map.keys();
            const values = self.final_to_id_map.values();
            while (i < keys.len) {
                const final = keys[i];
                if (!self.wm.existsFrame(final)) {
                    // delete
                    std.debug.assert(self.id_to_final_map.swapRemove(values[i]));
                    self.final_to_id_map.swapRemoveAt(i);
                } else {
                    i += 1;
                }
            }
        }
        // clean top_level_window_positions_and_sizes of closed windows
        {
            var i: usize = 0;
            const keys = self.top_level_window_positions_and_sizes.keys();
            while (i < keys.len) {
                const final = keys[i];
                if (!self.wm.existsFrame(final)) {
                    self.top_level_window_positions_and_sizes.swapRemoveAt(i);
                } else {
                    i += 1;
                }
            }
        }

        self.final_rdl = cfg.id.b2.draw();
    }
    pub fn endFrame(self: *Manager) *B2.RepositionableDrawList {
        std.debug.assert(self.active != null);
        const cfg = self.active.?;
        self.active = null;

        // at end of frame vs during frame:
        // - during frame:
        //   - 0 frame delay for closing windows because that is handled between frames
        //   - 1 frame delay for a window closed by an if statement, but only if it is a subframe of a frame with another frame
        //     - must make sure to call requiresRerender in this case
        //   - Theme provides a function to render a given root frame
        //   - window may be rendered inside of another window's callback
        //     - but collapsing the outer window will close the inner window. and uncollapsing the outer window will spawn
        //       a new inner window with reset size & position. so this seems like odd behaviour.
        //   - callback is run during the addWindow function call, which is expected
        // - at end of frame:
        //   - 0 frame delay for closing windows, including windows closed by an if statement
        //   - Theme provides a function to render an entire WM instance
        //     - excluding fullscreen overlays, dropdown menus, and some other things
        //   - callback must only point to frame-allocated memory, not stack-allocated. this is unusual, as typically component
        //     callbacks are called immediately
        //   - windows may not be rendered inside another window's callback. dropdown menus and other overlays will be
        //     handled by a different fn. dropdowns can't be handled by the Theme render.

        // 1. update wm:
        //     - remove closed windows
        //       - ideally most windows are closed between frames rather than during a frame. a window
        //         that is closed during a frame could have been closed by an if statement, which is weird.
        //     - save titles
        std.debug.assert(self.render_windows_ctx.count() == 0);
        defer self.render_windows_ctx.clearRetainingCapacity();
        for (self.this_frame.items) |item| {
            self.render_windows_ctx.putNoClobber(self.wm.gpa, item.frame_id, .{
                .title = item.title,
                .result = .empty,
            }) catch @panic("oom");
            // TODO notice closed windows, etc
        }

        // 2. call Theme.renderWindows();
        const rdl = Theme.renderWindows(cfg.id.sub(@src()), cfg.size, &self.wm, &self.render_windows_ctx);

        // 3. loop over this_frame.items, call callbacks, and fill reservations
        for (self.this_frame.items) |item| {
            // 4. get the final_window_slot for the final frame id
            const window_ctx = self.render_windows_ctx.get(item.frame_id).?;
            const filled = switch (window_ctx.result) {
                .filled => |f| f,
                .empty => continue, // window is collapsed
            };

            // 5. call cb() using the size and fill the reservation with the result
            const cb_res = blk: {
                std.debug.assert(self.current_window == null);
                self.current_window = item.id_unowned;
                defer self.current_window = null;
                break :blk item.cb.call(.{ .caller_id = item.id_unowned, .constraints = .{ .available_size = .{ .w = filled.size[0], .h = filled.size[1] } } }, {});
            };
            filled.reservation.for_draw_list.fill(filled.reservation, cb_res, .{});
        }

        self.this_frame.clearRetainingCapacity();

        self.final_rdl.?.place(rdl, .{});
        defer self.final_rdl = null;
        return self.final_rdl.?;
    }

    /// callback will be called at the end of the frame! callback data ptr must be allocated by the frame arena! no stack data!
    pub fn addWindow(self: *Manager, id_unowned: B2.ID, title: []const u8, cb: B2.Component(B2.StandardCallInfo, void, *B2.RepositionableDrawList)) void {
        std.debug.assert(self.active != null);

        // 1. get the final frame id for the passed in id_unowned
        //    - not found? create a new frame
        const frame_id_gpres = self.id_to_final_map.getOrPut(self.wm.gpa, id_unowned) catch @panic("oom");
        if (!frame_id_gpres.found_existing) {
            frame_id_gpres.key_ptr.* = id_unowned.dupeToOwned(self.wm.gpa);
            const frame_id = self.wm.addFrame(.{ .final = .{} });
            self.wm.addWindow(frame_id);
            frame_id_gpres.value_ptr.* = frame_id;
            self.final_to_id_map.putNoClobber(self.wm.gpa, frame_id_gpres.value_ptr.*, frame_id_gpres.key_ptr.*) catch @panic("oom");
        }
        const frame_id = frame_id_gpres.value_ptr.*;

        self.this_frame.append(self.wm.gpa, .{
            .id_unowned = id_unowned,
            .frame_id = frame_id,
            .title = id_unowned.b2.frame.arena.dupe(u8, title) catch @panic("oom"),
            .cb = cb,
        }) catch @panic("oom");
    }

    pub fn addFullscreenOverlay(self: *Manager, id_unowned: B2.ID, cb: B2.Component(B2.StandardCallInfo, void, *B2.RepositionableDrawList)) void {
        std.debug.assert(self.active != null);
        std.debug.assert(self.current_window == null);
        const result = cb.call(.{ .caller_id = id_unowned.sub(@src()), .constraints = .{ .available_size = .{ .w = self.active.?.size[0], .h = self.active.?.size[1] } } }, {});
        self.final_rdl.?.place(result, .{});
    }
};

// next todo:
// - information:
//   - top level window has position, size
//   - split has percentages (or absolute sizes for all but one?) for each child
//   - move & resize top level
//   - resize split boundaries
// - alwaysonbottom items
// - fullscreen_overlay items
// - bring to front
// - collapsing: have to decide what can be collapsed? eg all but one of a split window
// - dragging window from top level to tab, then dragging out from tab back to top level should preserve size.
//   - this means each 'final' window has a 'top_level_size' that is used when it becomes top level
// - figure out what to do about preview vs commit. and how to do smooth tab reordering.
