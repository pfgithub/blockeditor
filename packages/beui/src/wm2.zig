const std = @import("std");
const B2 = @import("beui_experiment.zig");

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
    const FrameID = packed struct(u64) {
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
    const Frame = struct {
        gen: u32,
        parent: FrameID,
        id: FrameID,
        self: FrameContent,
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
const Manager = struct {
    id_to_frame_map: B2.IdArrayMapUnmanaged(WM.FrameID),
    frame_to_id_map: std.AutoArrayHashMap(WM.FrameID, B2.ID),

    // deinit ids
    // for (self.id_to_frame_map.keys()) |*id| {
    //     id.deinitOwned(self.gpa);
    // }

    pub fn getOrAddFrameForID(self: *WM, id: B2.ID) void {
        const gpres = self.id_to_frame_map.getOrPut(self.gpa, id) catch @panic("oom");
        if (gpres.found_existing) return gpres.value_ptr.*;

        gpres.key_ptr.* = id.dupeToOwned(self.gpa);
        const frame_id = self.addFrame(.{ .final = .{ .window = gpres.key_ptr.* } });
        gpres.value_ptr.* = frame_id;
        _ = self.addWindow(frame_id);
        return gpres.value_ptr.*;
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
