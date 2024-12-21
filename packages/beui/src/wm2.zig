const std = @import("std");
const B2 = @import("beui_experiment.zig");

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
    };
    const FrameContent = union(enum) {
        tabbed: struct {},
        split: struct {
            direction: enum { x, y },
        },
        final: struct {
            window: B2.ID,
        },
        window: struct {
            child: FrameID,
        },
    };
    gpa: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(Frame),
    id_to_frame_map: B2.IdArrayMapUnmanaged(FrameID),

    top_level_windows: std.ArrayListUnmanaged(FrameID),

    pub fn init(gpa: std.mem.Allocator) WM {
        return .{
            .gpa = gpa,
            .frames = .empty,
            .id_to_frame_map = .empty,
            .top_level_windows = .empty,
        };
    }
    pub fn deinit(self: *WM) void {
        // deinit ids
        for (self.id_to_frame_map.keys()) |*id| {
            id.deinitOwned(self.gpa);
        }

        // deinit things
        self.frames.deinit(self.gpa);
        self.id_to_frame_map.deinit(self.gpa);
        self.top_level_windows.deinit(self.gpa);
    }

    fn addFrame(self: *WM, value: FrameContent) FrameID {
        const id: FrameID = @enumFromInt(self.frames.items.len);
        self.frames.append(self.gpa, .{
            .parent = .not_set,
            .id = id,
            .self = value,
        }) catch @panic("oom");
        switch (value) {
            .tabbed => {},
            .split => {},
            .final => {},
            .window => |w| {
                self.getFrame(w.child)._setParent(id);
            },
        }
        return id;
    }
    fn addWindow(self: *WM, child: FrameID) FrameID {
        const window_id = self.addFrame(.{ .window = .{ .child = child } });
        self.top_level_windows.append(self.gpa, window_id) catch @panic("oom");
        self.getFrame(window_id).parent = .top_level;
        return window_id;
    }
    fn getFrame(self: *WM, frame: FrameID) *Frame {
        return &self.frames.items[@intFromEnum(frame)];
    }

    pub fn getOrAddFrameForID(self: *WM, id: B2.ID) FrameID {
        const gpres = self.id_to_frame_map.getOrPut(self.gpa, id) catch @panic("oom");
        if (gpres.found_existing) return gpres.value_ptr.*;

        gpres.key_ptr.* = id.dupeToOwned(self.gpa);
        const frame_id = self.addFrame(.{ .final = .{ .window = gpres.key_ptr.* } });
        gpres.value_ptr.* = frame_id;
        _ = self.addWindow(frame_id);
        return gpres.value_ptr.*;
    }

    fn testingRenderToString(self: *WM, buf: *std.ArrayList(u8)) ![]const u8 {
        buf.clearAndFree();

        for (self.top_level_windows.items, 0..) |tlw, i| {
            if (i != 0) try buf.appendSlice("\n");
            try self._renderFrameToString(tlw, .top_level, buf);
        }

        return buf.items;
    }
    fn _renderFrameToString(self: *WM, frame_id: FrameID, expect_parent: FrameID, out: *std.ArrayList(u8)) !void {
        const frame = self.getFrame(frame_id);
        std.debug.assert(frame.parent == expect_parent);
        std.debug.assert(frame_id == frame.id);

        try out.writer().print("@{d}.{s}", .{ @intFromEnum(frame_id), @tagName(frame.self) });
        try out.appendSlice(": ");
        switch (frame.self) {
            .tabbed => |_| {
                try out.appendSlice("%todo_tabbed%");
            },
            .split => {
                try out.appendSlice("%todo_tabbed%");
            },
            .final => |f| {
                try out.writer().print("{s}", .{f.window});
            },
            .window => |w| {
                try self._renderFrameToString(w.child, frame_id, out);
            },
        }
    }
};

test WM {
    var tester: B2.B2Tester = undefined;
    tester.init(std.testing.allocator);
    defer tester.deinit();

    var my_wm = WM.init(std.testing.allocator);
    defer my_wm.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    {
        const id = tester.startFrame(10000, .{ 1000, 500 });
        defer tester.endFrame();

        try std.testing.expectEqualStrings("", try my_wm.testingRenderToString(&buf));
        _ = my_wm.getOrAddFrameForID(id);
        try std.testing.expectEqualStrings(
            \\@1.window: @0.final: %
        , try my_wm.testingRenderToString(&buf));
        _ = my_wm.getOrAddFrameForID(id.subStr("0"));
        try std.testing.expectEqualStrings(
            \\@1.window: @0.final: %
            \\@3.window: @2.final: %."0"
        , try my_wm.testingRenderToString(&buf));
    }
}
