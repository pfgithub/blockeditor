const std = @import("std");
const B2 = @import("beui_experiment.zig");

// this is the backing wm
// but the caller will manage:
// - remove windows by id that no longer exist
const WM = struct {
    const FrameID = enum(usize) {
        not_set = std.math.maxInt(usize) - 1,
        top_level = std.math.maxInt(usize),
        _,
    };
    const Frame = struct {
        parent: FrameID,
        id: FrameID,
        self: FrameContent,
        fn _setParent(self: *Frame, parent: FrameID) void {
            std.debug.assert(self.parent == .not_set);
            std.debug.assert(parent != .not_set);
            self.parent = parent;
        }
        pub const none: Frame = if (std.debug.runtime_safety) .{ .parent = .not_set, .id = .not_set, .self = .none } else undefined;
    };
    const FrameContent = union(enum) {
        tabbed: struct {},
        split: struct {
            direction: enum { x, y },
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
        pub fn children(self: *const FrameContent) []const FrameID {
            switch (self.*) {
                .tabbed => return &.{},
                .split => return &.{},
                .final => return &.{},
                .window => |w| return @as(*const [1]FrameID, &w.child),
                .dragging => |w| return @as(*const [1]FrameID, &w.child),
                .none => unreachable,
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

        // deinit things
        self.unused_frames.deinit(self.gpa);
        self.frames.deinit(self.gpa);
        self.top_level_windows.deinit(self.gpa);
    }

    pub fn addFrame(self: *WM, value: FrameContent) FrameID {
        const id: FrameID = if (self.unused_frames.popOrNull()) |reuse| blk: {
            break :blk reuse;
        } else blk: {
            const res: FrameID = @enumFromInt(self.frames.items.len);
            self.frames.append(self.gpa, .none) catch @panic("oom");
            break :blk res;
        };
        self.getFrame(id).* = .{
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
        return &self.frames.items[@intFromEnum(frame)];
    }

    fn _removeNode(self: *WM, frame_id: FrameID) void {
        const pval = self.getFrame(frame_id);
        std.debug.assert(pval.self != .none);
        pval.* = .none;
        self.unused_frames.append(self.gpa, frame_id) catch @panic("oom");
    }
    fn _removeTree(self: *WM, frame_id: FrameID) void {
        const frame = self.getFrame(frame_id);
        for (frame.self.children()) |child| {
            self._removeTree(child);
        }
        self._removeNode(frame_id);
    }
    pub fn removeFrame(self: *WM, frame_id: FrameID) void {
        {
            const frame = self.getFrame(frame_id);
            if (frame.self == .window) return self.removeFrame(frame.self.window.child);
        }
        self._onRemoveChild(self.getFrame(frame_id).parent, frame_id);
        self._removeTree(frame_id);
    }
    fn _onRemoveChild(self: *WM, frame_id: FrameID, child: FrameID) void {
        const frame = self.getFrame(frame_id);
        switch (frame.self) {
            .tabbed => @panic("TODO onRemoveChild(tabbed)"),
            .split => @panic("TODO onRemovedChild(split)"),
            .final => unreachable, // has no children
            .window => |win| {
                // the window must be removed
                std.debug.assert(win.child == child);
                self._removeNode(frame_id);
                const idx = std.mem.indexOfScalar(FrameID, self.top_level_windows.items, frame_id) orelse unreachable;
                _ = self.top_level_windows.orderedRemove(idx);
            },
            .dragging => |win| {
                // ungrab
                std.debug.assert(win.child == child);
                self._removeNode(frame_id);
                std.debug.assert(self.dragging == frame_id);
                self.dragging = .not_set;
            },
            .none => unreachable,
        }
    }
    pub fn grabFrame(self: *WM, frame_id: FrameID) void {
        std.debug.assert(self.dragging == .not_set);
        self._onRemoveChild(self.getFrame(frame_id).parent, frame_id);
        self.getFrame(frame_id).parent = .not_set;
        self.dragging = self.addFrame(.{ .dragging = .{ .child = frame_id } });
        self.getFrame(self.dragging).parent = .top_level;
    }

    fn testingRenderToString(self: *WM, buf: *std.ArrayList(u8)) ![]const u8 {
        buf.clearAndFree();

        for (self.top_level_windows.items) |tlw| {
            try self._renderFrameToString(tlw, .top_level, buf);
            try buf.appendSlice("\n");
        }

        if (self.dragging != .not_set) {
            try self._renderFrameToString(self.dragging, .top_level, buf);
            try buf.appendSlice("\n");
        }

        if (std.mem.endsWith(u8, buf.items, "\n")) return buf.items[0 .. buf.items.len - 1];
        return buf.items;
    }
    fn _renderFrameToString(self: *WM, frame_id: FrameID, expect_parent: FrameID, out: *std.ArrayList(u8)) !void {
        const frame = self.getFrame(frame_id);
        std.debug.assert(frame.parent == expect_parent);
        std.debug.assert(frame_id == frame.id);

        try out.writer().print("@{d}.{s}", .{ @intFromEnum(frame_id), @tagName(frame.self) });
        switch (frame.self) {
            .tabbed => |_| {
                try out.appendSlice(": %todo_tabbed%");
            },
            .split => {
                try out.appendSlice(": %todo_tabbed%");
            },
            .final => {},
            .window => |w| {
                try out.appendSlice(": ");
                try self._renderFrameToString(w.child, frame_id, out);
            },
            .dragging => |d| {
                try out.appendSlice(": ");
                try self._renderFrameToString(d.child, frame_id, out);
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
        \\@1.window: @0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@1.window: @0.final
        \\@3.window: @2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(@enumFromInt(0));
    try std.testing.expectEqualStrings(
        \\@3.window: @2.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.removeFrame(@enumFromInt(3));
    try std.testing.expectEqualStrings(
        \\
    , try my_wm.testingRenderToString(&buf));

    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    my_wm.addWindow(my_wm.addFrame(.{ .final = .{} }));
    try std.testing.expectEqualStrings(
        \\@3.window: @2.final
        \\@1.window: @0.final
    , try my_wm.testingRenderToString(&buf));
    my_wm.grabFrame(@enumFromInt(2));
    try std.testing.expectEqualStrings(
        \\@1.window: @0.final
        \\@3.dragging: @2.final
    , try my_wm.testingRenderToString(&buf));
}
