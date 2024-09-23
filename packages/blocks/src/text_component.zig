//! Definitions:
//! - Document: a rendered text file
//!   - DocByte: index into the document
//! - Segment: all spans that share an id
//!   - SegByte: index into a segment
//! - Span: an individual section of a segment holding a slice of buffer data
//!   - SpanByte: index into a span
//! - Buffer: raw unordered text data referenced by spans
//!    - BufByte: index into the buffer
//!
//! WARNING: BufByte and DocByte have been confused frequently
//! TODO: audit code for uses of 'bufbyte' and correct them to 'docbyte' where needed

const bi = @import("blockinterface2.zig");
const util = @import("util.zig");

fn BalancedBinaryTree(comptime Data: type) type {
    return struct {
        const Count = Data.Count;

        const NodeIndex = enum(usize) {
            none = 0,
            root = std.math.maxInt(usize),
            _,
            pub fn format(value: NodeIndex, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                switch (value) {
                    .none => {
                        try writer.print("ø", .{});
                    },
                    .root => {
                        try writer.print("T", .{});
                    },
                    else => {
                        try writer.print("{d}", .{@intFromEnum(value)});
                    },
                }
            }
        };
        const Node = struct {
            lhs_sum: Count,
            self_sum: Count,
            rhs_sum: Count,
            height: usize,
            value: Data,

            parent: NodeIndex = .none,
            lhs: NodeIndex = .none,
            rhs: NodeIndex = .none,

            fn sum(node: Node) Count {
                return node.lhs_sum.add(node.self_sum).add(node.rhs_sum);
            }
            fn side(node: *const Node, dir: Direction) NodeIndex {
                return switch (dir) {
                    .left => node.lhs,
                    .right => node.rhs,
                };
            }
            fn sideMut(node: *Node, dir: Direction) *NodeIndex {
                return switch (dir) {
                    .left => &node.lhs,
                    .right => &node.rhs,
                };
            }
        };
        // results:
        // ArrayList, ReleaseSafe, 100_000: 4.155s
        // SegmentedList, ReleaseSafe, 100_000: 7.023s
        // ArenaAllocator, ReleaseSafe, 100_000: 0.396s
        pool: std.heap.MemoryPool(Node), // this is internally an arena but it keeps a linked list of destroyed objects (why not an ArrayList? not sure)
        root_node: NodeIndex = .none,

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .pool = .init(alloc),
            };
        }
        pub fn deinit(self: *@This()) void {
            self.pool.deinit();
        }

        fn _addNode(self: *@This(), data: Data) !NodeIndex {
            const slot = try self.pool.create();
            slot.* = .{
                .height = 1,
                .lhs_sum = Count.zero,
                .self_sum = data.count(self),
                .rhs_sum = Count.zero,
                .value = data,
            };
            return @enumFromInt(@intFromPtr(slot));
        }
        fn _recalculateSumsAtAndAbove(self: *@This(), node_idx: NodeIndex) void {
            var pos = node_idx;
            var iter_zero = true;
            while (pos != .none and pos != .root) {
                const node = self._getNodePtr(pos).?;
                const prev_lhs_sum = node.lhs_sum;
                const prev_rhs_sum = node.rhs_sum;
                const prev_height = node.height;
                node.lhs_sum = if (self._getNodePtr(node.lhs)) |lhs| lhs.sum() else Count.zero;
                node.rhs_sum = if (self._getNodePtr(node.rhs)) |rhs| rhs.sum() else Count.zero;
                node.height = 1 + @max(self._height(node.lhs), self._height(node.rhs));
                if (!iter_zero and prev_lhs_sum.eql(node.lhs_sum) and prev_rhs_sum.eql(node.rhs_sum) and prev_height == node.height) {
                    break; // no need to loop anymore
                }
                pos = node.parent;
                iter_zero = false;
            }
        }
        fn _getNodePtr(_: *@This(), node_idx: NodeIndex) ?*Node {
            if (node_idx == .none or node_idx == .root) return null;
            const res: *Node = @ptrFromInt(@intFromEnum(node_idx));
            return res;
        }
        fn _getNodePtrConst(_: *const @This(), node_idx: NodeIndex) ?*const Node {
            if (node_idx == .none or node_idx == .root) return null;
            const res: *Node = @ptrFromInt(@intFromEnum(node_idx));
            return res;
        }
        pub fn getNodeDataPtrConst(_: *const @This(), node_idx: NodeIndex) ?*const Data {
            if (node_idx == .none or node_idx == .root) return null;
            const res: *Node = @ptrFromInt(@intFromEnum(node_idx));
            return &res.value;
        }
        const Direction = enum {
            left,
            right,
            fn flip(self: Direction) Direction {
                return switch (self) {
                    .left => .right,
                    .right => .left,
                };
            }
        };
        fn _link(self: *BBT, parent: NodeIndex, direction: Direction, child: NodeIndex) void {
            self._linkParent(parent, child);
            self._linkSide(parent, direction, child);
        }
        fn _getParent(self: *const BBT, child: NodeIndex) NodeIndex {
            if (child == .none) return .none;
            if (child == .root) return .none;
            const node_ptr = self._getNodePtrConst(child).?;
            return node_ptr.parent;
        }
        fn _getChildSide(self: *const BBT, parent: NodeIndex, child: NodeIndex) Direction {
            if (self._getSide(parent, .left) == child) return .left;
            if (self._getSide(parent, .right) == child) return .right;
            unreachable;
        }
        fn _getSide(self: *const BBT, parent: NodeIndex, direction: Direction) NodeIndex {
            if (parent == .root and direction == .right) unreachable;
            if (parent == .root and direction == .left) return self.root_node;
            if (parent == .none) return .none;
            return self._getNodePtrConst(parent).?.side(direction);
        }
        fn _linkSide(self: *BBT, parent: NodeIndex, direction: Direction, child: NodeIndex) void {
            if (parent == .root and direction == .right) unreachable;
            if (parent == .root and direction == .left) {
                self.root_node = child;
                return;
            }
            if (parent == .none) {
                return;
            }
            self._getNodePtr(parent).?.sideMut(direction).* = child;
        }
        fn _linkParent(self: *BBT, parent: NodeIndex, child: NodeIndex) void {
            if (child == .root) unreachable;
            const child_ptr = self._getNodePtr(child) orelse return;
            child_ptr.parent = parent;
        }
        fn _rotateRight(self: *BBT, y_idx: NodeIndex) void {
            const parent_idx = self._getParent(y_idx);
            const parent_side = self._getChildSide(parent_idx, y_idx);
            // [[a x b] y c] => [a x [b y c]]
            const x_idx = self._getSide(y_idx, .left);
            if (y_idx == .none or x_idx == .none) @panic("rotateRight must have x and y");
            const a_idx = self._getSide(x_idx, .left);
            const b_idx = self._getSide(x_idx, .right);
            const c_idx = self._getSide(y_idx, .right);

            self._link(x_idx, .left, a_idx);
            self._link(x_idx, .right, y_idx);
            self._link(y_idx, .left, b_idx);
            self._link(y_idx, .right, c_idx);
            self._link(parent_idx, parent_side, x_idx);

            self._recalculateSumsAtAndAbove(a_idx);
            self._recalculateSumsAtAndAbove(x_idx);
            self._recalculateSumsAtAndAbove(b_idx);
            self._recalculateSumsAtAndAbove(c_idx);
            self._recalculateSumsAtAndAbove(y_idx);
        }
        fn _rotateLeft(self: *BBT, x_idx: NodeIndex) void {
            const parent_idx = self._getParent(x_idx);
            const parent_side = self._getChildSide(parent_idx, x_idx);
            // [a x [b y c]] => [[a x b] y c]
            const y_idx = self._getSide(x_idx, .right);
            if (y_idx == .none or x_idx == .none) @panic("rotateLeft must have x and y");
            const a_idx = self._getSide(x_idx, .left);
            const b_idx = self._getSide(y_idx, .left);
            const c_idx = self._getSide(y_idx, .right);

            self._link(x_idx, .left, a_idx);
            self._link(x_idx, .right, b_idx);
            self._link(y_idx, .left, x_idx);
            self._link(y_idx, .right, c_idx);
            self._link(parent_idx, parent_side, y_idx);

            self._recalculateSumsAtAndAbove(a_idx);
            self._recalculateSumsAtAndAbove(b_idx);
            self._recalculateSumsAtAndAbove(x_idx);
            self._recalculateSumsAtAndAbove(c_idx);
            self._recalculateSumsAtAndAbove(y_idx);
        }
        fn _height(self: *const @This(), target: NodeIndex) usize {
            const nodev = self._getNodePtrConst(target) orelse return 0;
            return nodev.height;
        }
        fn _rebalanceInner(self: *@This(), x_idx: NodeIndex) ?NodeIndex {
            const y_idx = self._getParent(x_idx);
            const z_idx = self._getParent(y_idx);
            if (x_idx == .root or y_idx == .root or z_idx == .root) return null;
            const y_dir_to_x = self._getChildSide(y_idx, x_idx);
            const z_dir_to_y = self._getChildSide(z_idx, y_idx);

            const z_ptr = self._getNodePtrConst(z_idx) orelse return null;
            const lhs_height = self._height(z_ptr.lhs);
            const rhs_height = self._height(z_ptr.rhs);
            if (lhs_height > rhs_height + 1) {
                // left case
                std.debug.assert(z_dir_to_y == .left);
                switch (y_dir_to_x) {
                    .left => {
                        // left left case
                        self._rotateRight(z_idx);
                    },
                    .right => {
                        // left right case
                        self._rotateLeft(y_idx);
                        self._rotateRight(z_idx);
                    },
                }
            } else if (lhs_height + 1 < rhs_height) {
                // right case
                std.debug.assert(z_dir_to_y == .right);
                switch (y_dir_to_x) {
                    .left => {
                        // right left case
                        self._rotateRight(y_idx);
                        self._rotateLeft(z_idx);
                    },
                    .right => {
                        // right right case
                        self._rotateLeft(z_idx);
                    },
                }
            } else {
                // nothing to do
            }

            // travel up
            return self._getParent(x_idx);
        }
        fn _rebalance(self: *@This(), x_id: NodeIndex) void {
            var target: ?NodeIndex = x_id;
            while (target) |t| {
                target = self._rebalanceInner(t);
            }
        }
        pub fn insertNodeBefore(self: *@This(), new_node_data: Data, anchor_node: NodeIndex) !NodeIndex {
            // the correct way to insert is to only insert as a leaf node
            // so:
            // - if before has no lhs, insert as lhs
            // - if before has lhs, go lhs and insert as rhs
            //   - if has rhs, go rhs and insert as rhs
            //   - ... loop
            // that might be why our balance isn't working

            const new_node = try self._addNode(new_node_data);

            const anchor_lhs = self._getSide(anchor_node, .left);
            if (anchor_lhs != .none) {
                var target = anchor_lhs;
                while (true) {
                    const target_rhs = self._getSide(target, .right);
                    if (target_rhs == .none) break;
                    target = target_rhs;
                }
                self._link(target, .right, new_node);
            } else {
                self._link(anchor_node, .left, new_node);
            }

            self._recalculateSumsAtAndAbove(new_node);
            self._rebalance(new_node);

            return new_node;
        }
        pub fn updateNode(self: *@This(), node_idx: NodeIndex, new_node_data: Data) void {
            const nodev = self._getNodePtr(node_idx).?;
            nodev.value = new_node_data;
            nodev.self_sum = nodev.value.count(self);
            self._recalculateSumsAtAndAbove(node_idx);
        }

        pub fn getCountForNode(self: *const @This(), node: NodeIndex) Count {
            if (node == .root) {
                const root_val = self._getNodePtrConst(self.root_node) orelse return .zero;
                return root_val.sum();
            }
            const root_node_ptr = self._getNodePtrConst(node).?;
            var current_count: Count = root_node_ptr.lhs_sum;
            var current_node = node;
            while (true) {
                const parent = self._getParent(current_node);
                if (parent == .root) break;
                const child_side = self._getChildSide(parent, current_node);
                if (child_side == .right) {
                    const parent_ptr = self._getNodePtrConst(parent).?;
                    current_count = parent_ptr.lhs_sum.add(parent_ptr.self_sum).add(current_count);
                }
                current_node = parent;
            }

            return current_count;
        }

        pub fn findNodeForQuery(self: *const @This(), query: anytype) NodeIndex {
            return self._findNodeForQuerySub(self.root_node, .zero, query);
        }
        fn _findNodeForQuerySub(self: *const @This(), node_idx: NodeIndex, parent_sum: Count, target: anytype) NodeIndex {
            const node = self._getNodePtrConst(node_idx) orelse return .root;

            const lhs = parent_sum.add(node.lhs_sum);
            const lhs_plus_center = lhs.add(node.self_sum);
            const cmp_res = target.compare(lhs, lhs_plus_center);

            switch (cmp_res) {
                .eq => {
                    // in range (will always be false for a deleted node)
                    return node_idx;
                },
                .gt => {
                    // search rhs
                    return self._findNodeForQuerySub(node.rhs, lhs_plus_center, target);
                },
                .lt => {
                    // search lhs
                    return self._findNodeForQuerySub(node.lhs, parent_sum, target);
                },
            }
        }
        fn iterator(self: *const @This(), opts: IteratorOptions) Iterator {
            var res: Iterator = .{ .tree = self, .node = undefined, .skip_most_empties = opts.skip_most_empties };
            if (opts.leftmost_node) |lmn| {
                res.node = lmn;
            } else {
                res.node = self.root_node;
                res.goDeepLhs();
            }
            return res;
        }
        const IteratorOptions = struct {
            leftmost_node: ?NodeIndex = null,
            skip_most_empties: bool = false,
        };
        const BBT = @This();
        const Iterator = struct {
            tree: *const BBT,
            node: NodeIndex,
            skip_most_empties: bool = false,

            /// go to the deepest lhs node within the current node
            fn goDeepLhs(self: *Iterator) void {
                while (true) {
                    const lhs = self.tree._getSide(self.node, .left);
                    if (lhs == .none) break;
                    if (self.skip_most_empties) {
                        const lhs_ptr = self.tree._getNodePtrConst(lhs).?;
                        if (lhs_ptr.sum().eql(Data.Count.zero)) {
                            // waste of time to explore this tree
                            break;
                        }
                    }
                    self.node = lhs;
                }
            }
            /// go to the nearest parent who's lhs = the child
            fn goParent(self: *Iterator) void {
                while (true) {
                    const prev_node_idx = self.node;
                    const parent = self.tree._getParent(prev_node_idx);
                    self.node = parent;
                    const parent_side = self.tree._getChildSide(self.node, prev_node_idx);
                    if (parent_side == .right) {
                        continue;
                    } else {
                        break;
                    }
                }
            }
            fn next(self: *Iterator) ?NodeIndex {
                const result = self.node;
                if (result == .none or result == .root) return null;

                const crhs = self.tree._getSide(self.node, .right);
                if (crhs != .none) {
                    self.node = crhs;
                    self.goDeepLhs();
                } else {
                    self.goParent();
                }

                return result;
            }
        };

        pub fn format(value: *const BBT, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try previewTreeRecursive(value, writer, value.root_node, .zero);
        }
        fn previewTreeRecursive(tree: *const BBT, out: std.io.AnyWriter, current_node: NodeIndex, current_offset: Count) !void {
            const node_ptr = tree._getNodePtrConst(current_node) orelse {
                try out.print("ø", .{});
                return;
            };
            try out.print("[", .{});
            try previewTreeRecursive(tree, out, node_ptr.lhs, current_offset);
            try out.print(", {}:{}^{d}.{}, ", .{ current_node, current_offset.add(node_ptr.lhs_sum), node_ptr.height, node_ptr.value });
            try previewTreeRecursive(tree, out, node_ptr.rhs, current_offset.add(node_ptr.lhs_sum).add(node_ptr.self_sum));
            try out.print("]", .{});
        }
    };
}

const SampleData = struct {
    value: []const u8,
    deleted: bool,
    fn count(self: @This(), _: *const BalancedBinaryTree(SampleData)) Count {
        if (self.deleted) return .{ .items = 1, .length = 0, .newline_count = 0 };
        var res: Count = .{ .items = 1, .length = self.value.len, .newline_count = 0 };
        for (self.value) |char| {
            if (char == '\n') res.newline_count += 1;
        }
        return res;
    }
    pub fn format(value: SampleData, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}\"{}\"", .{ if (value.deleted) "[d]" else "", std.zig.fmtEscapes(value.value) });
    }

    const Count = struct {
        // TODO: we need to determine height
        // oops this isn't measuring height, it's measuring items right now
        items: usize,
        length: usize,
        newline_count: usize,
        pub const zero = @This(){ .items = 0, .length = 0, .newline_count = 0 };
        pub fn add(a: @This(), b: @This()) @This() {
            return .{
                .items = a.items + b.items,
                .length = a.length + b.length,
                .newline_count = a.newline_count + b.newline_count,
            };
        }
        pub fn eql(a: @This(), b: @This()) bool {
            return std.meta.eql(a, b);
        }
        pub fn format(value: Count, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{d}", .{value.length});
        }

        const DocbyteQuery = struct {
            docbyte: usize,
            fn compare(q: DocbyteQuery, a: Count, b: Count) std.math.Order {
                if (q.docbyte < a.length) return .lt;
                if (q.docbyte >= b.length) return .gt;
                return .eq;
            }
        };
    };
};

fn testPrintTree(tree: *BalancedBinaryTree(SampleData), expected_value: []const u8) !void {
    var actual_value = std.ArrayList(u8).init(std.testing.allocator);
    defer actual_value.deinit();

    var iter = tree.iterator(.{});
    while (iter.next()) |idx| {
        const node = tree._getNodePtr(idx).?;
        if (node.value.deleted) continue;
        actual_value.appendSlice(node.value.value) catch @panic("oom");
    }

    try std.testing.expectEqualStrings(expected_value, actual_value.items);

    try std.testing.expectEqual(expected_value.len, tree.getCountForNode(.root).length);
}
fn previewTree(tree: *const BalancedBinaryTree(SampleData)) !void {
    try std.io.getStdErr().writer().any().print("{}\n", .{tree});
}
test "bbt" {
    const Tree = BalancedBinaryTree(SampleData);

    const gpa = std.testing.allocator;

    var tree = Tree.init(gpa);
    defer tree.deinit();

    try testPrintTree(&tree, "");
    const end_node = try tree.insertNodeBefore(.{ .value = "\x00", .deleted = false }, .root);
    try testPrintTree(&tree, "\x00");
    const hw = try tree.insertNodeBefore(.{ .value = "Hello, World!", .deleted = false }, end_node);
    try testPrintTree(&tree, "Hello, World!\x00");

    _ = try tree.insertNodeBefore(.{ .value = "[", .deleted = false }, hw);
    try testPrintTree(&tree, "[Hello, World!\x00");
    try testPrintTree(&tree, "[Hello, World!\x00");
    _ = try tree.insertNodeBefore(.{ .value = "]", .deleted = false }, end_node);
    try testPrintTree(&tree, "[Hello, World!]\x00");
    try testPrintTree(&tree, "[Hello, World!]\x00");

    _ = try tree.insertNodeBefore(.{ .value = "(n14)", .deleted = false }, tree.findNodeForQuery(SampleData.Count.DocbyteQuery{ .docbyte = 14 }));
    try testPrintTree(&tree, "[Hello, World!(n14)]\x00");
    try testPrintTree(&tree, "[Hello, World!(n14)]\x00");

    try previewTree(&tree);
}

// this is essentially zed's model:
//   https://zed.dev/blog/crdts
// it's only a small stretch from here to having a proper CRDT
// - right now multiplayer will require going back and re-applying events
//   to make sure they end up in the same order on all clients
// - a CRDT allows applying operations in any order and always ending
//   up at the same result (well, dependencies have to be applied before
//   dependants, but that's the only ordering rule.)
// - the one case where we're not a CRDT is:
//   [@1"hello" @0"\x00"]
//      insert: @1.0 "+"
//      insert: @1.0 "!"
//      uh oh! applying these in a different order gives different results
//   also same thing with two people deleting the same region

const std = @import("std");

pub const LynCol = struct { lyn: u64, col: u64 };

pub const SegmentID = enum(u64) {
    end = 0,
    _,

    pub fn owner(self: SegmentID) u16 {
        const num = @intFromEnum(self);
        return @intCast(num & std.math.maxInt(u16));
    }
    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const num = @intFromEnum(self.*);
        if (num == 0) {
            try writer.print("E", .{});
            return;
        }
        const op_id = num >> 16;
        const client_id = self.owner();
        try writer.print("@{d}", .{op_id});
        if (client_id != 0) {
            try writer.print("/{d}", .{client_id});
        }
    }

    pub fn jsonStringify(self: SegmentID, json: anytype) !void {
        // remove after https://github.com/ziglang/zig/pull/21228
        try json.write(@intFromEnum(self));
    }
};
pub const MoveID = enum(u64) {
    _,

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const num = @intFromEnum(self.*);
        const op_id = num >> 16;
        const client_id = num & std.math.maxInt(u16);
        try writer.print("*{d}", .{op_id});
        if (client_id != 0) {
            try writer.print("/{d}", .{client_id});
        }
    }
};

// indices into this are:
// @id.segbyte
// they are stable and don't even need updating!
// - if the cursor position is @4.1, regardless of all the inserts and deletes
//   that happen, the cursor position can stay @4.1
// the only trouble is the table gets bigger over time
// - compaction destroys undo history

pub const Position = struct {
    id: SegmentID,
    /// can never refer to the last index of a segment
    segbyte: u64,

    pub const end = Position{ .id = .end, .segbyte = 0 };

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.id == .end) {
            try writer.print("E", .{});
            return;
        }
        try writer.print("{}.{d}", .{ self.id, self.segbyte });
    }
};

pub const TextDocument = Document(u8, 0);
/// The plan is for this to work for:
/// - Text documents (plain text or rich text with embedded blocks)
/// - Reorderable lists ('move' op should be used rather than delete+insert)
/// TODO: document needs to call deinit on T if it is available
pub fn Document(comptime T: type, comptime T_empty: T) type {
    return struct {
        // TODO: SimpleOperation
        // whenever the document changes, it needs to emit SimpleOperation
        // events. We can't just put this in applyOperation, it probably needs
        // to keep a callback list unfortunately.
        const Doc = @This();
        pub const SimpleOperation = struct {
            position: Position,
            delete_len: u64,
            insert_text: []const T,
        };
        pub const EmitSimpleOperation = struct {
            position: u64,
            delete_len: u64,
            insert_text: []const T,
        };
        pub const Operation = union(enum) {
            move: struct {
                // To support using Document for lists, we need a 'move' operation. Otherwise, two people moving the same
                // list item could cause it to duplicate.
                start: Position,
                len_within_segment: u64,
                end: Position,

                // to find the spans to move, it gets the spans from start to start + len_within_segment (within
                // a segment). tombstones are included in length calculations but are not moved.
            },
            insert: struct {
                id: SegmentID,
                pos: Position,
                text: []const T,
            },
            extend: struct {
                // can only be performed by the owner of the segment id
                // if two clients try to extend the same segment, that doesn't work.
                // note: this may split a span into multiple if its end index is not
                // the buffer end index. this does not count as an observable difference
                // between clients. the only goal is that the full segment is the same
                // between clients, but @0"a" @0"b" on one client and @0"ab" on another
                // is allowed.
                id: SegmentID,
                prev_len: u64, // *must be full length of segment*. for error checking only.
                text: []const T,
            },
            delete: struct {
                // a delete operation only deletes a slice of a single segment
                // instead of being start: Position, end: Position
                // 0: "|my text|"
                //    1.0: "my |great |text"
                //    2.0: "||"
                // => |great |
                // this might be a bit helpful against data loss?
                // it's sure not helpful for programming. this is really annoying. it
                // would be so much easier as start: Position, end: Position

                // reminder: len_within_segment can span multiple spans
                // of the same segment
                start: Position,
                len_within_segment: u64,
            },
            replace: struct {
                // replaces text within a segment starting at [start] with [text]. undeletes any deleted text
                // in this range. cannot change the length of a segment.

                // this should be used for:
                // - undoing a delete operation
                // - checking or unchecking a markdown checkbox

                start: Position,
                text: []const T,
            },

            pub fn serialize(self: *const Operation, out: *bi.AlignedArrayList) void {
                std.json.stringify(self, .{}, out.writer()) catch @panic("oom");
            }
            pub fn deserialize(arena: std.mem.Allocator, slice: bi.AlignedByteSlice) !Operation {
                return std.json.parseFromSliceLeaky(Operation, arena, slice, .{}) catch return error.DeserializeError;
            }

            pub fn format(
                self: *const @This(),
                comptime _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                switch (self.*) {
                    .move => |mop| {
                        try writer.print("[M:{}:{d}->{}]", .{ mop.start, mop.len_within_segment, mop.end });
                    },
                    .insert => |iop| {
                        try writer.print("[I:{}:\"{}\"->{}]", .{ iop.pos, std.zig.fmtEscapes(iop.text), iop.id });
                    },
                    .delete => |dop| {
                        try writer.print("[D:{}:{d}]", .{ dop.start, dop.len_within_segment });
                    },
                    .extend => |xop| {
                        try writer.print("[X:{}:{d}:\"{}\"]", .{ xop.id, xop.prev_len, std.zig.fmtEscapes(xop.text) });
                    },
                    .replace => |rop| {
                        try writer.print("[R:{}:\"{}\"]", .{ rop.start, std.zig.fmtEscapes(rop.text) });
                    },
                }
            }
        };

        pub const Span = struct {
            id: SegmentID,
            length: u64,
            start_segbyte: u64,
            bufbyte: ?u64, // null = deleted

            fn deleted(self: Span) bool {
                return self.bufbyte == null;
            }

            pub fn format(value: Span, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                if (value.deleted()) {
                    try writer.print("-{d}", .{value.length});
                } else {
                    try writer.print("{}\"{d}\"", .{ value.id, value.length });
                }
            }

            fn count(span: *const Span, bbt: *const BalancedBinaryTree(Span)) Count {
                if (span.deleted()) return .{
                    .byte_count = 0,
                    .newline_count = 0,
                    .bytes_after_newline_count = 0,
                };
                const document: *const Doc = @alignCast(@fieldParentPtr("span_bbt", bbt));
                var result = Count{
                    .byte_count = span.length,
                    .newline_count = 0,
                    .bytes_after_newline_count = 0,
                };
                for (document.buffer.items[usi(span.bufbyte.?)..][0..usi(span.length)]) |char| {
                    result.bytes_after_newline_count += 1;
                    if (char == '\n') {
                        result.newline_count += 1;
                        result.bytes_after_newline_count = 0;
                    }
                }
                return result;
            }
            const Count = struct {
                pub const zero = Count{ .byte_count = 0, .newline_count = 0, .bytes_after_newline_count = 0 };
                byte_count: u64,
                newline_count: u64,
                bytes_after_newline_count: u64,

                fn add(a: Count, b: Count) Count {
                    return .{
                        .byte_count = a.byte_count + b.byte_count,
                        .newline_count = a.newline_count + b.newline_count,
                        .bytes_after_newline_count = if (b.newline_count == 0) a.bytes_after_newline_count + b.bytes_after_newline_count else b.bytes_after_newline_count,
                    };
                }
                fn eql(a: Count, b: Count) bool {
                    return std.meta.eql(a, b);
                }
                pub fn format(value: Count, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                    try writer.print("{d}", .{value.byte_count});
                }

                const DocbyteQuery = struct {
                    docbyte: u64,
                    pub fn compare(q: DocbyteQuery, a: Count, b: Count) std.math.Order {
                        if (q.docbyte < a.byte_count) return .lt;
                        if (q.docbyte >= b.byte_count) return .gt;
                        return .eq;
                    }
                };
                const LynColQuery = struct {
                    lyn: u64,
                    col: u64,
                    fn tx64To128(a: u64, b: u64) u128 {
                        return (@as(u128, a) << 64) | b;
                    }
                    pub fn compare(q: LynColQuery, a: Count, b: Count) std.math.Order {
                        if (tx64To128(q.lyn, q.col) < tx64To128(a.newline_count, a.bytes_after_newline_count)) return .lt;
                        if (tx64To128(q.lyn, q.col) >= tx64To128(b.newline_count, b.bytes_after_newline_count)) return .gt;
                        return .eq;
                    }
                };
            };
        };
        const BBT = BalancedBinaryTree(Span);
        // this causes a noticable pause to deinit :/
        const SegmentIDMap = std.AutoHashMap(SegmentID, std.ArrayList(BBT.NodeIndex)); // sorted so it can be binary searched
        span_bbt: BBT, // must contain at least: @0 "\x00"
        segment_id_map: SegmentIDMap, // this could also be a tree sorted by SegmentID first and segbyte second
        buffer: std.ArrayList(T),
        allocator: std.mem.Allocator,
        panic_on_modify_segment_id_map: bool = false,

        on_before_simple_operation: util.CallbackList(util.Callback(EmitSimpleOperation, void)),
        on_after_simple_operation: util.CallbackList(util.Callback(EmitSimpleOperation, void)),

        client_id: u16,
        /// must not be 0
        next_uuid: u48,

        pub fn format(
            self: *const @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            var it = self.span_bbt.iterator(.{});
            var i: usize = 0;
            while (it.next()) |node| : (i += 1) {
                const span = self.span_bbt.getNodeDataPtrConst(node).?;
                if (i != 0) try writer.print(" ", .{});
                if (span.id == .end) {
                    std.debug.assert(span.length == 1);
                    std.debug.assert(!span.deleted());
                    try writer.print("E", .{});
                    continue;
                }
                try writer.print("{}.{d}", .{ span.id, span.start_segbyte });
                if (span.bufbyte) |bufbyte| {
                    const span_text = self.buffer.items[bufbyte..][0..span.length];
                    try writer.print("\"{}\"", .{std.zig.fmtEscapes(span_text)});
                } else {
                    try writer.print("-{d}", .{span.length});
                }
            }
        }

        const serialized_span = extern struct {
            length: packed struct(u64) { deleted: bool, len: u63 },
            id: SegmentID,
        };
        // this is a bunch of zeroes and a two. why? isn't length 1 and id 0? where's the two from? and why does this have to be so long
        pub const default = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
        pub fn serialize(self: *const Doc, out: *bi.AlignedArrayList) void {
            // format: [u64 aligned_length] [bytes] [length, id] [end]
            const writer = out.writer();

            // write span contents
            writer.writeInt(u64, self.length(), .little) catch @panic("oom");
            var iter = self.span_bbt.iterator(.{ .skip_most_empties = true });
            while (iter.next()) |node_idx| {
                const node = self.span_bbt.getNodeDataPtrConst(node_idx).?;
                if (node.id == .end) break;
                if (node.bufbyte == null) continue;

                writer.writeAll(self.buffer.items[usi(node.bufbyte.?)..][0..usi(node.length)]) catch @panic("oom");
            }

            // align
            const aligned_length = std.mem.alignForward(usize, out.items.len, bi.Alignment);
            const align_diff = aligned_length - out.items.len;
            for (0..align_diff) |_| writer.writeByte('\x00') catch @panic("oom");

            // write spans (& merge adjacent)
            iter = self.span_bbt.iterator(.{});
            var uncommitted_span: ?serialized_span = null;
            while (iter.next()) |node_idx| {
                const node = self.span_bbt.getNodeDataPtrConst(node_idx).?;

                std.debug.assert(node.length != 0);
                std.debug.assert(node.length <= std.math.maxInt(u63));

                if (uncommitted_span) |*uc| {
                    if (uc.length.deleted == node.deleted() and uc.id == node.id) {
                        // the span can be merged instead of written
                        uc.*.length.len += @intCast(node.length);
                        continue;
                    }

                    writer.writeStructEndian(uc.*, .little) catch @panic("oom");
                }
                uncommitted_span = serialized_span{
                    .length = .{
                        .deleted = node.deleted(),
                        .len = @intCast(node.length),
                    },
                    .id = node.id,
                };
            }
            if (uncommitted_span) |uc| {
                writer.writeStructEndian(uc, .little) catch @panic("oom");
            }
        }
        pub fn deserialize(gpa: std.mem.Allocator, fbs: *bi.AlignedFbsReader) bi.DeserializeError!Doc {
            const reader = fbs.reader();

            var res = Doc.initEmpty(gpa);
            errdefer res.deinit();

            const bufbyte_offset = res.buffer.items.len;

            const buffer_length = reader.readInt(u64, .little) catch return error.DeserializeError;
            if (buffer_length > fbs.buffer[fbs.pos..].len) return error.DeserializeError;
            res.buffer.appendSlice(fbs.buffer[fbs.pos..][0..usi(buffer_length)]) catch @panic("oom");
            fbs.pos += usi(buffer_length);
            fbs.pos = std.mem.alignForward(usize, fbs.pos, bi.Alignment);
            if (fbs.pos > fbs.buffer.len) return error.DeserializeError;

            var bufbyte: u64 = 0;
            while (true) {
                const itm = reader.readStructEndian(serialized_span, .little) catch return error.DeserializeError;

                if (itm.id == .end) {
                    break;
                }

                var start_segbyte: u64 = 0;
                if (res.segment_id_map.get(itm.id)) |prev_span| {
                    if (prev_span.items.len > 0) {
                        const last_idx = prev_span.items[prev_span.items.len - 1];
                        const last_v = res.span_bbt.getNodeDataPtrConst(last_idx).?;
                        start_segbyte += last_v.start_segbyte + last_v.length;
                    }
                }

                // definitely not right
                // we should be doing replaceRange(E node, 1, {new span, E node})
                const insert_span = Span{
                    .id = itm.id,
                    .length = itm.length.len,
                    .start_segbyte = start_segbyte,
                    .bufbyte = if (itm.length.deleted) null else blk: {
                        defer bufbyte += itm.length.len;
                        if (bufbyte + itm.length.len > buffer_length) return error.DeserializeError;
                        break :blk bufbyte + bufbyte_offset;
                    },
                };
                const last = res._findEntrySpan(Position.end).span_index;
                res._insertBefore(last, &.{insert_span});
            }

            if (bufbyte != buffer_length) return error.DeserializeError;

            return res;
        }

        pub fn initEmpty(alloc: std.mem.Allocator) Doc {
            var res: Doc = .{
                .span_bbt = undefined,
                .buffer = .init(alloc),
                .segment_id_map = .init(alloc),
                .allocator = alloc,

                .on_before_simple_operation = .init(alloc),
                .on_after_simple_operation = .init(alloc),

                .client_id = 0,
                .next_uuid = 1,
            };
            res.buffer.append(T_empty) catch @panic("oom");

            // spans_bbt uses fieldParentPtr to find the buffer for counting
            // the inserted node, so it must be inside the document when
            // we call insertNodeBefore. It's okay if the pointer moves later.
            res.span_bbt = .init(alloc);

            // manually init first span because there are no event handlers
            const last_span: Span = .{
                .id = @enumFromInt(0),
                .start_segbyte = 0,
                .length = 1,
                .bufbyte = 0,
            };
            const node_idx = res.span_bbt.insertNodeBefore(last_span, .root) catch @panic("oom");
            res._ensureInIdMap(last_span.id, last_span.start_segbyte, node_idx);

            return res;
        }
        pub fn deinit(self: *Doc) void {
            var sm_iter = self.segment_id_map.iterator();
            while (sm_iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.on_before_simple_operation.deinit();
            self.on_after_simple_operation.deinit();
            self.segment_id_map.deinit();
            self.span_bbt.deinit();
            self.buffer.deinit();
            self.* = undefined;
        }

        pub fn positionFromDocbyte(self: *const Doc, target_docbyte: u64) Position {
            const span = self.span_bbt.findNodeForQuery(Span.Count.DocbyteQuery{ .docbyte = target_docbyte });
            if (span == .none or span == .root) @panic("positionFromDocbyte out of range");
            const span_data = self.span_bbt.getNodeDataPtrConst(span).?;
            std.debug.assert(!span_data.deleted());
            const span_position = self.span_bbt.getCountForNode(span);
            const res_position: Position = .{
                .id = span_data.id,
                // I don't understand why span_data includes start_segbyte?
                .segbyte = span_data.start_segbyte + (target_docbyte - span_position.byte_count),
            };
            if (@import("builtin").is_test) self.assertRoundTrip(res_position);
            return res_position;
        }
        pub fn docbyteFromPosition(self: *const Doc, position: Position) u64 {
            const res = self._findEntrySpan(position);
            if (@import("builtin").is_test) self.assertRoundTrip(self.positionFromDocbyte(res.position_docbyte));
            return res.position_docbyte;
        }

        fn assertRoundTrip(self: *const Doc, position: Position) void {
            // make sure round trip lynColFromPosition -> positionFromLynCol same
            const lyn_col = self.lynColFromPosition(position);
            const pos = self.positionFromLynCol(lyn_col);
            std.debug.assert(pos.?.id == position.id and pos.?.segbyte == position.segbyte);
        }

        pub fn lynColFromPosition(self: *const Doc, position: Position) LynCol {
            const res = self._findEntrySpan(position);
            const span_data = self.span_bbt.getNodeDataPtrConst(res.span_index).?;
            const span_count = self.span_bbt.getCountForNode(res.span_index);

            var subarray_portion = span_data.*;
            subarray_portion.length = if (span_data.deleted()) 0 else res.spanbyte_incl_deleted;
            const subarray_count = subarray_portion.count(&self.span_bbt);
            const total_count = span_count.add(subarray_count);
            return .{ .lyn = total_count.newline_count, .col = total_count.bytes_after_newline_count };
        }
        pub fn positionFromLynCol(self: *const Doc, lyn_col: LynCol) ?Position {
            const span = self.span_bbt.findNodeForQuery(Span.Count.LynColQuery{ .lyn = lyn_col.lyn, .col = lyn_col.col });
            if (span == .none or span == .root) return null; // not found
            const span_data = self.span_bbt.getNodeDataPtrConst(span).?;
            std.debug.assert(!span_data.deleted());
            var current_position = self.span_bbt.getCountForNode(span);
            // now we have to walk
            const slice = self.buffer.items[span_data.bufbyte.?..][0..span_data.length];
            for (slice, 0..) |char, i| {
                switch (std.math.order(current_position.newline_count, lyn_col.lyn)) {
                    .lt => {},
                    .eq => switch (std.math.order(current_position.bytes_after_newline_count, lyn_col.col)) {
                        .lt => {},
                        .eq => return .{ .id = span_data.id, .segbyte = span_data.start_segbyte + i },
                        .gt => return null,
                    },
                    .gt => return null,
                }

                current_position.byte_count += 1;
                current_position.bytes_after_newline_count += 1;
                if (char == '\n') {
                    current_position.newline_count += 1;
                    current_position.bytes_after_newline_count = 0;
                }
            }
            std.debug.assert(current_position.newline_count != lyn_col.lyn and current_position.bytes_after_newline_count != lyn_col.col);
            return null;
        }

        pub const EntryIndex = struct {
            span_index: BBT.NodeIndex,
            span_start_docbyte: u64,
            position_docbyte: u64,
            spanbyte_incl_deleted: u64,
        };
        fn _findEntrySpan(self: *const Doc, position: Position) EntryIndex {
            // this should be:
            // - self.span_index_to_segments_map:
            //   - find the span that covers the position.segbyte
            //   - get the count of that span and return

            const seg_al = self.segment_id_map.getEntry(position.id) orelse @panic("bad findEntrySpan");
            var res: ?BBT.NodeIndex = null;
            for (seg_al.value_ptr.items) |span_idx| {
                const span = self.span_bbt.getNodeDataPtrConst(span_idx).?;
                if (position.segbyte >= span.start_segbyte) {
                    res = span_idx;
                } else break;
            }
            const span = res.?;

            const span_data = self.span_bbt.getNodeDataPtrConst(span).?;
            const span_count = self.span_bbt.getCountForNode(span);
            return .{
                .span_index = span,
                .span_start_docbyte = span_count.byte_count,
                .position_docbyte = span_count.byte_count + (if (span_data.deleted()) (0) else (position.segbyte) - span_data.start_segbyte),
                .spanbyte_incl_deleted = position.segbyte - span_data.start_segbyte,
            };
        }
        pub fn read(self: *const Doc, start: Position) []const u8 {
            var it = self.readIterator(start);
            return it.next() orelse "";
        }
        pub fn readLeft(self: *const Doc, start: Position) []const u8 {
            const start_docbyte = self.docbyteFromPosition(start);
            if (start_docbyte == 0) return "";
            const target_span = self.positionFromDocbyte(start_docbyte - 1);
            const target_span_info = self._findEntrySpan(target_span);
            const target_segbyte = target_span.segbyte + 1;
            const target_span_cont = self.span_bbt.getNodeDataPtrConst(target_span_info.span_index).?;
            const rlres = self.buffer.items[usi(target_span_cont.bufbyte.?)..][0..usi(target_segbyte - target_span_cont.start_segbyte)];
            return rlres;
        }
        pub fn readIterator(self: *const Doc, start: Position) ReadIterator {
            const start_posinfo = self._findEntrySpan(start);
            const it = self.span_bbt.iterator(.{ .leftmost_node = start_posinfo.span_index, .skip_most_empties = true });
            return .{
                .doc = self,
                .span_it = it,
                .start_docbyte = start_posinfo.position_docbyte,
                .sliced = false,
            };
        }
        const ReadIterator = struct {
            doc: *const Doc,
            span_it: BBT.Iterator,
            start_docbyte: u64,
            sliced: bool,

            pub fn next(self: *ReadIterator) ?[]const u8 {
                const span_index = self.span_it.next() orelse return null;
                const span = self.doc.span_bbt.getNodeDataPtrConst(span_index).?;
                if (span.deleted()) return "";
                if (span.id == .end) return null;
                const span_text = self.doc.buffer.items[usi(span.bufbyte.?)..][0..usi(span.length)];
                if (self.sliced) return span_text;

                const span_count = self.doc.span_bbt.getCountForNode(span_index);
                self.sliced = true;

                if (self.start_docbyte >= span_count.byte_count) {
                    const diff = self.start_docbyte - span_count.byte_count;
                    std.debug.assert(diff <= span_text.len);
                    const span_text_sub = span_text[usi(diff)..];
                    return span_text_sub;
                } else {
                    return span_text;
                }
            }
        };
        pub fn readSlice(self: *const Doc, start: Position, result_in: []T) void {
            if (result_in.len == 0) return;
            var result = result_in;
            var it = self.readIterator(start);
            while (it.next()) |seg| {
                const minlen = @min(result.len, seg.len);
                @memcpy(result[0..minlen], seg[0..minlen]);
                result = result[minlen..];
                if (result.len == 0) return;
            }
            @panic("readSlice result_in too long");
        }

        fn _removeFromIdMap(self: *Doc, seg: SegmentID, idx: BBT.NodeIndex) void {
            const gpres = self.segment_id_map.getPtr(seg) orelse @panic("cannot remove if not found1");
            const insert_idx: usize = for (gpres.items, 0..) |itm, i| {
                if (itm == idx) break i;
            } else @panic("cannot remove if not found2");
            gpres.replaceRangeAssumeCapacity(insert_idx, 1, &.{});
        }
        fn _ensureInIdMap(self: *Doc, seg: SegmentID, start: u64, idx: BBT.NodeIndex) void {
            const ptr = switch (self.panic_on_modify_segment_id_map) {
                // getOrPut mutates the pointer if there is 0 remaining capacity even if the item is found.
                // so if we're not allowed to mutate, we need to use getPtr.
                true => self.segment_id_map.getPtr(seg).?,
                false => blk: {
                    const gpres = self.segment_id_map.getOrPut(seg) catch @panic("oom");
                    if (!gpres.found_existing) {
                        if (self.panic_on_modify_segment_id_map) @panic("not allowed to modify id map right now");
                        gpres.value_ptr.* = .init(self.allocator);
                    }
                    break :blk gpres.value_ptr;
                },
            };
            const insert_idx: usize = for (ptr.items, 0..) |itm, i| {
                const itmv = self.span_bbt.getNodeDataPtrConst(itm).?;
                if (start < itmv.start_segbyte) {
                    break i;
                }
            } else ptr.items.len;
            ptr.replaceRange(insert_idx, 0, &[_]BBT.NodeIndex{idx}) catch @panic("oom");
        }

        fn _getSimpleOp(self: *Doc, position: BBT.NodeIndex, remove: ?*const Span, insert: *const Span) EmitSimpleOperation {
            const posbyte = blk: {
                const posinfo = self.span_bbt.getNodeDataPtrConst(position) orelse {
                    break :blk self.length();
                };
                break :blk self.docbyteFromPosition(.{ .id = posinfo.id, .segbyte = posinfo.start_segbyte });
            };

            return .{
                .position = posbyte,
                .delete_len = if (remove) |rm| rm.count(&self.span_bbt).byte_count else 0,
                .insert_text = if (insert.bufbyte) |bb| self.buffer.items[usi(bb)..][0..usi(insert.length)] else "",
            };
        }

        /// insertBefore and updateNode are the only allowed ways to mutate the span bbt
        fn _updateNode(self: *Doc, index: BBT.NodeIndex, next_value: Span) void {
            const prev_value = self.span_bbt.getNodeDataPtrConst(index).?;

            const simple_op = self._getSimpleOp(index, prev_value, &next_value);
            self.on_before_simple_operation.emit(simple_op);

            self._removeFromIdMap(prev_value.id, index);
            self.span_bbt.updateNode(index, next_value);
            self._ensureInIdMap(next_value.id, next_value.start_segbyte, index);

            self.on_after_simple_operation.emit(simple_op);
        }
        /// insertBefore and updateNode are the only allowed ways to mutate the span bbt
        fn _insertBefore(self: *Doc, after_index: BBT.NodeIndex, values: []const Span) void {
            for (values) |value| {
                const simple_op = self._getSimpleOp(after_index, null, &value);
                self.on_before_simple_operation.emit(simple_op);

                const node_idx = self.span_bbt.insertNodeBefore(value, after_index) catch @panic("oom");
                self._ensureInIdMap(value.id, value.start_segbyte, node_idx);

                self.on_after_simple_operation.emit(simple_op);
            }
        }
        fn _insertAfter(self: *Doc, before_index: BBT.NodeIndex, values: []const Span) void {
            var it = self.span_bbt.iterator(.{ .leftmost_node = before_index });
            _ = it.next().?;
            self._insertBefore(it.node, values);
        }
        fn _replaceRange(self: *Doc, index: BBT.NodeIndex, delete_count: usize, next_slice: []const Span) void {
            if (delete_count != 1) @panic("TODO replaceRange with non-1 deleteCount");
            if (next_slice.len < 1) @panic("TODO replaceRange with next_slice len lt 1");
            // hack to prevent modifying final "\x00". simple operations should never be emitted covering the last byte.
            if (next_slice[next_slice.len - 1].id == .end) {
                return self._insertBefore(index, next_slice[0 .. next_slice.len - 1]);
            }
            self._updateNode(index, next_slice[0]);
            self._insertAfter(index, next_slice[1..]);
        }

        fn splitSpan(self: *Doc, pos: Position) void {
            const span_position = self._findEntrySpan(pos);
            const span_index = span_position.span_index;
            const span = self.span_bbt.getNodeDataPtrConst(span_index).?;
            const split_spanbyte = pos.segbyte - span.start_segbyte;

            const e_lhs: Span = .{
                .id = span.id,
                .start_segbyte = span.start_segbyte,
                .bufbyte = span.bufbyte,
                .length = split_spanbyte,
            };
            const e_rhs: Span = .{
                .id = span.id,
                .start_segbyte = span.start_segbyte + split_spanbyte,
                .bufbyte = if (span.bufbyte) |bufbyte| bufbyte + split_spanbyte else null,
                .length = span.length - split_spanbyte,
            };

            std.debug.assert(e_rhs.length > 0);
            if (e_lhs.length != 0) {
                self._replaceRange(span_index, 1, &.{
                    e_lhs,
                    e_rhs,
                });
            }
        }

        pub fn applyOperation(self: *Doc, operation_serialized: bi.AlignedByteSlice, undo_operation: ?*bi.UndoOperationWriter(Operation)) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const op_dsrlz = try Operation.deserialize(arena.allocator(), operation_serialized);
            // ^ need to validate, or we can validate at usafe in fn applyOperationStruct

            applyOperationStruct(self, op_dsrlz, undo_operation);
        }
        pub fn applyOperationStruct(self: *Doc, op: Operation, out_undo: ?*bi.UndoOperationWriter(Operation)) void {
            // TODO applyOperation should return the inverse operation for undo
            // insert(3, "hello") -> delete(3, 5)
            // delete(3, 5) -> undelete(3, "hello")
            // extend(3, "hello") -> delete(3, 5)
            // move(@1: 3-5, @2: 6) -> move(@2: 6-8, @1: 3) (inverse move operations may need to split into multiple operations)
            switch (op) {
                .move => |move_op| {
                    if (out_undo) |_| {
                        @panic("TODO support undo move operation");
                    }
                    _ = move_op;
                    @panic("TODO physically move nodes.");
                    // implementation:
                    // - go to start. split the node to [A, B]
                    // - go to start + segment_len. split the node to [C, D]
                    // - go to end. split the node to [E, F]
                    // - move all nodes from B to C to between E and F
                    // This will require implementing delete for BalancedBinaryTree.
                    // - Deleted pointers can be put in an ArrayList to be reused (push / pop).
                },
                .insert => |insert_op| {
                    std.debug.assert(insert_op.text.len > 0);

                    if (out_undo) |undo| undo.appendOperation(.{
                        .delete = .{
                            .start = .{ .id = insert_op.id, .segbyte = 0 },
                            .len_within_segment = insert_op.text.len,
                        },
                    });

                    const added_data_bufbyte = self.buffer.items.len;
                    self.buffer.appendSlice(insert_op.text) catch @panic("OOM");

                    self.splitSpan(insert_op.pos);
                    const entry_span = self._findEntrySpan(insert_op.pos);
                    std.debug.assert(entry_span.spanbyte_incl_deleted == 0);
                    self._insertBefore(entry_span.span_index, &.{.{
                        .id = insert_op.id,
                        .start_segbyte = 0,
                        .bufbyte = @intCast(added_data_bufbyte),
                        .length = @intCast(insert_op.text.len),
                    }});
                },
                .delete => |delete_op| {
                    if (out_undo) |uo| {
                        // if the delete range covers already-deleted parts, this won't work right
                        // genOperations should never generate a delete operation like that though.

                        // stealing self.buffer to allocate a temporary array. this is hacky, we should be using an arena,
                        // maybe passed into out_undo for example
                        const orig_len = self.buffer.items.len;
                        const tmp_slice = self.buffer.addManyAsSlice(delete_op.len_within_segment) catch @panic("oom");
                        defer self.buffer.items.len = orig_len;

                        self.readSlice(delete_op.start, tmp_slice);

                        uo.appendOperation(.{ .replace = .{
                            .start = delete_op.start,
                            .text = tmp_slice,
                        } });
                    }

                    self.panic_on_modify_segment_id_map = true;
                    defer self.panic_on_modify_segment_id_map = false;
                    const affected_spans_al_entry = self.segment_id_map.getEntry(delete_op.start.id).?;
                    // this won't invalidate because panic_on_modify_segment_id_map is set
                    const affected_spans_al = affected_spans_al_entry.value_ptr;

                    var i: usize = 0;
                    for (affected_spans_al.items, 0..) |itm, i_in| {
                        const span = self.span_bbt.getNodeDataPtrConst(itm).?;
                        if (delete_op.start.segbyte >= span.start_segbyte) {
                            i = i_in;
                        } else {
                            break;
                        }
                    }
                    const success = while (i < affected_spans_al.items.len) : (i += 1) {
                        var span_idx = affected_spans_al.items[i];
                        var span = self.span_bbt.getNodeDataPtrConst(span_idx).?;

                        // split affected start portion
                        if (delete_op.start.segbyte >= span.start_segbyte) {
                            const split_spanbyte = delete_op.start.segbyte - span.start_segbyte;
                            const left_side: Span = .{
                                .id = span.id,
                                .start_segbyte = span.start_segbyte,
                                .bufbyte = span.bufbyte,
                                .length = split_spanbyte,
                            };
                            const right_side: Span = .{
                                .id = span.id,
                                .start_segbyte = span.start_segbyte + split_spanbyte,
                                .bufbyte = if (span.bufbyte) |bufbyte| bufbyte + split_spanbyte else null,
                                .length = span.length - split_spanbyte,
                            };
                            std.debug.assert(right_side.length > 0);
                            if (left_side.length > 0) {
                                self._replaceRange(span_idx, 1, &.{
                                    left_side,
                                    right_side,
                                });
                                i += 1;
                                span_idx = affected_spans_al.items[i];
                                span = self.span_bbt.getNodeDataPtrConst(span_idx).?;
                            }
                        }
                        // split affected end portion
                        var did_split_end = false;
                        if (delete_op.start.segbyte + delete_op.len_within_segment < span.start_segbyte + span.length) {
                            did_split_end = true;
                            const split_spanbyte = (delete_op.start.segbyte + delete_op.len_within_segment) - span.start_segbyte;
                            const left_side: Span = .{
                                .id = span.id,
                                .start_segbyte = span.start_segbyte,
                                .bufbyte = span.bufbyte,
                                .length = split_spanbyte,
                            };
                            const right_side: Span = .{
                                .id = span.id,
                                .start_segbyte = span.start_segbyte + split_spanbyte,
                                .bufbyte = if (span.bufbyte) |bufbyte| bufbyte + split_spanbyte else null,
                                .length = span.length - split_spanbyte,
                            };
                            if (left_side.length > 0) {
                                self._replaceRange(span_idx, 1, &.{
                                    left_side,
                                    right_side,
                                });
                                span = self.span_bbt.getNodeDataPtrConst(span_idx).?;
                            }
                        }

                        // mark deleted
                        self._replaceRange(span_idx, 1, &.{
                            .{
                                .id = span.id,
                                .start_segbyte = span.start_segbyte,
                                .bufbyte = null,
                                .length = span.length,
                            },
                        });
                        span = self.span_bbt.getNodeDataPtrConst(span_idx).?;

                        if (did_split_end or span.start_segbyte + span.length == delete_op.start.segbyte + delete_op.len_within_segment) {
                            break true; // done
                        }
                    } else false;
                    std.debug.assert(success);
                },
                .extend => |extend_op| {
                    if (out_undo) |undo| undo.appendOperation(.{
                        .delete = .{
                            .start = .{ .id = extend_op.id, .segbyte = extend_op.prev_len },
                            .len_within_segment = extend_op.text.len,
                        },
                    });

                    const affected_spans_al_entry = self.segment_id_map.getEntry(extend_op.id).?;
                    const affected_spans_al = affected_spans_al_entry.value_ptr;
                    const prev_span_idx = affected_spans_al.getLastOrNull().?;
                    const prev_span = self.span_bbt.getNodeDataPtrConst(prev_span_idx).?;

                    std.debug.assert(prev_span.start_segbyte + prev_span.length == extend_op.prev_len);

                    const newstr_start_bufbyte = self.buffer.items.len;
                    self.buffer.appendSlice(extend_op.text) catch @panic("oom");
                    if (!prev_span.deleted() and prev_span.bufbyte.? + prev_span.length == newstr_start_bufbyte) {
                        self._replaceRange(prev_span_idx, 1, &.{
                            .{
                                .id = prev_span.id,
                                .start_segbyte = prev_span.start_segbyte,
                                .bufbyte = prev_span.bufbyte,
                                .length = @intCast(prev_span.length + extend_op.text.len),
                            },
                        });
                    } else {
                        // have to make a new span
                        self._insertAfter(prev_span_idx, &.{
                            .{
                                .id = prev_span.id,
                                .start_segbyte = @intCast(prev_span.start_segbyte + prev_span.length),
                                .bufbyte = @intCast(newstr_start_bufbyte),
                                .length = @intCast(extend_op.text.len),
                            },
                        });
                    }
                },
                .replace => |replace_op| {
                    if (out_undo) |_| {
                        // this is almost really simple. we almost just generate a replace op with the
                        // existing text. the problem is that the previous text may have had deleted ranges.
                        // so what we want really is a combined delete-replace operation. you say
                        // 'delete_replace' <segment id> <start segbyte> and then pass a slice.
                        // it could have
                        // <length><new data><length><new data><length | deleted><length><new data>...
                        //
                        // the entirety of applyOperation is really complicated right now - we would like to make
                        // it much simpler to say .splitSpan(split_position). maybe we work on that first.
                        @panic("TODO support undo replace operation");
                    }

                    const affected_spans = blk: {
                        const affected_spans_al_entry = self.segment_id_map.getEntry(replace_op.start.id).?;
                        const affected_spans_al = affected_spans_al_entry.value_ptr;
                        // affected_spans_al will be mutated when `replaceRange` is called, so we make a stable copy of it

                        break :blk self.segment_id_map.allocator.dupe(BBT.NodeIndex, affected_spans_al.items) catch @panic("oom");
                    };
                    defer self.segment_id_map.allocator.free(affected_spans);

                    const op_start_segbyte = replace_op.start.segbyte;
                    const op_end_segbyte = op_start_segbyte + replace_op.text.len;

                    for (affected_spans) |affected_span_idx| {
                        // right we have to call replaceRange to update a span
                        // replaceRange

                        const span_value = self.span_bbt.getNodeDataPtrConst(affected_span_idx).?;

                        const span_start_segbyte = span_value.start_segbyte;
                        const span_end_segbyte = span_start_segbyte + span_value.length;

                        const op_clamped_start_segbyte = @max(op_start_segbyte, span_start_segbyte);
                        const op_clamped_end_segbyte = @min(op_end_segbyte, span_end_segbyte);

                        // branches:
                        // - out of range
                        if (op_clamped_start_segbyte >= op_clamped_end_segbyte) {
                            // - skip
                            continue;
                        }

                        const span_start_offset = op_clamped_start_segbyte - span_start_segbyte;
                        const op_start_offset = op_clamped_start_segbyte - replace_op.start.segbyte;
                        const clamped_length = op_clamped_end_segbyte - op_clamped_start_segbyte;
                        const replace_contents = replace_op.text[usi(op_start_offset)..][0..usi(clamped_length)];

                        if (span_value.bufbyte) |bufbyte| {
                            // - not deleted and partial or full coverage:
                            // update buffer
                            const full_range = self.buffer.items[usi(bufbyte)..][0..usi(span_value.length)];
                            const update_range = full_range[usi(span_start_offset)..][0..usi(clamped_length)];
                            @memcpy(update_range, replace_contents);

                            // update newline points
                            self._replaceRange(affected_span_idx, 1, &.{span_value.*});
                        } else if (clamped_length == span_value.length) {
                            const new_bufbyte_start = self.buffer.items.len;
                            self.buffer.appendSlice(replace_contents) catch @panic("oom");
                            self._replaceRange(affected_span_idx, 1, &.{.{
                                .id = span_value.id,
                                .length = span_value.length,
                                .start_segbyte = span_value.start_segbyte,
                                .bufbyte = new_bufbyte_start,
                            }});
                        } else {
                            // - deleted and partial coverage:
                            //   - have to split and mark just one span undeleted
                            //   - for now we can panic("TODO")
                            //   - ideally we should have a split function because it's such a common operation
                            @panic("TODO 'replace' op deleted partial coverage branch");
                        }
                    }
                },
            }
        }

        pub fn length(self: *const Doc) u64 {
            const res_count = self.span_bbt.getCountForNode(.root).byte_count;
            std.debug.assert(res_count >= 1); // must contain at least "\x00"
            return res_count - 1;
        }

        pub fn genOperations(self: *Doc, res: *std.ArrayList(Operation), simple: SimpleOperation) void {
            const pos = simple.position;
            const delete_count = simple.delete_len;
            const insert_text = simple.insert_text;

            // 1. generate delete operation
            //     - this is going to be annoying because we chose to make seperate delete operations
            //       per segment id
            if (delete_count != 0) {
                const span_position = self._findEntrySpan(pos);
                const doc_start_docbyte = span_position.position_docbyte;
                const doc_end_docbyte = doc_start_docbyte + delete_count;
                // std.log.info("pos: {}, start byte: {d}, end byte: {d} / {d}", .{pos, doc_start_docbyte, doc_end_docbyte, self.length});
                std.debug.assert(doc_end_docbyte <= self.length());

                var span_start_docbyte = span_position.span_start_docbyte;
                var iter = self.span_bbt.iterator(.{ .leftmost_node = span_position.span_index, .skip_most_empties = true });
                while (span_start_docbyte < doc_end_docbyte) {
                    const span_i = iter.next() orelse @panic("delete out of range");
                    const span = self.span_bbt.getNodeDataPtrConst(span_i).?;
                    if (span.id == .end) @panic("unreachable");

                    if (span.deleted()) continue;

                    const span_end_docbyte = span_start_docbyte + span.length;
                    const target_start_docbyte = @max(span_start_docbyte, doc_start_docbyte);
                    const target_end_docbyte = @min(span_end_docbyte, doc_end_docbyte);
                    const target_segbyte = target_start_docbyte - span_start_docbyte + span.start_segbyte;
                    const target_seglen = target_end_docbyte - target_start_docbyte;
                    std.debug.assert(target_seglen > 0);

                    res.append(.{
                        .delete = .{
                            .start = .{
                                .id = span.id,
                                .segbyte = @intCast(target_segbyte),
                            },
                            .len_within_segment = @intCast(target_seglen),
                        },
                    }) catch @panic("oom");

                    span_start_docbyte += span.length;
                }
            }
            // 2. generate insert operation
            if (insert_text.len == 0) return;
            blk: {
                // generate an 'extend' operation if applicable
                const span_position = self._findEntrySpan(pos);
                if (span_position.spanbyte_incl_deleted != 0) break :blk;
                if (span_position.position_docbyte == 0) break :blk;
                const prev_position = self.positionFromDocbyte(span_position.position_docbyte - 1);
                const prev_v = self._findEntrySpan(prev_position);
                const prev_data = self.span_bbt.getNodeDataPtrConst(prev_v.span_index).?;

                // check if valid
                std.debug.assert(!prev_data.deleted());

                // check if span is allowed
                if (prev_data.id.owner() != self.client_id) break :blk;

                const entry = self.segment_id_map.getEntry(prev_data.id).?;
                if (entry.value_ptr.getLast() != prev_v.span_index) {
                    // invalid; not at end of array
                    break :blk;
                }

                // valid!
                res.append(.{
                    .extend = .{
                        .id = prev_data.id,
                        .prev_len = prev_data.start_segbyte + prev_data.length,
                        .text = insert_text,
                    },
                }) catch @panic("oom");
                return;
            }
            res.append(.{
                .insert = .{
                    .id = self.uuid(),
                    .pos = pos,
                    .text = insert_text,
                },
            }) catch @panic("oom");
        }

        pub fn uuid(self: *Doc) SegmentID {
            defer self.next_uuid += 1;
            return @enumFromInt((@as(u64, self.next_uuid) << 16) | self.client_id);
        }

        pub const Viewer = struct {
            doc: *Document,
            index: usize,
            sub_index: usize,

            pub fn read() u8 {}
            pub fn move(self: *Viewer, count: isize) void {
                _ = self;
                _ = count;
            }
            // Viewer from position 10
            // Viewer.read()
            // Viewer.move(5)
            // Viewer.read()
            // Viewer.rightToNextLineStart
            // Viewer.leftToNextLineStart
            // Viewer. ...
        };
    };
}

fn testBlockEquals(block: *TextDocument, target: []const u8) !void {
    const gpa = block.buffer.allocator;

    try std.testing.expectEqual(target.len, block.length());

    const actual = try gpa.alloc(u8, target.len);
    defer gpa.free(actual);
    block.readSlice(block.positionFromDocbyte(0), actual);
    try std.testing.expectEqualStrings(target, actual);
}

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const gpa = gpa_alloc.allocator();

    try testSampleBlock(gpa);

    const testdocument_len = switch (@import("builtin").mode) {
        .Debug => 100_000,
        else => 1_000_000,
    };

    const parent_progress_node = std.Progress.start(.{});
    defer parent_progress_node.end();

    const progress_node = parent_progress_node.start("testDocument()", testdocument_len);
    defer progress_node.end();

    var dur_measure = try std.time.Timer.start();
    const testres = try testDocument(gpa, testdocument_len, progress_node);
    const dur = dur_measure.read();
    std.log.info("testDocument({d}) spans in in {d}", .{ testdocument_len, std.fmt.fmtDuration(dur) });
    // std.log.info("- nspans: {d}", .{testres.spans_len});
    std.log.info("- max len: {d}", .{testres.max_len});
    inline for (std.meta.fields(Timings)) |timing_field| {
        std.log.info("- {s} dur: {d}", .{ timing_field.name, std.fmt.fmtDuration(@field(testres.timings, timing_field.name)) });
    }
    std.log.info("- height: {d}", .{testres.final_height});
}
pub const std_options = .{ .log_level = .info };

fn testSampleBlock(gpa: std.mem.Allocator) !void {
    var block = TextDocument.initEmpty(gpa);
    defer block.deinit();

    std.log.info("block: [{}]", .{block});

    var opgen_demo = std.ArrayList(TextDocument.Operation).init(gpa);
    defer opgen_demo.deinit();

    const b0 = block.positionFromDocbyte(0);
    std.log.info("pos: {}", .{b0});
    std.debug.assert(block.length() == 0);

    block.applyOperationStruct(.{
        .insert = .{
            .id = block.uuid(),
            .pos = block.positionFromDocbyte(0),
            .text = "i held",
        },
    }, null);
    try testBlockEquals(&block, "i held");
    std.log.info("block: [{}]", .{block});

    block.applyOperationStruct(.{
        .insert = .{
            .id = block.uuid(),
            .pos = block.positionFromDocbyte(4),
            .text = "llo wor",
        },
    }, null);
    try testBlockEquals(&block, "i hello world");
    std.log.info("block: [{}]", .{block});
    block.applyOperationStruct(.{
        // deleting a range will generate multiple delete operations unfortunately
        .delete = .{
            .start = block.positionFromDocbyte(0),
            .len_within_segment = 2,
        },
    }, null);
    try testBlockEquals(&block, "hello world");
    std.log.info("block: {d}[{}]", .{ block.length(), block });
    block.applyOperationStruct(.{
        .extend = .{
            .id = block.positionFromDocbyte(2).id,
            .prev_len = 7,
            .text = "R",
        },
    }, null);
    try testBlockEquals(&block, "hello worRld");
    std.log.info("block: [{}]", .{block});

    block.applyOperationStruct(.{
        .extend = .{
            .id = block.positionFromDocbyte(0).id,
            .prev_len = 6,
            .text = "!",
        },
    }, null);
    try testBlockEquals(&block, "hello worRld!");
    std.log.info("block: [{}]", .{block});

    opgen_demo.clearRetainingCapacity();
    block.genOperations(&opgen_demo, .{ .position = block.positionFromDocbyte(0), .delete_len = 0, .insert_text = "Test\n" });
    for (opgen_demo.items) |op| {
        std.log.info("  apply {}", .{op});
        block.applyOperationStruct(op, null);
    }
    try testBlockEquals(&block, "Test\nhello worRld!");
    std.log.info("block: [{}]", .{block});

    opgen_demo.clearRetainingCapacity();
    block.genOperations(&opgen_demo, .{ .position = block.positionFromDocbyte(1), .delete_len = 18 - 2, .insert_text = "Cleared." });
    for (opgen_demo.items) |op| {
        std.log.info("  apply {}", .{op});
        block.applyOperationStruct(op, null);
    }
    try testBlockEquals(&block, "TCleared.!");
    std.log.info("block: [{}]", .{block});

    // replace live text
    opgen_demo.clearRetainingCapacity();
    block.applyOperationStruct(.{ .replace = .{
        .start = block.positionFromDocbyte(1),
        .text = "Replaced",
    } }, null);
    try testBlockEquals(&block, "TReplaced!");
    std.log.info("block: [{}]", .{block});

    // replace part of live text
    opgen_demo.clearRetainingCapacity();
    block.applyOperationStruct(.{ .replace = .{
        .start = block.positionFromDocbyte(4),
        .text = "!!!!",
    } }, null);
    try testBlockEquals(&block, "TRep!!!!d!");
    std.log.info("block: [{}]", .{block});

    // bring back full dead text
    opgen_demo.clearRetainingCapacity();
    block.applyOperationStruct(.{ .replace = .{
        .start = .{ .id = @enumFromInt(3 << 16), .segbyte = 1 },
        .text = "ABCD",
    } }, null);
    try testBlockEquals(&block, "TRep!!!!dABCD!");
    std.log.info("block: [{}]", .{block});

    // bring back part of dead text
    if (false) {
        @panic("TODO");
    }

    // move text
    if (false) {
        block.applyOperationStruct(.{
            .move = .{
                .start = block.positionFromDocbyte(2),
                .end = block.positionFromDocbyte(8),
                .len_within_segment = 5,
                .prev_move_id = @enumFromInt(@intFromEnum(block.positionFromDocbyte(2).id)),
                .next_move_id = block.moveUuid(),
            },
        });
        try testBlockEquals(&block, "<todo>");
        std.log.info("block: [{}]", .{block});
    }

    var srlz_al = bi.AlignedArrayList.init(gpa);
    defer srlz_al.deinit();
    block.serialize(&srlz_al);

    std.log.info("result: \"{}\"", .{std.zig.fmtEscapes(srlz_al.items)});
    std.log.info("actual len: {d}, minimum len: {d}, ratio: {d:.2}x more memory used to store spans", .{ srlz_al.items.len, block.length(), @as(f64, @floatFromInt(srlz_al.items.len)) / @as(f64, @floatFromInt(block.length())) });
    // currently each span costs 16 bytes when it could cost less
    // - span lengths can probably be u32? maybe not

    var dsrlz_fbs: bi.AlignedFbsReader = .{ .buffer = srlz_al.items, .pos = 0 };
    var deserialized = try TextDocument.deserialize(gpa, &dsrlz_fbs);
    defer deserialized.deinit();
    std.log.info("deserialized block: {}", .{deserialized});

    var rsrlz_al = bi.AlignedArrayList.init(gpa);
    defer rsrlz_al.deinit();
    deserialized.serialize(&rsrlz_al);

    try std.testing.expectEqualStrings(srlz_al.items, rsrlz_al.items);
}
test "sample block" {
    const gpa = std.testing.allocator;
    try testSampleBlock(gpa);
}

test "document" {
    // this is a fuzz test
    // we can't really use std.testing.fuzz() for it unless we implement a parser or something
    _ = try testDocument(std.testing.allocator, 1_000, null);
}

// fuzz test deserializing random blocks
fn fuzzTest(input_misaligned: []const u8) anyerror!void {
    const gpa = std.testing.allocator;

    const input_aligned = try gpa.alignedAlloc(u8, 16, input_misaligned.len);
    defer gpa.free(input_aligned);
    @memcpy(input_aligned, input_misaligned);

    var ia_fbs = bi.AlignedFbsReader{ .buffer = input_aligned, .pos = 0 };
    if (TextDocument.deserialize(gpa, &ia_fbs)) |deserialized_1| {
        if (ia_fbs.pos < ia_fbs.buffer.len) return error.DeserializeError;

        var deserialized = deserialized_1;
        defer deserialized.deinit();

        // TODO: do some stuff with the block to make sure it's not completely broken

        // reserialize the block and assert it's identical same
        // - if it's not going to be the same, deserialize should have errored
        var rsrlz_al = bi.AlignedArrayList.init(gpa);
        deserialized.serialize(&rsrlz_al);
        try std.testing.expectEqualSlices(u8, input_aligned, rsrlz_al.items);
    } else |_| {
        // error is ok. as long as it doesn't panic.
    }
}
test "fuzz" {
    // not particularily useful until https://github.com/ziglang/zig/issues/20804
    // also waiting on https://github.com/ziglang/zig/issues/20986

    if (@hasDecl(std.testing, "fuzzInput")) return error.SkipZigTest;
    try std.testing.fuzz(fuzzTest, .{});
}

const TestDocumentRetTy = struct {
    timings: Timings,
    max_len: usize,
    final_height: usize,
};
fn testDocument(alloc: std.mem.Allocator, count: usize, progress_node: ?std.Progress.Node) !TestDocumentRetTy {
    std.log.info("testDocument", .{});
    var tester: BlockTester = undefined;
    tester.init(alloc);
    defer tester.deinit();

    try tester.testReplaceRange(0, 0, "Hello");
    try tester.testReplaceRange(5, 0, " World!");

    var rng_random = std.Random.DefaultPrng.init(0);
    const rng = rng_random.random();

    var max_len: usize = 0;

    for (0..count) |_| {
        const insert_pos = rng.intRangeLessThan(u64, 0, tester.complex.length());
        const delete_pos = rng.intRangeLessThan(u64, insert_pos, tester.complex.length());
        const delete_len = delete_pos - insert_pos;

        var random_bytes: [10]u8 = undefined;
        for (&random_bytes) |*byte| byte.* = rng.intRangeAtMost(u8, 'a', 'z');
        const insert_count = rng.intRangeLessThan(u64, 0, random_bytes.len);

        try tester.testReplaceRange(insert_pos, delete_len, random_bytes[0..insert_count]);

        max_len = @max(max_len, tester.complex.length());
        if (progress_node) |n| n.completeOne();
    }

    return .{
        .timings = tester.timings,
        .max_len = max_len,
        .final_height = tester.complex.span_bbt._height(tester.complex.span_bbt.root_node),
    };
}

const Timings = struct {
    simple: u64 = 0,
    complex: u64 = 0,
    test_addManyAsSlice: u64 = 0,
    test_readSlice: u64 = 0,
    test_eql: u64 = 0,
};
const BlockTester = struct {
    alloc: std.mem.Allocator,
    simple: std.ArrayList(u8),
    complex: TextDocument,
    event_mirror: std.ArrayList(u8),

    timings: Timings,

    rendered_result: std.ArrayList(u8),
    opgen: std.ArrayList(TextDocument.Operation),

    pub fn init(self: *BlockTester, alloc: std.mem.Allocator) void {
        self.* = .{
            .alloc = alloc,
            .simple = .init(alloc),
            .complex = .initEmpty(alloc),
            .event_mirror = .init(alloc),

            .timings = .{},

            .rendered_result = .init(alloc),
            .opgen = .init(alloc),
        };
        self.complex.readSlice(self.complex.positionFromDocbyte(0), self.event_mirror.addManyAsSlice(self.complex.length()) catch @panic("oom"));
        self.complex.on_after_simple_operation.addListener(.from(self, onAfterSimpleOperation));
    }
    pub fn deinit(self: *BlockTester) void {
        self.complex.on_after_simple_operation.removeListener(.from(self, onAfterSimpleOperation));
        self.simple.deinit();
        self.complex.deinit();
        self.event_mirror.deinit();
        self.rendered_result.deinit();
        self.opgen.deinit();
    }

    fn onAfterSimpleOperation(self: *BlockTester, op: TextDocument.EmitSimpleOperation) void {
        self.event_mirror.replaceRange(op.position, op.delete_len, op.insert_text) catch @panic("oom");
    }

    pub fn testReplaceRange(self: *@This(), start: u64, delete_count: u64, insert_text: []const u8) !void {
        var timer = try std.time.Timer.start();

        // std.log.info("  replaceRange@{d}:{d}:\"{s}\"", .{start, delete_count, insert_text});
        self.simple.replaceRange(start, delete_count, insert_text) catch @panic("oom");

        self.timings.simple += timer.lap();

        defer self.opgen.clearRetainingCapacity();
        self.complex.genOperations(&self.opgen, .{ .position = self.complex.positionFromDocbyte(start), .delete_len = delete_count, .insert_text = insert_text });
        for (self.opgen.items) |op| {
            // std.log.info("    -> apply {}", .{op});
            self.complex.applyOperationStruct(op, null);
        }
        // std.log.info("  Updated document: [{}], ", .{self.complex});

        self.timings.complex += timer.lap();

        try std.testing.expectEqual(self.simple.items.len, self.complex.length());

        const rendered = self.rendered_result.addManyAsSlice(self.complex.length()) catch @panic("iin");
        defer self.rendered_result.clearRetainingCapacity();
        self.timings.test_addManyAsSlice += timer.lap();

        self.complex.readSlice(self.complex.positionFromDocbyte(0), rendered);
        self.timings.test_readSlice += timer.lap();

        try std.testing.expectEqualStrings(self.simple.items, rendered);
        try std.testing.expectEqualStrings(self.simple.items, self.event_mirror.items);
        self.timings.test_eql += timer.lap();

        if (false) {
            // this is extremely slow!
            // tests deserializing and reserializing the block
            const gpa = self.complex.buffer.allocator;

            var srlz_al = bi.AlignedArrayList.init(gpa);
            defer srlz_al.deinit();
            self.complex.serialize(&srlz_al);

            var deserialized = try TextDocument.deserialize(gpa, srlz_al.items);
            defer deserialized.deinit();

            var rsrlz_al = bi.AlignedArrayList.init(gpa);
            defer rsrlz_al.deinit();
            deserialized.serialize(&rsrlz_al);

            try std.testing.expectEqualStrings(srlz_al.items, rsrlz_al.items);
        }
    }
};

fn usi(a: u64) usize {
    return @intCast(a);
}

// notes:
// currently, typing will insert a lot of table entries
// these will never go away
