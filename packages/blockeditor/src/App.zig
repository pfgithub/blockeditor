const std = @import("std");
const blocks_mod = @import("blocks");
const bi = blocks_mod.blockinterface2;
const db_mod = blocks_mod.blockdb;
const Beui = @import("beui").Beui;
const blocks_net = @import("blocks_net");
const anywhere = @import("anywhere");
const tracy = anywhere.tracy;
const zgui = anywhere.zgui;
const B2 = Beui.beui_experiment;

const App = @This();

const EditorTab = struct {
    editor_view: Beui.EditorView,
};

gpa: std.mem.Allocator,

db: db_mod.BlockDB,
db_sync: ?blocks_net.TcpSync,

counter_block: *db_mod.BlockRef,
counter_component: db_mod.TypedComponentRef(bi.CounterComponent),

zig_language: Beui.EditorView.Core.highlighters_zig.HlZig,
markdown_language: Beui.EditorView.Core.highlighters_markdown.HlMd,

tabs: std.ArrayList(*EditorTab),
current_tab: usize,

tree: FsTree2,

pub fn init(self: *App, gpa: std.mem.Allocator) void {
    return self.initWithCfg(gpa, .{});
}
pub fn initWithCfg(self: *App, gpa: std.mem.Allocator, cfg: struct { enable_db_sync: bool = true }) void {
    self.gpa = gpa;

    self.db = db_mod.BlockDB.init(gpa);
    if (cfg.enable_db_sync) {
        self.db_sync = @as(blocks_net.TcpSync, undefined);
        self.db_sync.?.init(gpa, &self.db);
    } else {
        self.db_sync = null;
    }

    self.counter_block = self.db.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    self.counter_component = self.counter_block.typedComponent(bi.CounterBlock).?;

    self.zig_language = Beui.EditorView.Core.highlighters_zig.HlZig.init(gpa);
    self.markdown_language = Beui.EditorView.Core.highlighters_markdown.HlMd.init();

    self.tabs = .init(gpa);
    self.current_tab = 0;

    self.addTab(@embedFile("App.zig"));

    var outbuf: [std.fs.max_path_bytes]u8 = undefined;
    self.tree = .init(std.fs.cwd().realpath(".", &outbuf) catch |e| blk: {
        std.log.err("unable to get realpath: {s}", .{@errorName(e)});
        break :blk "";
    }, gpa);
    self.tree.createRootNode();
}
pub fn deinit(self: *App) void {
    self.tree.deinit();
    for (self.tabs.items) |tab| {
        tab.editor_view.deinit();
        self.gpa.destroy(tab);
    }
    self.tabs.deinit();
    self.markdown_language.deinit();
    self.zig_language.deinit();
    self.counter_component.unref();
    self.counter_block.unref();
    if (self.db_sync) |*s| s.deinit();
    self.db.deinit();
}

pub fn addTab(self: *App, file_cont: []const u8) void {
    const text_block = self.db.createBlock(bi.TextDocumentBlock.deserialize(self.gpa, bi.TextDocumentBlock.default) catch unreachable);
    defer text_block.unref();
    const text_component = text_block.typedComponent(bi.TextDocumentBlock).?;
    defer text_component.unref();

    text_component.applySimpleOperation(.{
        .position = text_component.value.positionFromDocbyte(0),
        .delete_len = 0,
        .insert_text = file_cont,
    }, null);

    const new_tab = self.gpa.create(EditorTab) catch @panic("oom");
    new_tab.* = .{ .editor_view = undefined };
    new_tab.editor_view.initFromDoc(self.gpa, text_component);
    new_tab.editor_view.core.setSynHl(self.zig_language.language());

    new_tab.editor_view.core.executeCommand(.{ .set_cursor_pos = .{ .position = text_component.value.positionFromDocbyte(0) } });

    self.tabs.append(new_tab) catch @panic("oom");
}

pub fn render(self: *App, call_id: B2.ID) void {
    const id = call_id.sub(@src());

    self.db.tickBegin();
    defer self.db.tickEnd();

    if (zgui.beginWindow("My counter (editor 1)", .{})) {
        defer zgui.endWindow();
        renderCounter(self.counter_component);
    }

    if (zgui.beginWindow("Editor Settings", .{})) {
        defer zgui.endWindow();

        zgui.text("Set syn hl:", .{});
        if (zgui.button("zig", .{})) {
            self.tabs.items[self.current_tab].editor_view.core.setSynHl(self.zig_language.language());
        }
        if (zgui.button("markdown", .{})) {
            self.tabs.items[self.current_tab].editor_view.core.setSynHl(self.markdown_language.language());
        }
        if (zgui.button("plaintext", .{})) {
            self.tabs.items[self.current_tab].editor_view.core.setSynHl(null);
        }
    }

    // const wm = b2.windowManager();
    // b2.windows.add()

    id.b2.persistent.wm.addWindow(id.sub(@src()), "Debug Texture", .from(self, render__debugTexture));
    const id_loop = id.pushLoop(@src(), usize);
    for (self.tabs.items, 0..) |tab, i| {
        const id_sub = id_loop.pushLoopValue(@src(), i);
        id.b2.persistent.wm.addWindow(id_sub.sub(@src()), "Editor View.zig", .from(&render__editor__Context{ .self = self, .tab = tab }, render__editor));
    }
    id.b2.persistent.wm.addWindow(id.sub(@src()), "File Tree", .from(self, render__tree));
}
const render__editor__Context = struct {
    self: *App,
    tab: *EditorTab,
};
fn render__editor(ctx: *const render__editor__Context, call_info: B2.StandardCallInfo, _: void) B2.StandardChild {
    const tab = ctx.tab;

    const tctx = tracy.traceNamed(@src(), "App editor");
    defer tctx.end();

    const ui = call_info.ui(@src());

    return tab.editor_view.gui(ui.sub(@src()), ui.id.b2.persistent.beui1);
}

const RenderTreeIndex = struct {
    i: usize,
    pub fn first(_: usize) RenderTreeIndex {
        return .{ .i = 0 };
    }
    pub fn update(itm: RenderTreeIndex, len: usize) ?RenderTreeIndex {
        if (itm.i >= len) return if (len == 0) null else .{ .i = len - 1 };
        return .{ .i = itm.i };
    }
    pub fn prev(itm: RenderTreeIndex, _: usize) ?RenderTreeIndex {
        if (itm.i == 0) return null;
        return .{ .i = itm.i - 1 };
    }
    pub fn next(itm: RenderTreeIndex, len: usize) ?RenderTreeIndex {
        if (itm.i == len - 1) return null;
        return .{ .i = itm.i + 1 };
    }
};
fn render__debugTexture(_: *App, call_info: B2.StandardCallInfo, _: void) B2.StandardChild {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    // TODO should be scrollable, vertical and horizontal
    // maybe window can autoscroll when content exceeds its bounds
    rdl.addRect(.{
        .pos = .{ 20, 20 },
        .size = .{ 200, 200 },
        .tint = .fromHexRgb(0xFF0000),
        .rounding = .{ .corners = .all, .radius = 100.0 },
    });
    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ 2048, 2048 },
        .uv_pos = .{ 0, 0 },
        .uv_size = .{ 1, 1 },
        .image = .editor_view_glyphs,
    });
    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? },
        .tint = B2.Theme.colors.window_bg,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    return .{ .rdl = rdl, .size = .{ 2048, 2048 } };
}
fn render__tree(self: *App, call_info: B2.StandardCallInfo, _: void) B2.StandardChild {
    const ui = call_info.ui(@src());

    const rdl = ui.id.b2.draw();
    const chres = B2.virtualScroller(ui.sub(@src()), &self.tree, FsTree2.Index, .from(self, render__tree__child));
    rdl.place(chres.rdl, .{});
    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = chres.size,
        .tint = B2.Theme.colors.window_bg,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    return .{ .rdl = rdl, .size = chres.size };
}
fn render__tree__child(self: *App, call_info: B2.StandardCallInfo, index: FsTree2.Index) B2.StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());

    const tree_node = index.current_node orelse unreachable;

    const itkn = B2.Button_Itkn.init(ui.id.sub(@src()));
    if (itkn.clicked()) {
        // TODO this should be in a between-frame callback
        if (tree_node.node_type == .file) {
            // what's the reason to require double click again? so you can select a file without opening it in order to rename it
            // or something like that?
            // if (ui.id.b2.persistent.beui1.leftMouseClickedCount() == 2) {
            var file_path = std.ArrayList(u8).init(ui.id.b2.frame.arena);
            self.tree.getPath(tree_node, &file_path);
            if (std.fs.cwd().readFileAlloc(ui.id.b2.frame.arena, file_path.items, std.math.maxInt(usize))) |file_cont| {
                self.addTab(file_cont);
            } else |e| {
                std.log.err("Failed to open file: {s}", .{@errorName(e)});
            }
        } else {
            if (tree_node.children_owned == null) {
                self.tree.expand(tree_node) catch |e| {
                    std.log.err("Failed to open directory: {s}", .{@errorName(e)});
                };
            } else {
                self.tree.contract(tree_node);
            }
        }
    }
    return B2.button(ui.sub(@src()), itkn, .from(&TreeChild{ .self = self, .node = tree_node }, render__tree__child__child));
}
const TreeChild = struct { self: *App, node: *FsTree2.Node };
fn render__tree__child__child(tc: *const TreeChild, call_info: B2.StandardCallInfo, itkn: B2.Button_Itkn) B2.StandardChild {
    _ = itkn;
    const self = tc.self;
    const tree_node = tc.node;
    const ui = call_info.ui(@src());

    _ = self;

    const offset_x: f32 = @as(f32, @floatFromInt(tree_node.indent_level)) * 6;

    const draw = ui.id.b2.draw();
    const res = B2.textLine(ui.subWithOffset(@src(), .{ offset_x, 0 }), .{ .text = tree_node.basename_owned }); //, .fromHexRgb(0xFFFFFF));
    draw.place(res.rdl, .{ .offset = .{ offset_x, 0 } });
    return .{ .rdl = draw, .size = .{ call_info.constraints.available_size.w.?, res.size[1] } };
}

fn renderCounter(counter: db_mod.TypedComponentRef(bi.CounterComponent)) void {
    zgui.text("Count: {d}", .{counter.value.count});
    if (zgui.button("Increment!", .{})) {
        counter.applySimpleOperation(.{ .add = 1 }, null);
    }
    if (zgui.button("Zero!", .{})) {
        counter.applySimpleOperation(.{ .set = 0 }, null);
    }
    if (zgui.button("Undo!", .{})) {
        @panic("TODO: someone needs to keep an undo list");
    }
    if (zgui.button("Redo!", .{})) {
        @panic("TODO: someone needs to keep a redo list");
    }
}

test "app renders" {
    var app: App = undefined;
    app.initWithCfg(std.testing.allocator, .{ .enable_db_sync = false });
    defer app.deinit();

    var arena_backing: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_backing.deinit();
    const arena = arena_backing.allocator();

    var b1: Beui = .{ .persistent = .{} };
    var b2: B2.Beui2 = undefined;
    b2.init(&b1, std.testing.allocator);
    defer b2.deinit();

    // render two frames
    for (0..2) |_| {
        b1.newFrame(.{
            .arena = arena,
            .now_ms = 0,
            .user_data = null,
            .vtable = &testing_vtable,
        });
        const root_id = b2.newFrame(.{ .size = .{ 200, 200 } });

        app.render(root_id.sub(@src()));

        b2.endFrame(null);
        b1.endFrame();
    }
}
const testing_vtable: Beui.FrameCfgVtable = .{
    .type_id = @typeName(void),
};

const FsTree2 = struct {
    // if we could embed virutalized scrollers inside other virtualized scrollers then
    // we wouldn't have to keep nodes around forever
    // TODO: if you open a dir and open some dirs within it, then close the outer dir and reopen it,
    // the inner dirs should stay open. might require a bit of a rethink?
    const Node = struct {
        basename_owned: []u8,
        child_index: usize,
        node_type: enum { dir, file, other },
        parent: ?*Node,
        children_owned: ?[]*Node,
        is_deleted: bool,
        indent_level: usize,
        fn deinit(self: *Node, gpa: std.mem.Allocator) void {
            gpa.free(self.basename_owned);
            if (self.children_owned) |co| gpa.free(co);
        }
    };
    root_dir_owned: []const u8,
    root_node: ?*Node,
    node_pool: std.heap.ArenaAllocator,
    all_nodes: std.ArrayList(*Node),
    deleted_nodes: std.ArrayList(*Node),

    pub const Index = struct {
        // pointer stays valid because we never delete nodes. if they are to be reused, they stay valid until
        // they are replaced with a new value.
        current_node: ?*Node,

        pub fn first(self: *FsTree2) Index {
            return .{ .current_node = self.root_node };
        }
        pub fn update(itm_in: Index, self: *FsTree2) ?Index {
            if (itm_in.current_node == null) return null;
            var node = itm_in.current_node.?;
            while (node.is_deleted) {
                if (node.parent) |parent| {
                    node = parent;
                } else {
                    // deleted node has no parent
                    if (self.root_node) |root_node| return .{ .current_node = root_node };
                    return null;
                }
            }
            return .{ .current_node = node };
        }
        pub fn prev(itm: Index, self: *FsTree2) ?Index {
            _ = self;
            if (itm.current_node == null) return null;
            const parent = itm.current_node.?.parent orelse return null;
            if (itm.current_node.?.child_index == 0) return .{ .current_node = parent };
            if (parent.children_owned == null) return .{ .current_node = parent }; // weird state
            const prev_index = itm.current_node.?.child_index - 1;
            if (prev_index >= parent.children_owned.?.len) return .{ .current_node = parent }; // child index out of range
            var lastchild = parent.children_owned.?[prev_index];
            while (lastchild.children_owned != null and lastchild.children_owned.?.len > 0) {
                lastchild = lastchild.children_owned.?[lastchild.children_owned.?.len - 1];
            }
            return .{ .current_node = lastchild };
        }
        pub fn next(itm: Index, self: *FsTree2) ?Index {
            _ = self;
            if (itm.current_node == null) return null;
            if (itm.current_node.?.children_owned) |children| {
                if (children.len > 0) return .{ .current_node = children[0] };
            }
            var current = itm.current_node.?;
            while (true) {
                const parent = current.parent orelse return null;
                if (parent.children_owned == null) return .{ .current_node = parent }; // weird state
                const next_index = std.math.add(usize, current.child_index, 1) catch return .{ .current_node = parent };
                if (next_index < parent.children_owned.?.len) return .{ .current_node = parent.children_owned.?[next_index] };
                current = parent;
            }
        }
    };

    pub fn init(root_dir: []const u8, gpa: std.mem.Allocator) FsTree2 {
        return .{
            .root_dir_owned = gpa.dupe(u8, root_dir) catch @panic("oom"),
            .root_node = null,
            .node_pool = .init(gpa),
            .all_nodes = .init(gpa),
            .deleted_nodes = .init(gpa),
        };
    }
    pub fn deinit(self: *FsTree2) void {
        self.all_nodes.allocator.free(self.root_dir_owned);
        for (self.all_nodes.items) |node| node.deinit(self.all_nodes.allocator);
        self.all_nodes.deinit();
        self.deleted_nodes.deinit();
        self.node_pool.deinit();
    }

    pub fn createRootNode(self: *FsTree2) void {
        self.root_node = self._addNode(.{
            .basename_owned = self.all_nodes.allocator.dupe(u8, ".") catch @panic("oom"),
            .node_type = .dir,
            .parent = null,
            .children_owned = null,
            .is_deleted = false,
            .indent_level = 0,
            .child_index = 0,
        });
    }

    pub fn getPath(self: *FsTree2, dir: *Node, result: *std.ArrayList(u8)) void {
        if (dir.parent) |parent| {
            self.getPath(parent, result);
        } else {
            result.appendSlice(self.root_dir_owned) catch @panic("oom");
        }
        result.appendSlice("/") catch @panic("oom");
        result.appendSlice(dir.basename_owned) catch @panic("oom");
    }
    pub fn expand(self: *FsTree2, dir: *Node) !void {
        if (dir.children_owned != null) return;

        var whole_path = std.ArrayList(u8).init(self.all_nodes.allocator);
        defer whole_path.deinit();
        self.getPath(dir, &whole_path);

        var res_children = std.ArrayList(*Node).init(self.all_nodes.allocator);
        defer res_children.deinit();
        errdefer for (res_children.items) |item| self._removeNode(item);

        var dirent = try std.fs.cwd().openDir(whole_path.items, .{ .iterate = true });
        defer dirent.close();
        var iter = dirent.iterateAssumeFirstIteration();
        while (try iter.next()) |entry| {
            res_children.append(self._addNode(.{
                .basename_owned = self.all_nodes.allocator.dupe(u8, entry.name) catch @panic("oom"),
                .child_index = std.math.maxInt(usize),
                .node_type = switch (entry.kind) {
                    .directory => .dir,
                    .file => .file,
                    else => .other,
                },
                .parent = dir,
                .children_owned = null,
                .is_deleted = false,
                .indent_level = dir.indent_level + 1,
            })) catch @panic("oom");
        }

        // sort
        std.mem.sort(*Node, res_children.items, self, Node_lessThanFn);
        // fill indices
        for (res_children.items, 0..) |v, i| v.child_index = i;

        dir.children_owned = res_children.toOwnedSlice() catch @panic("oom");
    }
    fn Node_lessThanFn(_: *FsTree2, a: *Node, b: *Node) bool {
        if (a.node_type == .dir and b.node_type != .dir) return true; // dirs go first
        if (b.node_type == .dir and a.node_type != .dir) return false;
        return std.mem.order(u8, a.basename_owned, b.basename_owned) == .lt;
    }

    pub fn contract(self: *FsTree2, dir: *Node) void {
        return self._contract(dir, dir);
    }
    fn _contract(self: *FsTree2, dir: *Node, setparent: *Node) void {
        // setparent is just so large trees can exit instantly and have less chance of jumping to a
        // newly overwritten node.
        if (dir.children_owned) |children| {
            for (children) |child| {
                self._contract(child, setparent);
                child.parent = setparent;
                self._removeNode(child);
            }
            self.all_nodes.allocator.free(children);
            dir.children_owned = null;
        }
    }

    fn _addNode(self: *FsTree2, value: Node) *Node {
        std.debug.assert(!value.is_deleted);
        if (self.deleted_nodes.items.len > 0) {
            const res = self.deleted_nodes.pop();
            res.deinit(self.all_nodes.allocator);
            res.* = value;
            return res;
        }
        const new_node = self.node_pool.allocator().create(Node) catch @panic("oom");
        new_node.* = value;
        self.all_nodes.append(new_node) catch @panic("oom");
        return new_node;
    }
    fn _removeNode(self: *FsTree2, value: *Node) void {
        std.debug.assert(!value.is_deleted);
        value.is_deleted = true;
        value.child_index = std.math.maxInt(usize);
        self.deleted_nodes.append(value) catch @panic("oom");
    }
};
