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

pub const std_options = std.Options{
    .log_scope_levels = &.{
        .{ .scope = .emu, .level = .err },
    },
};

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

enable_bouncing_ball: bool,

pub fn init(self: *App, gpa: std.mem.Allocator) void {
    return self.initWithCfg(gpa, .{});
}
pub fn initWithCfg(self: *App, gpa: std.mem.Allocator, cfg: struct { enable_db_sync: bool = true }) void {
    self.gpa = gpa;

    self.db = db_mod.BlockDB.init(gpa);
    if (@import("builtin").target.os.tag != .wasi and cfg.enable_db_sync) {
        self.db_sync = @as(blocks_net.TcpSync, undefined);
        self.db_sync.?.init(gpa, &self.db);
    } else {
        self.db_sync = null;
    }

    self.counter_block = self.db.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    self.counter_component = self.counter_block.typedComponent(bi.CounterBlock).?;

    self.zig_language = Beui.EditorView.Core.highlighters_zig.HlZig.init(gpa);
    self.markdown_language = Beui.EditorView.Core.highlighters_markdown.HlMd.init();

    self.enable_bouncing_ball = true;

    self.tabs = .init(gpa);
    self.current_tab = 0;

    self.addTab(@embedFile("App.zig"));

    var outbuf: [std.fs.max_path_bytes]u8 = undefined;
    self.tree = .init(if (@import("builtin").os.tag == .wasi) (
    // realpath should never be used. but until then:
        "/") else std.fs.cwd().realpath(".", &outbuf) catch |e| blk: {
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
    id.b2.persistent.wm.addWindow(id.sub(@src()), "Debug Texture 2", .from(self, render__debugTexture2));
    const id_loop = id.pushLoop(@src(), usize);
    for (self.tabs.items, 0..) |tab, i| {
        const id_sub = id_loop.pushLoopValue(@src(), i);
        const tmpdata = id.b2.frame.arena.dupe(render__editor__Context, &.{.{ .self = self, .tab = tab }}) catch @panic("oom");
        id.b2.persistent.wm.addWindow(id_sub.sub(@src()), "Editor View.zig", .from(&tmpdata[0], render__editor));
    }
    id.b2.persistent.wm.addWindow(id.sub(@src()), "File Tree", .from(self, render__tree));
    id.b2.persistent.wm.addWindow(id.sub(@src()), "Minigamer", .from(&{}, @import("mini.zig").render));
    if (zgui.beginWindow("Bouncing Ball", .{})) {
        defer zgui.endWindow();

        zgui.checkbox("Enable", &self.enable_bouncing_ball);
    }
    if (self.enable_bouncing_ball) {
        id.b2.persistent.wm.addFullscreenOverlay(id.sub(@src()), .from(@as(*void, undefined), render__bounceBall));
    } else {
        // todo preserve state tree
    }
}

const BounceBallState = struct {
    ball_pos_px: @Vector(2, f32),
    ball_vel_per_frame: @Vector(2, f32),
    ball_dragging: bool,
    fixed_timestep_manager: anywhere.util.FixedTimestep,

    prev_mouse_pos: ?@Vector(2, f32) = null,
    prev_mouse_time: f64 = 0.0,
    prev2_mouse_pos: ?@Vector(2, f32) = null,
    prev2_mouse_time: f64 = 0.0,
    prev3_mouse_pos: ?@Vector(2, f32) = null,
    prev3_mouse_time: f64 = 0.0,

    pub fn init(self: *BounceBallState, whole_size: @Vector(2, f32)) void {
        self.* = .{
            .ball_pos_px = whole_size / @Vector(2, f32){ 2.0, 2.0 },
            .ball_vel_per_frame = .{ 0, 0 },
            .ball_dragging = false,
            .fixed_timestep_manager = .init(anywhere.util.fpsToMspf(120.0)),
        };
    }
    pub fn deinit(_: *BounceBallState) void {}
};
const ball_diameter: f32 = 80.0;
const ball_size: @Vector(2, f32) = @splat(ball_diameter);
const ball_size_half: @Vector(2, f32) = @splat(ball_diameter / 2.0);
fn render__bounceBall(_: *void, call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
    const whole_size: @Vector(2, f32) = .{ call_info.constraints.available_size.w.?, call_info.constraints.available_size.h.? };

    const ui = call_info.ui(@src());
    const b2 = ui.id.b2;

    const state = b2.state2(ui.id.sub(@src()), whole_size, BounceBallState);

    // correct if the window was resized
    state.ball_pos_px = @max(state.ball_pos_px, ball_size_half);
    state.ball_pos_px = @min(state.ball_pos_px, whole_size - ball_size_half);

    // to update this to variable timestep:
    // - change gravity to `+= 0.5 * dt`
    // - change air resistance to ` *= @splat( std.math.pow(f64, dt, 0.99) )`
    // where 16.6666 ms = 1.0 dt
    for (0..state.fixed_timestep_manager.advance(@floatFromInt(b2.persistent.beui1.frame.frame_cfg.?.now_ms))) |_| {
        // gravity
        if (!state.ball_dragging) state.ball_vel_per_frame[1] += 0.5;

        // move
        state.ball_pos_px += state.ball_vel_per_frame;

        // air resistance
        state.ball_vel_per_frame *= @splat(0.99);

        // bounce wall
        if (state.ball_pos_px[0] < ball_size_half[0]) {
            state.ball_vel_per_frame[0] = -state.ball_vel_per_frame[0];
            state.ball_pos_px[0] = ball_size_half[0];
        }
        if (state.ball_pos_px[1] < ball_size_half[1]) {
            state.ball_vel_per_frame[1] = -state.ball_vel_per_frame[1];
            state.ball_pos_px[1] = ball_size_half[1];
        }
        if (state.ball_pos_px[0] > whole_size[0] - ball_size_half[0]) {
            state.ball_vel_per_frame[0] = -state.ball_vel_per_frame[0];
            state.ball_pos_px[0] = whole_size[0] - ball_size_half[0];
        }
        if (state.ball_pos_px[1] > whole_size[1] - ball_size_half[1]) {
            state.ball_vel_per_frame[1] = -state.ball_vel_per_frame[1];
            state.ball_pos_px[1] = whole_size[1] - ball_size_half[1];
        }
    }

    // TODO:
    // - [x] drag with mouse
    // - [ ] consistent throwing on mouse up
    // - [ ] detect when at rest (vel 0 & on ground)
    // - [ ] request an animation frame when not at rest (so when you throw the ball
    //       it keeps moving. once screen refreshing is only enabled for a real action,
    //       this will matter.)
    // - [ ] support scroll wheel to throw the ball
    // nice to have:
    // - [ ] make the ball squash and stretch. that would be fun.

    const rdl = b2.draw();

    rdl.addRect(.{
        .pos = state.ball_pos_px - ball_size_half,
        .size = ball_size,
        .tint = .fromHexRgb(0xFF0000),
        .rounding = .{ .corners = .all, .style = .round, .radius = ball_diameter / 2 },
    });
    rdl.addMouseEventCapture2(ui.id.sub(@src()), state.ball_pos_px - ball_size_half, ball_size, .{
        .onMouseEvent = .from(state, render__bounceBall__onMouseEvent),
    });

    return rdl;
}
fn render__bounceBall__onMouseEvent(state: *BounceBallState, b2: *B2.Beui2, ev: B2.MouseEvent) ?Beui.Cursor {
    const now: f64 = @floatFromInt(b2.persistent.beui1.frame.frame_cfg.?.now_ms);
    if (ev.action == .down or ev.action == .move_while_up) {
        const cpos = ((ev.pos.? - ev.capture_pos) - ball_size_half) / ball_size_half;
        const dist = @sqrt(cpos[0] * cpos[0] + cpos[1] * cpos[1]);
        if (dist <= 1.0) {
            // actually touching
            if (ev.action == .down) {
                state.ball_dragging = true;
                state.ball_vel_per_frame = .{ 0, 0 };
                state.prev_mouse_pos = ev.pos.?;
                state.prev_mouse_time = now;
                state.prev2_mouse_pos = ev.pos.?;
                state.prev2_mouse_time = now;
                state.prev3_mouse_pos = ev.pos.?;
                state.prev3_mouse_time = now;
            }
            return .arrow;
        } else {
            // not touching; ignore event
            return null;
        }
    } else {
        if (ev.action == .up) {
            const diff = ev.pos.? - state.prev3_mouse_pos.?;
            const tdiff: f32 = @floatCast(now - state.prev3_mouse_time);

            state.ball_dragging = false;
            if (tdiff < 1) {
                // std.log.info("throw failed; missing average", .{});
            } else {
                // std.log.info("throwing {d} over {d}ms", .{ diff, tdiff });
                state.ball_vel_per_frame = diff / @as(@Vector(2, f32), @splat(tdiff / @as(f32, @floatCast(anywhere.util.fpsToMspf(120)))));
            }
        } else {
            const diff = ev.pos.? - state.prev_mouse_pos.?;
            // currently dragging
            state.prev3_mouse_pos = state.prev2_mouse_pos;
            state.prev3_mouse_time = state.prev2_mouse_time;

            state.prev2_mouse_pos = state.prev_mouse_pos;
            state.prev2_mouse_time = state.prev_mouse_time;

            state.prev_mouse_pos = ev.pos.?;
            state.prev_mouse_time = now;

            state.ball_pos_px += diff;
        }

        return .arrow;
    }
}

const render__editor__Context = struct {
    self: *App,
    tab: *EditorTab,
};
fn render__editor(ctx: *const render__editor__Context, call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
    const tab = ctx.tab;

    const tctx = tracy.traceNamed(@src(), "App editor");
    defer tctx.end();

    const ui = call_info.ui(@src());

    const res = tab.editor_view.gui(ui.sub(@src()), ui.id.b2.persistent.beui1);
    return res.rdl;
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
fn render__debugTexture(_: *App, call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    // TODO should be scrollable, vertical and horizontal
    // maybe window can autoscroll when content exceeds its bounds
    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ 2048, 2048 },
        .uv_pos = .{ 0, 0 },
        .uv_size = .{ 1, 1 },
        .image = .grayscale,
    });
    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? },
        .tint = B2.Theme.colors.window_bg,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    return rdl;
}
fn render__debugTexture2(_: *App, call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ 2048, 2048 },
        .uv_pos = .{ 0, 0 },
        .uv_size = .{ 1, 1 },
        .image = .rgba,
    });
    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? },
        .tint = B2.Theme.colors.window_bg,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    return rdl;
}
fn render__tree(self: *App, call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
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
    return rdl;
}
fn render__tree__child(self: *App, call_info: B2.StandardCallInfo, index: FsTree2.Index) B2.StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());

    const tree_node = index.current_node orelse unreachable;

    const tree_data = ui.id.b2.frame.arena.create(render__tree__child_onClick_data) catch @panic("oom");
    tree_data.* = .{ .self = self, .tree_node = tree_node };
    const ehdl: B2.ButtonEhdl = .{
        .onClick = .from(tree_data, render__tree__child_onClick),
    };
    return B2.button(ui.sub(@src()), ehdl, .from(&TreeChild{ .self = self, .node = tree_node }, render__tree__child__child));
}
const render__tree__child_onClick_data = struct {
    self: *App,
    tree_node: *FsTree2.Node,
};
fn render__tree__child_onClick(data: *render__tree__child_onClick_data, b2: *B2.Beui2, _: void) void {
    const self = data.self;
    const tree_node = data.tree_node;
    // if App was deinitialized at the end of this frame, self & tree_node won't exist.
    // luckily that (probably? what if we run two apps?) won't happen with App, but this
    // issue needs to be solved. like somehow in deinit fns we also need to have a list
    // of callbacks to deactivate.
    if (tree_node.node_type == .file) {
        // what's the reason to require double click again? so you can select a file without opening it in order to rename it
        // or something like that?
        // if (ui.id.b2.persistent.beui1.leftMouseClickedCount() == 2) {
        var file_path = std.ArrayList(u8).init(b2.frame.arena);
        self.tree.getPath(tree_node, &file_path);
        if (std.fs.cwd().readFileAlloc(b2.frame.arena, file_path.items, std.math.maxInt(usize))) |file_cont| {
            self.addTab(file_cont);
        } else |e| {
            std.log.err("Failed to open file: {s}", .{@errorName(e)});
        }
    } else {
        if (!tree_node.opened) {
            self.tree.expand(tree_node) catch |e| {
                std.log.err("Failed to open directory: {s}", .{@errorName(e)});
            };
        } else {
            self.tree.contract(tree_node);
        }
    }
}
const TreeChild = struct { self: *App, node: *FsTree2.Node };
fn render__tree__child__child(tc: *const TreeChild, call_info: B2.StandardCallInfo, state: B2.ButtonState) B2.StandardChild {
    const self = tc.self;
    const tree_node = tc.node;
    const ui = call_info.ui(@src());

    _ = self;

    const offset_x: f32 = @as(f32, @floatFromInt(tree_node.indent_level)) * 6;

    const draw = ui.id.b2.draw();
    const res = B2.textLine(ui.subWithOffset(@src(), .{ offset_x, 0 }), .{ .text = tree_node.basename_owned }); //, .fromHexRgb(0xFFFFFF));
    draw.place(res.rdl, .{ .offset = .{ offset_x, 0 } });
    if (state.active) {
        draw.addRect(.{ .pos = .{ 0, 0 }, .size = .{ call_info.constraints.available_size.w.?, res.size[1] }, .tint = .fromHexRgb(0x747474) });
    }
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

    var tester: B2.B2Tester = undefined;
    tester.init(std.testing.allocator);
    defer tester.deinit();

    // render two frames
    for (0..2) |_| {
        const root_id = tester.startFrame(0, .{ 200, 200 });

        app.render(root_id.sub(@src()));

        tester.endFrame();
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
        children_owned: []*Node, // MUST BE SORTED BY std.mem.order IF opened IS false
        opened: bool,
        is_deleted: bool,
        indent_level: usize,
        fn deinit(self: *Node, gpa: std.mem.Allocator) void {
            gpa.free(self.basename_owned);
            gpa.free(self.children_owned);
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
            if (!parent.opened) return .{ .current_node = parent }; // weird state
            const prev_index = itm.current_node.?.child_index - 1;
            if (prev_index >= parent.children_owned.len) return .{ .current_node = parent }; // child index out of range
            var lastchild = parent.children_owned[prev_index];
            while (lastchild.opened and lastchild.children_owned.len > 0) {
                lastchild = lastchild.children_owned[lastchild.children_owned.len - 1];
            }
            return .{ .current_node = lastchild };
        }
        pub fn next(itm: Index, self: *FsTree2) ?Index {
            _ = self;
            if (itm.current_node == null) return null;
            if (itm.current_node.?.opened) {
                const children = itm.current_node.?.children_owned;
                if (children.len > 0) return .{ .current_node = children[0] };
            }
            var current = itm.current_node.?;
            while (true) {
                const parent = current.parent orelse return null;
                if (!parent.opened) return .{ .current_node = parent }; // weird state
                const next_index = std.math.add(usize, current.child_index, 1) catch return .{ .current_node = parent };
                if (next_index < parent.children_owned.len) return .{ .current_node = parent.children_owned[next_index] };
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
            .opened = false,
            .children_owned = &.{},
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
    fn binarySearchCompareFn(ctx: []const u8, t: *Node) std.math.Order {
        return std.mem.order(u8, ctx, t.basename_owned);
    }
    pub fn expand(self: *FsTree2, dir: *Node) !void {
        if (dir.opened) return;

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
            const prev_entry_idx_opt = std.sort.binarySearch(*Node, dir.children_owned, entry.name, binarySearchCompareFn);
            const newnode = if (prev_entry_idx_opt) |idx| dir.children_owned[idx] else self._addNode(.{
                .basename_owned = self.all_nodes.allocator.dupe(u8, entry.name) catch @panic("oom"),
                .child_index = std.math.maxInt(usize),
                .node_type = switch (entry.kind) {
                    .directory => .dir,
                    .file => .file,
                    else => .other,
                },
                .parent = dir,
                .children_owned = &.{},
                .opened = false,
                .is_deleted = false,
                .indent_level = dir.indent_level + 1,
            });
            if (prev_entry_idx_opt != null) newnode.is_deleted = true; // HACK: mark "is_deleted". the flag will be removed later.
            res_children.append(newnode) catch @panic("oom");
        }

        // sort
        std.mem.sort(*Node, res_children.items, self, Node_lessThanFn);
        // fill indices
        for (res_children.items, 0..) |v, i| v.child_index = i;

        for (dir.children_owned) |prev_ch| {
            if (!prev_ch.is_deleted) {
                self._removeNode(prev_ch);
            }
            prev_ch.is_deleted = false;
        }
        self.all_nodes.allocator.free(dir.children_owned);
        dir.children_owned = res_children.toOwnedSlice() catch @panic("oom");
        dir.opened = true;
    }
    fn Node_lessThanFn(_: *FsTree2, a: *Node, b: *Node) bool {
        if (a.node_type == .dir and b.node_type != .dir) return true; // dirs go first
        if (b.node_type == .dir and a.node_type != .dir) return false;
        return std.mem.order(u8, a.basename_owned, b.basename_owned) == .lt;
    }
    fn Node_orderOnly(_: *FsTree2, a: *Node, b: *Node) bool {
        return std.mem.order(u8, a.basename_owned, b.basename_owned) == .lt;
    }

    pub fn contract(self: *FsTree2, dir: *Node) void {
        return self._contract(dir, dir);
    }
    fn _contract(self: *FsTree2, dir: *Node, setparent: *Node) void {
        // setparent is just so large trees can exit instantly and have less chance of jumping to a
        // newly overwritten node.
        if (!dir.opened) return;
        dir.opened = false;
        var new_children: std.ArrayList(*Node) = .init(self.all_nodes.allocator);
        defer new_children.deinit();
        for (dir.children_owned) |child| {
            if (child.opened) {
                new_children.append(child) catch @panic("oom");
            } else {
                self._contract(child, setparent);
                child.parent = setparent;
                self._removeNode(child);
            }
        }
        std.mem.sort(*Node, new_children.items, self, Node_orderOnly); // must be std.mem.order sorted
        self.all_nodes.allocator.free(dir.children_owned);
        dir.children_owned = new_children.toOwnedSlice() catch @panic("oom");
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
