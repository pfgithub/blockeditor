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

tree: FsTree,

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

    self.tree = .init(gpa);
    blk: {
        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch break :blk;
        defer dir.close();
        self.tree.addDir(0, 0, dir, 0);
    }
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

    for (self.tabs.items) |tab| {
        id.b2.persistent.wm.addWindow(id.sub(@src()), .from(&render__editor__Context{ .self = self, .tab = tab }, render__editor));
    }
    id.b2.persistent.wm.addWindow(id.sub(@src()), .from(self, render__tree));
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
fn render__tree(self: *App, call_info: B2.StandardCallInfo, _: void) B2.StandardChild {
    const ui = call_info.ui(@src());

    return B2.virtualScroller(ui.sub(@src()), self.tree.al.items.len, RenderTreeIndex, .from(self, render__tree__child));
}
fn render__tree__child(self: *App, call_info: B2.StandardCallInfo, index: RenderTreeIndex) B2.StandardChild {
    const ui = call_info.ui(@src());

    const tree_node = self.tree.al.items[index.i];

    // if it's a folder, we add its button ikey to the list of folder click handlers. then, if it is clicked next frame,
    // we expand the folder before calling virtualScroller()
    // folder click handlers list can be stored in the render list because it's a frame context item.
    // - ideally, we would handle clicks between frames? maybe we can set up in beui a button that handles clicks
    //   between frames. as long as it doesn't crash if you click the same frame you free() the App

    const offset_x: f32 = @as(f32, @floatFromInt(tree_node.indent_level)) * 6;

    const draw = ui.id.b2.draw();
    const res = B2.textOnly(ui.subWithOffset(@src(), .{ offset_x, 0 }), tree_node.basename_owned, .fromHexRgb(0xFFFFFF));
    draw.place(res.rdl, .{ offset_x, 0 });
    return .{ .rdl = draw, .size = res.size + @Vector(2, f32){ offset_x, 0 } };
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

const FsTree = struct {
    const FsNode = struct {
        indent_level: usize,
        child_index: usize,
        basename_owned: []u8,
        node_type: enum { dir, file, other },
    };
    al: std.ArrayList(FsNode),
    pub fn init(gpa: std.mem.Allocator) FsTree {
        return .{ .al = .init(gpa) };
    }
    pub fn deinit(self: *FsTree) void {
        for (self.al.items) |item| self.al.allocator.free(item.basename_owned);
        self.al.deinit();
    }
    fn addDir(self: *FsTree, insert_at: usize, delete_len: usize, dir: std.fs.Dir, indent_level: usize) void {
        var iter = dir.iterate();
        var tmp_al = std.ArrayList(FsNode).init(self.al.allocator);
        defer tmp_al.deinit();
        while (iter.next() catch return) |file| {
            const name_dupe = self.al.allocator.dupe(u8, file.name) catch @panic("oom");
            tmp_al.append(.{
                .indent_level = indent_level,
                .child_index = 0,
                .basename_owned = name_dupe,
                .node_type = switch (file.kind) {
                    .directory => .dir,
                    .file => .file,
                    else => .other,
                },
            }) catch @panic("oom");
        }
        std.mem.sort(FsNode, tmp_al.items, {}, FsNode_lessThanFn);
        for (tmp_al.items, 0..) |*item, i| item.child_index = i;
        self.al.replaceRange(insert_at, delete_len, tmp_al.items) catch @panic("oom");
    }
    fn FsNode_lessThanFn(_: void, a: FsNode, b: FsNode) bool {
        if (a.node_type == .dir and b.node_type != .dir) return true; // dirs go first
        if (b.node_type == .dir and a.node_type != .dir) return false;
        return std.mem.order(u8, a.basename_owned, b.basename_owned) == .lt;
    }
};
