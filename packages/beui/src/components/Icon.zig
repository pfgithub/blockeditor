const B2 = @import("../beui_experiment.zig");

const IconTag = enum {
    arrow_opened,
    arrow_closed,
};
pub const IconData = struct {
    // we should probably have declarative methods to declare icons
    // ie from svg or from image
    // (for image it can be cached based on the hash of the image content or similar)
    append: *const fn (rdl: *B2.RepositionableDrawList) void,
};

pub fn Icon(call_info: B2.StandardCallInfo, value: *const IconData, label: ?[]const u8) B2.StandardChild {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    value.append(rdl);
    _ = label; // TODO
    return .{ .rdl = rdl, .size = .{ 24, 24 } };
}
