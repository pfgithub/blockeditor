const std = @import("std");
const src = @embedFile("tests/0.cvl");
const parser = @import("parser.zig");

test "compiler" {
    const gpa = std.testing.allocator;
    var tree = parser.parse(gpa, src);
    defer tree.deinit();
    try std.testing.expect(!tree.owner.has_errors);

    // it is parsed. now handle the root file decl
    const root = tree.root();
    const first_decl = tree.firstChild(root).?;
    const fn_def = tree.next(tree.firstChild(first_decl).?).?;
    const fn_body = tree.next(tree.firstChild(fn_def).?).?;
    _ = fn_body;
    // std.log.err("val: {s}", .{@tagName(tree.tag(fn_body))});
    // it's a code expr

}
