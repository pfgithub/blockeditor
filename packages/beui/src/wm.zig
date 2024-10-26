const std = @import("std");
const B2 = @import("beui_experiment.zig");

const FloatingContainer = struct {
    position: @Vector(2, f32),
    size: @Vector(2, f32),
    child: *InnerContainer,
};
const InnerContainer = struct {
    parent: ?*InnerContainer,
    value: union(enum) {
        final: struct {
            id: B2.ID,
        },
        tabs: struct {
            active_tab: usize,
            children: std.ArrayList(*InnerContainer),
        },
        split: struct {
            direction: enum { x, y },
            items: std.ArrayList(SplitContainerInfo),
        },
    },

    pub fn validate(node: *InnerContainer, parent: ?*InnerContainer) void {
        std.debug.assert(node.parent == parent);
        switch (node.value) {
            .tabs => |*tcont| {
                std.debug.assert(tcont.active_tab < tcont.children.items.len);
                for (tcont.children.items) |ch| validate(ch, node);
            },
            .split => |*split| {
                switch (split.direction) {
                    .x => std.debug.assert(parent == null or (parent.?.value == .split and parent.?.value.split.direction != .x)),
                    .y => std.debug.assert(parent == null or (parent.?.value == .split and parent.?.value.split.direction != .y)),
                }
                for (split.items.items, 0..) |ch, i| {
                    if (i == 0) std.debug.assert(ch.start_px == 0);
                    validate(ch.node, node);
                }
            },
            .final => {},
        }
    }
    pub fn format(self: *const InnerContainer, comptime _: []const u8, _: std.fmt.FormatOptions, writer: std.io.AnyWriter) !void {
        try writer.writeAll("[");
        switch (self.value) {
            .final => |id| {
                try writer.print("{d}", .{id.hash()});
            },
            .tabs => |t| {
                try writer.print("T", .{});
                for (t.children.items, 0..) |c, i| {
                    if (i == 0) try writer.print("|", .{});
                    try writer.print(" {}", .{c});
                }
            },
            .split => |s| {
                try writer.print("S", .{});
                for (s.items.items, 0..) |c, i| {
                    if (i == 0) try writer.print("|", .{});
                    try writer.print(" {d},{}", .{ c.start_px, c.node });
                }
            },
        }
        try writer.writeAll("]");
    }
};
const SplitContainerInfo = struct {
    start_px: f32, // first in the list is 0.
    node: *InnerContainer,
};

const WindowManager = struct {
    floating_containers: std.ArrayList(FloatingContainer),
    inner_containers: std.heap.MemoryPool(InnerContainer),
    id_to_inner_container_map: B2.IdMap(*InnerContainer),

    pub fn init(gpa: std.mem.Allocator) WindowManager {
        return .{
            .floating_containers = .init(gpa),
            .inner_containers = .init(gpa),
            .id_to_inner_container_map = .init(gpa),
        };
    }
    pub fn deinit(wm: *WindowManager) void {
        wm.floating_containers.deinit();
        wm.inner_containers.deinit();
        wm.id_to_inner_container_map.deinit();
    }

    pub fn validate(self: *const WindowManager) void {
        for (self.floating_containers.items) |fc| fc.child.validate(null);
    }

    fn getFloatingContainerForInnerContainer(self: *WindowManager, ic: *InnerContainer) ?*FloatingContainer {
        var parentmost_window = ic;
        while (parentmost_window.parent) |v| parentmost_window = v;
        for (self.floating_containers.items) |c| {
            if (c.child == parentmost_window) return c;
        } else {
            return null;
        }
    }

    pub fn moveFloating(self: *WindowManager, ic: *InnerContainer, offset: @Vector(2, f32), anchors: [4]bool) void {
        // go up to the parent floating container & move it
        const floating_target = self.getFloatingContainerForInnerContainer(ic) orelse {
            std.log.warn("moveFloating() called on window which no longer exists", .{});
            return;
        };
        var x1, var y1 = floating_target.position;
        var x2, var y2 = floating_target.position + floating_target.size;

        if (anchors[0]) x1 += offset[0];
        if (anchors[1]) y1 += offset[1];
        if (anchors[2]) x2 += offset[0];
        if (anchors[3]) y2 += offset[1];

        floating_target.position = .{ x1, y1 };
        floating_target.size = .{ x2 - x1, y2 - y1 };

        // min/max is not performed here; it is performed by the display instead
        // ^ that doesn't quite make sense - once a drag is over, if the window has negative
        //    size, we should fix its size so it doesn't appear to suddenly be broken.
        //    - maybe when a drag is started, we should fix? that way if you make the window
        //      smaller and a window is at the edge, it keeps its original position until you touch it?
        //    - alternatively, we could store two positions: target position & actual position. when
        //      starting a drag, set target position to actual position.
    }
    /// index is the index of the window after the split point
    pub fn moveSplit(self: *WindowManager, ic: *InnerContainer, index: usize, offset: f32) void {
        std.debug.assert(ic.value != .split);
        std.debug.assert(index == 0);
        std.debug.assert(index < ic.value.split.items.items.len);
        const target = &ic.value.split.items.items[index];
        target.start_px += offset;
        _ = self;
    }

    fn _addInnerContainer(self: *WindowManager, cont: InnerContainer) *InnerContainer {
        const res = self.inner_containers.create() catch @panic("oom");
        res.* = cont;
        return res;
    }

    /// TODO preserve location across app restarts; store window positions
    /// in a block or something and store arbitrary data in the window, ie a text
    /// editor would hold a reference to the text block being edited.
    /// also todo default layout stuff, ie "open this window to the right of this other window"
    pub fn getOrOpenWindow(self: *WindowManager, child: B2.ID) *InnerContainer {
        if (self.id_to_inner_container_map.get(child)) |v| {
            return v;
        }
        const res = self._addInnerContainer(.{
            .parent = null,
            .final = child,
        });
        self.floating_containers.append(.{
            .position = .{ 10, 10 },
            .size = .{ 100, 100 },
            .child = res,
        });
        return res;
    }

    pub fn format(self: *const WindowManager, comptime _: []const u8, _: std.fmt.FormatOptions, writer: std.io.AnyWriter) !void {
        self.validate();
        for (self.floating_containers.items, 0..) |fc, i| {
            if (i != 0) try writer.writeAll(" ");
            try writer.print("{d},{d},{d},{d},[{}]", .{ fc.position[0], fc.position[1], fc.size[0], fc.size[1], fc.child });
        }
    }
};

test WindowManager {
    var arena_backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_backing.deinit();
    const arena = arena_backing.allocator();

    var wm: WindowManager = .init(std.testing.allocator);
    defer wm.deinit();

    try std.testing.expectEqualStrings("", try std.fmt.allocPrint(arena, "{}", .{wm}));

    if (true) return error.SkipZigTest;

    // add a window
    const win1 = wm.getOrOpenWindow(1);
    try std.testing.expectEqualStrings("10,10,100,100,[1]", try std.fmt.allocPrint(arena, "{}", .{wm}));

    // add another window
    const win2 = wm.getOrOpenWindow(2);
    try std.testing.expectEqualStrings("10,10,100,100,[1] 10,10,100,100,[2]", try std.fmt.allocPrint(arena, "{}", .{wm}));

    // bring to front
    wm.bringToFrontWindow(win1);
    try std.testing.expectEqualStrings("10,10,100,100,[2] 10,10,100,100,[1]", try std.fmt.allocPrint(arena, "{}", .{wm}));

    // move window
    wm.moveFloating(win2, .{ 20, 20 }, .{ true, true, true, true });
    try std.testing.expectEqualStrings("30,30,100,100,[2] 10,10,100,100,[1]", try std.fmt.allocPrint(arena, "{}", .{wm}));

    // dock to the right
    wm.dropWindow(win2, win1, .right);
    try std.testing.expectEqualStrings("10,10,100,100,[S| 0,[1] 50,[2]]", try std.fmt.allocPrint(arena, "{}", .{wm}));

    // resize
    wm.moveSplit(win2.parent, 1, -30);
    try std.testing.expectEqualStrings("10,10,100,100,[S| 0,[1] 20,[2]]", try std.fmt.allocPrint(arena, "{}", .{wm}));

    // pick up to move
    wm.floatWindow(win2, .{ 50, 50 });
    try std.testing.expectEqualStrings("10,10,100,100,[1] 50,50,100,100,[2]", try std.fmt.allocPrint(arena, "{}", .{wm}));

    // tab it
    wm.dropWindow(win2, win1, .tab);
    try std.testing.expectEqualStrings("10,10,100,100,[T| [1] [2]]", try std.fmt.allocPrint(arena, "{}", .{wm}));

    // reorder tabs
    // (TODO? how to implement this?)
}

// it might be useful to try to implement this as a generic tree with no validation
// - every state is valid as long as the tree invariants are kept