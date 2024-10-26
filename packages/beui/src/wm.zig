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
        final: B2.ID,
        tabs: struct {
            active_tab: usize,
            children: std.ArrayList(*InnerContainer),
        },
        split: struct {
            direction: enum { x, y },
            items: std.ArrayList(SplitContainerInfo),
        },
        floating: struct {},
    },
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

    const ValidateParent = enum { split_x, split_y, other };
    pub fn validate(node: *InnerContainer, parent: ValidateParent) void {
        switch (node.value) {
            .tabs => |*tcont| {
                std.debug.assert(tcont.active_tab < tcont.children.items.len);
                for (tcont.children.items) |ch| validate(ch, .other);
            },
            .split => |*split| {
                switch (split.direction) {
                    .x => std.debug.assert(parent != .split_x),
                    .y => std.debug.assert(parent != .split_y),
                }
                const sv: ValidateParent = switch (split.direction) {
                    .x => .split_x,
                    .y => .split_y,
                };
                for (split.items.items) |ch| validate(ch.node, sv);
            },
            .final => {},
        }
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
        if(self.id_to_inner_container_map.get(child)) |v| {
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
};

test WindowManager {
    var wm: WindowManager = .init(std.testing.allocator);
    defer wm.deinit();

    // add a window
    // const win = wm.getOrOpenWindow();
    // _ = win;

    // find the window for an id
}
