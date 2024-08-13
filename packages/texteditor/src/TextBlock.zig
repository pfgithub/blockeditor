//! Definitions:
//! - Document: a rendered text file
//!   - DocByte: index into the document
//! - Segment: all spans that share an id
//!   - SegByte: index into a segment
//! - Span: an individual section of a segment holding a slice of buffer data
//!   - SpanByte: index into a span
//! - Buffer: raw unordered text data referenced by spans
//!    - BufByte: index into the buffer

// THIS FILE IS IN TWO PROJECTS

fn BalancedBinaryTree(comptime Data: type) type {
    return struct {
        // TODO: auto balancing (red/black or bst?)
        // sample red black tree impl: https://github.com/CutieDeng/RBTreeUnmanaged/blob/master/src/root.zig
        // it doesn't support the automated summing, it just has a compare fn. so basically worthless.
        // but it should show how to make the tree.
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

        // if we want to support removing while using an arena, whenever a node
        // gets deleted we could put its pointer in an array and then when creating a new node
        // prefer to pop() the array and write to that pointer over allocating a new one. that's
        // pretty cool.
        arena: std.heap.ArenaAllocator,
        root_node: NodeIndex = .none,

        /// alloc will be wrapped in an arena for memory bookkeeping. so don't pass an arena unless you want a double-arena!
        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .arena = std.heap.ArenaAllocator.init(alloc),
            };
        }
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        fn _addNode(self: *@This(), data: Data) !NodeIndex {
            const slot = try self.arena.allocator().create(Node);
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
        fn _getNodePtrConst(_: *const @This(), node_idx: NodeIndex) ?*Node {
            if (node_idx == .none or node_idx == .root) return null;
            const res: *Node = @ptrFromInt(@intFromEnum(node_idx));
            return res;
        }
        pub fn getNodeDataPtrConst(_: *const @This(), node_idx: NodeIndex) ?*Data {
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
        fn _rebalance(self: *@This(), x_idx: NodeIndex) void {
            const y_idx = self._getParent(x_idx);
            const z_idx = self._getParent(y_idx);
            if (x_idx == .root or y_idx == .root or z_idx == .root) return;
            const y_dir_to_x = self._getChildSide(y_idx, x_idx);
            const z_dir_to_y = self._getChildSide(z_idx, y_idx);

            const z_ptr = self._getNodePtrConst(z_idx) orelse return;
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
            @call(.always_tail, _rebalance, .{ self, self._getParent(x_idx) });
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
                const root_val = self._getNodePtrConst(self.root_node) orelse return Count.zero;
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
                    current_count = current_count.add(parent_ptr.lhs_sum.add(parent_ptr.self_sum));
                }
                current_node = parent;
            }

            return current_count;
        }

        pub fn findNodeForQuery(self: *const @This(), query: anytype) NodeIndex {
            return self._findNodeForQuerySub(self.root_node, query);
        }
        fn _findNodeForQuerySub(self: *const @This(), node_idx: NodeIndex, target: anytype) NodeIndex {
            const node = self._getNodePtrConst(node_idx) orelse return .root;

            const lhs = node.lhs_sum;
            const lhs_plus_center = node.lhs_sum.add(node.self_sum);
            const cmp_res = target.compare(lhs, lhs_plus_center);

            switch (cmp_res) {
                .eq => {
                    // in range (will always be false for a deleted node)
                    return node_idx;
                },
                .gt => {
                    // search rhs
                    return self._findNodeForQuerySub(node.rhs, target.shift(lhs_plus_center));
                },
                .lt => {
                    // search lhs
                    return self._findNodeForQuerySub(node.lhs, target);
                },
            }
        }
        fn iterator(self: *const @This(), opts: IteratorOptions) Iterator {
            var res: Iterator = .{ .tree = self, .node = undefined, .skip_empty = opts.skip_empty };
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
            skip_empty: bool = false,
        };
        const BBT = @This();
        const Iterator = struct {
            tree: *const BBT,
            node: NodeIndex,
            skip_empty: bool = false,

            /// go to the deepest lhs node within the current node
            fn goDeepLhs(self: *Iterator) void {
                while (true) {
                    const lhs = self.tree._getSide(self.node, .left);
                    if (lhs == .none) break;
                    if (self.skip_empty) {
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
            fn shift(q: DocbyteQuery, a: Count) DocbyteQuery {
                return .{ .docbyte = q.docbyte - a.length };
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
    try tree.previewTreeRecursive(std.io.getStdErr().writer().any(), tree.root_node, SampleData.Count.zero);
    try std.io.getStdErr().writer().any().print("\n", .{});
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
};
pub const DeleteID = enum(u64) {
    none = 0,
    _,

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
        const client_id = num & std.math.maxInt(u16);
        try writer.print("-@{d}", .{op_id});
        if (client_id != 0) {
            try writer.print("/{d}", .{client_id});
        }
    }
};

pub const UndoOperation = union(enum) {
    // this shouldn't need to be tagged?
    insert: SegmentID,
    delete: DeleteID,
};

// indices into this are:
// @id.segbyte
// they are stable and don't even need updating!
// - if the cursor position is @4.1, regardless of all the inserts and deletes
//   that happen, the cursor position can stay @4.1
// the only trouble is the table gets bigger over time
// - compaction destroys undo history

pub const TextDocument = Document(u8, 0);
// this is generic, but it doesn't really work for reorderable lists
// - reorderable lists generally you don't want to duplicate items when you
//   move them around, but current implementation would have if two people
//   move an item at the same time it would duplicate it.
pub fn Document(comptime T: type, comptime T_empty: T) type {
    return struct {
        const Doc = @This();
        pub const Operation = union(enum) {
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
                id: DeleteID,
                start: Position,
                len_within_segment: u64,
            },

            pub fn format(
                self: *const @This(),
                comptime _: []const T,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                switch (self.*) {
                    .insert => |iop| {
                        try writer.print("[I:{}:\"{}\"->{}]", .{ iop.pos, std.fmt.fmtSliceEscapeLower(iop.text), iop.id });
                    },
                    .delete => |dop| {
                        try writer.print("[D:{}:{d}->{}]", .{ dop.start, dop.len_within_segment, dop.id });
                    },
                    .extend => |xop| {
                        try writer.print("[X:{}:{d}:\"{}\"]", .{ xop.id, xop.prev_len, std.fmt.fmtSliceEscapeLower(xop.text) });
                    },
                }
            }
        };

        pub const Position = struct {
            id: SegmentID,
            /// can never refer to the last index of a segment
            segbyte: u64,

            pub fn format(
                self: *const @This(),
                comptime _: []const T,
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
        pub const Span = struct {
            enabled_by_id: SegmentID,
            disabled_by_id: DeleteID,
            length: u64,
            start_segbyte: u64,
            bufbyte: u64,

            pub fn format(value: Span, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                if (value.disabled_by_id != .none) {
                    try writer.print("-", .{});
                } else {
                    try writer.print("\"{d}\"", .{value.length});
                }
            }

            fn count(span: *const Span, bbt: *const BalancedBinaryTree(Span)) Count {
                if (span.disabled_by_id != .none) return .{
                    .byte_count = 0,
                    .newline_count = 0,
                };
                const document: *const Doc = @fieldParentPtr("span_bbt", bbt);
                var result = Count{
                    .byte_count = span.length,
                    .newline_count = 0,
                };
                for (document.buffer.items[span.bufbyte..][0..span.length]) |char| {
                    if (char == '\n') result.newline_count += 1;
                }
                return result;
            }
            const Count = struct {
                pub const zero = Count{ .byte_count = 0, .newline_count = 0 };
                byte_count: u64,
                newline_count: u64,

                fn add(a: Count, b: Count) Count {
                    return .{
                        .byte_count = a.byte_count + b.byte_count,
                        .newline_count = a.newline_count + b.newline_count,
                    };
                }
                fn eql(a: Count, b: Count) bool {
                    return std.meta.eql(a, b);
                }
                pub fn format(value: Count, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                    try writer.print("{d}", .{value.byte_count});
                }

                const DocbyteQuery = struct {
                    docbyte: usize,
                    fn compare(q: DocbyteQuery, a: Count, b: Count) std.math.Order {
                        if (q.docbyte < a.byte_count) return .lt;
                        if (q.docbyte >= b.byte_count) return .gt;
                        return .eq;
                    }
                    fn shift(q: DocbyteQuery, a: Count) DocbyteQuery {
                        return .{ .docbyte = q.docbyte - a.byte_count };
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

        client_id: u16,
        /// must not be 0
        next_uuid: u48,

        pub fn format(
            self: *const @This(),
            comptime _: []const T,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            var it = self.span_bbt.iterator(.{});
            var i: usize = 0;
            while (it.next()) |node| : (i += 1) {
                const span = self.span_bbt.getNodeDataPtrConst(node).?;
                if (i != 0) try writer.print(" ", .{});
                if (span.enabled_by_id == .end) {
                    std.debug.assert(span.length == 1);
                    std.debug.assert(span.disabled_by_id == .none);
                    try writer.print("E", .{});
                    continue;
                }
                const span_text = self.buffer.items[span.bufbyte..][0..span.length];
                try writer.print("{}.{d}", .{ span.enabled_by_id, span.start_segbyte });
                if (span.disabled_by_id != .none) try writer.print("{}", .{span.disabled_by_id});
                try writer.print("\"{s}\"", .{std.fmt.fmtSliceEscapeLower(span_text)});
            }
        }

        pub fn initEmpty(alloc: std.mem.Allocator) Doc {
            var res: Doc = .{
                .span_bbt = undefined,
                .buffer = std.ArrayList(T).init(alloc),
                .segment_id_map = SegmentIDMap.init(alloc),
                .allocator = alloc,

                .client_id = 0,
                .next_uuid = 1,
            };
            res.buffer.append(T_empty) catch @panic("oom");

            // spans_bbt uses fieldParentPtr to find the buffer for counting
            // the inserted node, so it must be inside the document when
            // we call insertNodeBefore. It's okay if the pointer moves later.
            res.span_bbt = BalancedBinaryTree(Span).init(alloc);

            res._insertBefore(.root, &[_]Span{
                .{
                    .enabled_by_id = @enumFromInt(0),
                    .disabled_by_id = .none,
                    .start_segbyte = 0,
                    .length = 1,
                    .bufbyte = 0,
                },
            });

            return res;
        }
        pub fn deinit(self: *Doc) void {
            var sm_iter = self.segment_id_map.iterator();
            while (sm_iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.segment_id_map.deinit();
            self.span_bbt.deinit();
            self.buffer.deinit();
            self.* = undefined;
        }

        pub fn positionFromDocbyte(self: *const Doc, target_docbyte: u64) Position {
            const span = self.span_bbt.findNodeForQuery(Span.Count.DocbyteQuery{ .docbyte = target_docbyte });
            if (span == .none or span == .root) @panic("positionFromDocbyte out of range");
            const span_data = self.span_bbt.getNodeDataPtrConst(span).?;
            const span_position = self.span_bbt.getCountForNode(span);
            return .{
                .id = span_data.enabled_by_id,
                // I don't understand why span_data includes start_segbyte?
                .segbyte = span_data.start_segbyte + (target_docbyte - span_position.byte_count),
            };
        }
        pub fn byteOffsetFromPosition(self: *const Doc, position: Position) usize {
            const res = self._findEntryIndex(position);
            return res.span_start_docbyte + res.spanbyte;
        }
        pub const EntryIndex = struct {
            span_index: BBT.NodeIndex,
            span_start_docbyte: usize,
            spanbyte: usize,
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
                .spanbyte = position.segbyte - span_data.start_segbyte,
            };
        }
        pub fn read(self: *const Doc, start: Position) []const u8 {
            var it = self.readIterator(start);
            return it.next() orelse "";
        }
        pub fn readIterator(self: *const Doc, start: Position) ReadIterator {
            const start_posinfo = self._findEntrySpan(start);
            const it = self.span_bbt.iterator(.{ .leftmost_node = start_posinfo.span_index, .skip_empty = true });
            return .{
                .doc = self,
                .span_it = it,
                .start_docbyte = start_posinfo.span_start_docbyte,
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
                if (span.disabled_by_id != .none) return "";
                if (span.enabled_by_id == .end) return null;
                const span_text = self.doc.buffer.items[span.bufbyte..][0..span.length];
                if (self.sliced) return span_text;

                const span_count = self.doc.span_bbt.getCountForNode(span_index);
                self.sliced = true;

                if (self.start_docbyte >= span_count.byte_count) {
                    const diff = self.start_docbyte - span_count.byte_count;
                    std.debug.assert(diff <= span_text.len);
                    const span_text_sub = span_text[diff..];
                    return span_text_sub;
                } else {
                    return span_text;
                }
            }
        };
        pub fn readSlice(self: *const Doc, start: Position, result_in: []T) void {
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
            const gpres = self.segment_id_map.getOrPut(seg) catch @panic("oom");
            if (!gpres.found_existing) @panic("cannot remove if not found1");
            const insert_idx: usize = for (gpres.value_ptr.items, 0..) |itm, i| {
                if (itm == idx) break i;
            } else @panic("cannot remove if not found2");
            gpres.value_ptr.replaceRangeAssumeCapacity(insert_idx, 1, &.{});
        }
        fn _ensureInIdMap(self: *Doc, seg: SegmentID, start: usize, idx: BBT.NodeIndex) void {
            const gpres = self.segment_id_map.getOrPut(seg) catch @panic("oom");
            if (!gpres.found_existing) gpres.value_ptr.* = std.ArrayList(BBT.NodeIndex).init(self.allocator);
            const insert_idx: usize = for (gpres.value_ptr.items, 0..) |itm, i| {
                const itmv = self.span_bbt.getNodeDataPtrConst(itm).?;
                if (start < itmv.start_segbyte) {
                    break i;
                }
            } else gpres.value_ptr.items.len;
            gpres.value_ptr.replaceRange(insert_idx, 0, &[_]BBT.NodeIndex{idx}) catch @panic("oom");
        }
        fn _updateNode(self: *Doc, index: BBT.NodeIndex, next_value: Span) void {
            const prev_value = self.span_bbt.getNodeDataPtrConst(index).?;
            self._removeFromIdMap(prev_value.enabled_by_id, index);
            self.span_bbt.updateNode(index, next_value);
            self._ensureInIdMap(next_value.enabled_by_id, next_value.start_segbyte, index);
        }
        fn _insertBefore(self: *Doc, after_index: BBT.NodeIndex, values: []const Span) void {
            for (values) |value| {
                const node_idx = self.span_bbt.insertNodeBefore(value, after_index) catch @panic("oom");
                self._ensureInIdMap(value.enabled_by_id, value.start_segbyte, node_idx);
            }
        }
        fn _insertAfter(self: *Doc, before_index: BBT.NodeIndex, values: []const Span) void {
            var it = self.span_bbt.iterator(.{ .leftmost_node = before_index });
            _ = it.next();
            self._insertBefore(it.node, values);
        }
        // this is the only allowed way to update the entries array. (this or insertAter/updateNode)
        fn _replaceRange(self: *Doc, index: BBT.NodeIndex, delete_count: usize, next_slice: []const Span) void {
            if (delete_count != 1) @panic("TODO replaceRange with non-1 deleteCount");
            if (next_slice.len < 1) @panic("TODO replaceRange with next_slice len lt 1");
            self._updateNode(index, next_slice[0]);
            self._insertAfter(index, next_slice[1..]);
        }

        pub fn applyOperation(self: *Doc, op: Operation) void {
            switch (op) {
                .insert => |insert_op| {
                    if (insert_op.text.len == 0) return; // nothing to do

                    const added_data_bufbyte = self.buffer.items.len;
                    self.buffer.appendSlice(insert_op.text) catch @panic("OOM");
                    const e_mid: Span = .{
                        .enabled_by_id = insert_op.id,
                        .disabled_by_id = .none,
                        .start_segbyte = 0,
                        .bufbyte = @intCast(added_data_bufbyte),
                        .length = @intCast(insert_op.text.len),
                    };

                    // 0. find entry
                    const span_position = self._findEntrySpan(insert_op.pos);
                    const span_index = span_position.span_index;
                    const span = self.span_bbt.getNodeDataPtrConst(span_index).?;
                    // 1. split entry
                    const split_spanbyte = insert_op.pos.segbyte - span.start_segbyte;

                    const e_lhs: Span = .{
                        .enabled_by_id = span.enabled_by_id,
                        .disabled_by_id = span.disabled_by_id,
                        .start_segbyte = span.start_segbyte,
                        .bufbyte = span.bufbyte,
                        .length = split_spanbyte,
                    };
                    const e_rhs: Span = .{
                        .enabled_by_id = span.enabled_by_id,
                        .disabled_by_id = span.disabled_by_id,
                        .start_segbyte = span.start_segbyte + split_spanbyte,
                        .bufbyte = span.bufbyte + split_spanbyte,
                        .length = span.length - split_spanbyte,
                    };

                    // done! above pointers are invalidated after this
                    std.debug.assert(e_mid.length > 0);
                    std.debug.assert(e_rhs.length > 0);
                    if (e_lhs.length == 0) {
                        self._replaceRange(span_index, 1, &.{
                            e_mid,
                            e_rhs,
                        });
                    } else {
                        self._replaceRange(span_index, 1, &.{
                            e_lhs,
                            e_mid,
                            e_rhs,
                        });
                    }
                },
                .delete => |delete_op| {
                    const affected_spans_al_entry = self.segment_id_map.getEntry(delete_op.start.id).?;
                    // this shouldn't invalidate because the hashmap shouldn't get any new entries
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
                                .enabled_by_id = span.enabled_by_id,
                                .disabled_by_id = span.disabled_by_id,
                                .start_segbyte = span.start_segbyte,
                                .bufbyte = span.bufbyte,
                                .length = split_spanbyte,
                            };
                            const right_side: Span = .{
                                .enabled_by_id = span.enabled_by_id,
                                .disabled_by_id = span.disabled_by_id,
                                .start_segbyte = span.start_segbyte + split_spanbyte,
                                .bufbyte = span.bufbyte + split_spanbyte,
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
                                .enabled_by_id = span.enabled_by_id,
                                .disabled_by_id = span.disabled_by_id,
                                .start_segbyte = span.start_segbyte,
                                .bufbyte = span.bufbyte,
                                .length = split_spanbyte,
                            };
                            const right_side: Span = .{
                                .enabled_by_id = span.enabled_by_id,
                                .disabled_by_id = span.disabled_by_id,
                                .start_segbyte = span.start_segbyte + split_spanbyte,
                                .bufbyte = span.bufbyte + split_spanbyte,
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
                                .enabled_by_id = span.enabled_by_id,
                                .disabled_by_id = delete_op.id,
                                .start_segbyte = span.start_segbyte,
                                .bufbyte = span.bufbyte,
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
                    const affected_spans_al_entry = self.segment_id_map.getEntry(extend_op.id).?;
                    const affected_spans_al = affected_spans_al_entry.value_ptr;
                    const prev_span_idx = affected_spans_al.getLastOrNull().?;
                    const prev_span = self.span_bbt.getNodeDataPtrConst(prev_span_idx).?;

                    std.debug.assert(prev_span.start_segbyte + prev_span.length == extend_op.prev_len);

                    const newstr_start_bufbyte = self.buffer.items.len;
                    self.buffer.appendSlice(extend_op.text) catch @panic("oom");
                    if (prev_span.bufbyte + prev_span.length == newstr_start_bufbyte and prev_span.disabled_by_id == .none) {
                        self._replaceRange(prev_span_idx, 1, &.{
                            .{
                                .enabled_by_id = prev_span.enabled_by_id,
                                .disabled_by_id = .none,
                                .start_segbyte = prev_span.start_segbyte,
                                .bufbyte = prev_span.bufbyte,
                                .length = @intCast(prev_span.length + extend_op.text.len),
                            },
                        });
                    } else {
                        // have to make a new span
                        self._insertAfter(prev_span_idx, &.{
                            .{
                                .enabled_by_id = prev_span.enabled_by_id,
                                .disabled_by_id = .none,
                                .start_segbyte = @intCast(prev_span.start_segbyte + prev_span.length),
                                .bufbyte = @intCast(newstr_start_bufbyte),
                                .length = @intCast(extend_op.text.len),
                            },
                        });
                    }
                },
            }
        }

        pub fn length(self: *const Doc) u64 {
            const res_count = self.span_bbt.getCountForNode(.root).byte_count;
            std.debug.assert(res_count >= 1); // must contain at least "\x00"
            return res_count - 1;
        }

        pub fn genOperations(self: *Doc, res: *std.ArrayList(Operation), pos: Position, delete_count: usize, insert_text: []const T) void {
            // 1. generate delete operation
            //     - this is going to be annoying because we chose to make seperate delete operations
            //       per segment id
            if (delete_count != 0) {
                const span_position = self._findEntrySpan(pos);
                const doc_start_docbyte = span_position.span_start_docbyte + span_position.spanbyte;
                const doc_end_docbyte = doc_start_docbyte + delete_count;
                // std.log.info("pos: {}, start byte: {d}, end byte: {d} / {d}", .{pos, doc_start_docbyte, doc_end_docbyte, self.length});
                std.debug.assert(doc_end_docbyte <= self.length());
                const delete_id = self.deleteUuid();

                var span_start_docbyte = span_position.span_start_docbyte;
                var iter = self.span_bbt.iterator(.{ .leftmost_node = span_position.span_index, .skip_empty = true });
                while (span_start_docbyte < doc_end_docbyte) {
                    const span_i = iter.next() orelse @panic("delete out of range");
                    const span = self.span_bbt.getNodeDataPtrConst(span_i).?;
                    if (span.enabled_by_id == .end) @panic("unreachable");

                    if (span.disabled_by_id != .none) continue;

                    const span_end_docbyte = span_start_docbyte + span.length;
                    const target_start_docbyte = @max(span_start_docbyte, doc_start_docbyte);
                    const target_end_docbyte = @min(span_end_docbyte, doc_end_docbyte);
                    const target_segbyte = target_start_docbyte - span_start_docbyte + span.start_segbyte;
                    const target_seglen = target_end_docbyte - target_start_docbyte;
                    std.debug.assert(target_seglen > 0);

                    res.append(.{
                        .delete = .{
                            .id = delete_id,
                            .start = .{
                                .id = span.enabled_by_id,
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
                if (span_position.spanbyte != 0) break :blk;
                const span_position_docbyte = self.span_bbt.getCountForNode(span_position.span_index);
                if (span_position_docbyte.byte_count == 0) break :blk;
                const prev_position = self.positionFromDocbyte(span_position_docbyte.byte_count - 1);
                const prev_v = self._findEntrySpan(prev_position);
                const prev_data = self.span_bbt.getNodeDataPtrConst(prev_v.span_index).?;

                // check if valid
                std.debug.assert(prev_data.disabled_by_id == .none);

                // check if span is allowed
                if (prev_data.enabled_by_id.owner() != self.client_id) break :blk;

                const entry = self.segment_id_map.getEntry(prev_data.enabled_by_id).?;
                if (entry.value_ptr.getLast() != prev_v.span_index) {
                    // invalid; not at end of array
                    break :blk;
                }

                // valid!
                res.append(.{
                    .extend = .{
                        .id = prev_data.enabled_by_id,
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
        pub fn deleteUuid(self: *Doc) DeleteID {
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

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const gpa = gpa_alloc.allocator();

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var block = TextDocument.initEmpty(gpa);
    defer block.deinit();

    std.log.info("block: [{}]", .{block});

    var opgen_demo = std.ArrayList(TextDocument.Operation).init(gpa);
    defer opgen_demo.deinit();

    const b0 = block.positionFromDocbyte(0);
    std.log.info("pos: {}", .{b0});
    std.debug.assert(block.length() == 0);

    // TODO:
    // applyOperations: genOperations( block.positionFromByteOffset(0), 0, "i held" )
    // applyOperations: genOperations( block.positionFromByteOffset(4), 0, "llo wor" )
    // applyOperations: genOperations( block.positionFromByteOffset(0), 2, "" )
    block.applyOperation(.{
        .insert = .{
            .id = block.uuid(),
            .pos = block.positionFromDocbyte(0),
            .text = "i held",
        },
    });
    std.debug.assert(block.length() == 6);
    std.log.info("block: [{}]", .{block});

    block.applyOperation(.{
        .insert = .{
            .id = block.uuid(),
            .pos = block.positionFromDocbyte(4),
            .text = "llo wor",
        },
    });
    std.log.info("block: [{}]", .{block});
    std.debug.assert(block.length() == 13);
    block.applyOperation(.{
        // deleting a range will generate multiple delete operations unfortunately
        .delete = .{
            .id = block.deleteUuid(),
            .start = block.positionFromDocbyte(0),
            .len_within_segment = 2,
        },
    });
    std.log.info("block: {d}[{}]", .{ block.length(), block });
    std.debug.assert(block.length() == 11);
    block.applyOperation(.{
        .extend = .{
            .id = block.positionFromDocbyte(2).id,
            .prev_len = 7,
            .text = "R",
        },
    });
    std.log.info("block: [{}]", .{block});
    std.debug.assert(block.length() == 12);
    block.applyOperation(.{
        .extend = .{
            .id = block.positionFromDocbyte(0).id,
            .prev_len = 6,
            .text = "!",
        },
    });
    std.log.info("block: [{}]", .{block});
    std.debug.assert(block.length() == 13);

    opgen_demo.clearRetainingCapacity();
    block.genOperations(&opgen_demo, block.positionFromDocbyte(0), 0, "Test\n");
    for (opgen_demo.items) |op| {
        std.log.info("  apply {}", .{op});
        block.applyOperation(op);
    }
    std.log.info("block: [{}]", .{block});
    std.debug.assert(block.length() == 18);

    opgen_demo.clearRetainingCapacity();
    block.genOperations(&opgen_demo, block.positionFromDocbyte(1), 18 - 2, "Cleared.");
    for (opgen_demo.items) |op| {
        std.log.info("  apply {}", .{op});
        block.applyOperation(op);
    }
    std.log.info("block: [{}]", .{block});
    std.debug.assert(block.length() == 10);

    const blockcpy = try arena.alloc(u8, block.length());
    block.readSlice(block.positionFromDocbyte(0), blockcpy);
    std.log.info("block: {d}/`{s}`", .{ blockcpy.len, blockcpy });

    const testdocument_len = 100_000;

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

test "document" {
    // this is a fuzz test
    // we can't really use std.testing.fuzzInput() for it unless we implement a parser or something
    _ = try testDocument(std.testing.allocator, 1_000, null);
}

const TestDocumentRetTy = struct {
    timings: Timings,
    max_len: usize,
    final_height: usize,
};
fn testDocument(alloc: std.mem.Allocator, count: usize, progress_node: ?std.Progress.Node) !TestDocumentRetTy {
    std.log.info("testDocument", .{});
    var tester = BlockTester.init(alloc);
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

    timings: Timings,

    rendered_result: std.ArrayList(u8),
    opgen: std.ArrayList(TextDocument.Operation),

    pub fn init(alloc: std.mem.Allocator) BlockTester {
        return .{
            .alloc = alloc,
            .simple = std.ArrayList(u8).init(alloc),
            .complex = TextDocument.initEmpty(alloc),

            .timings = .{},

            .rendered_result = std.ArrayList(u8).init(alloc),
            .opgen = std.ArrayList(TextDocument.Operation).init(alloc),
        };
    }
    pub fn deinit(self: *@This()) void {
        self.simple.deinit();
        self.complex.deinit();
        self.rendered_result.deinit();
        self.opgen.deinit();
    }

    pub fn testReplaceRange(self: *@This(), start: u64, delete_count: u64, insert_text: []const u8) !void {
        var timer = try std.time.Timer.start();

        // std.log.info("  replaceRange@{d}:{d}:\"{s}\"", .{start, delete_count, insert_text});
        self.simple.replaceRange(start, delete_count, insert_text) catch @panic("oom");

        self.timings.simple += timer.lap();

        defer self.opgen.clearRetainingCapacity();
        self.complex.genOperations(&self.opgen, self.complex.positionFromDocbyte(start), delete_count, insert_text);
        for (self.opgen.items) |op| {
            // std.log.info("    -> apply {}", .{op});
            self.complex.applyOperation(op);
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
        self.timings.test_eql += timer.lap();
    }
};

// notes:
// currently, typing will insert a lot of table entries
// we can reduce this by:
// - on insert
// - if the target's client_id == our client_id
//   and the target's pos + offset == the end of the array
//   then, rather than creating a normal insert, create an extend
//   operation
