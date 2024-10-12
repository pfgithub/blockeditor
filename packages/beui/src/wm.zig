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
    start_percent: f32, // first in the list is 0. next is 33%. next is 66%. end.
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
        };
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
};

test WindowManager {
    var wm: WindowManager = .init(std.testing.allocator);
    defer wm.deinit();
}
