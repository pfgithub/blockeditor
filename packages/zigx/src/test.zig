const std = @import("std");
const Ast = @import("zig/Ast.zig");

test {
    _ = @import("example.zigx.zig");
}

// how it works:
// for build.zig, we will provide a Convert step.
// it does:
// - format the source
// - convert and write to output.zigx.zig
// then when importing zigx files, always add an extra ".zig" on the end
// and add "*.zigx.zig" to your gitignore.

// still todo:
// - we need to disambiguate shadowed names in captures.

// more things we can do:
// - we can pretty trivially replace eg '#' with '@src()' or 'ui.id.push(@src())'

fn testConvert(src: [:0]const u8, target: [:0]const u8) !void {
    const gpa = std.testing.allocator;
    var parsed = try Ast.parse(gpa, src, .zig);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), parsed.errors.len);

    var rendered = std.ArrayList(u8).init(gpa);
    defer rendered.deinit();
    try parsed.renderToArrayList(&rendered, .{ .render_to_zig = true });
    try std.testing.expectEqualStrings(target, rendered.items);

    {
        try rendered.append('\x00');
        var validatereprint = try std.zig.Ast.parse(gpa, rendered.items[0 .. rendered.items.len - 1 :0], .zig);
        defer validatereprint.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), validatereprint.errors.len);
        var zir = try std.zig.AstGen.generate(gpa, validatereprint);
        defer zir.deinit(gpa);
        try std.testing.expectEqual(false, zir.hasCompileErrors());
    }

    rendered.clearRetainingCapacity();
    try parsed.renderToArrayList(&rendered, .{ .render_to_zig = false });
    try std.testing.expectEqualStrings(src, rendered.items);
}

test "zigx" {
    try testConvert(
        \\const UI = @import("UI");
        \\
        \\fn demo(ui0: UI) void {
        \\    _ = UI.button(ui0.id, |ui1| blk: {
        \\        break :blk UI.Text("hello", ui1.id);
        \\    });
        \\}
        \\
    ,
        \\const UI = @import("UI");
        \\
        \\fn demo(ui0: UI) void {
        \\    _ = _0: { var _0 = UI.button(ui0.id); while(_0.next()) |ui1| _0.post(blk: {
        \\        break :blk UI.Text("hello", ui1.id);
        \\    }); break :_0 _0.end();};
        \\}
        \\
    );
}
