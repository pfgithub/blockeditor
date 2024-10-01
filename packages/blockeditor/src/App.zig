const std = @import("std");
const blocks_mod = @import("blocks");
const bi = blocks_mod.blockinterface2;
const db_mod = blocks_mod.blockdb;
const Beui = @import("beui").Beui;
const blocks_net = @import("blocks_net");
const anywhere = @import("anywhere");
const zgui = anywhere.zgui;
const B2 = Beui.beui_experiment;

const App = @This();

const EditorTab = struct {
    editor_view: Beui.EditorView,
};

gpa: std.mem.Allocator,

db: db_mod.BlockDB,
db_sync: blocks_net.TcpSync,

counter_block: *db_mod.BlockRef,
counter_component: db_mod.TypedComponentRef(bi.CounterComponent),

zig_language: Beui.EditorView.Core.highlighters_zig.HlZig,
markdown_language: Beui.EditorView.Core.highlighters_markdown.HlMd,

tabs: std.ArrayList(*EditorTab),
current_tab: usize,

pub fn init(self: *App, gpa: std.mem.Allocator) void {
    self.gpa = gpa;

    self.db = db_mod.BlockDB.init(gpa);
    self.db_sync.init(gpa, &self.db);

    self.counter_block = self.db.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    self.counter_component = self.counter_block.typedComponent(bi.CounterBlock).?;

    self.zig_language = Beui.EditorView.Core.highlighters_zig.HlZig.init(gpa);
    self.markdown_language = Beui.EditorView.Core.highlighters_markdown.HlMd.init();

    self.tabs = .init(gpa);
    self.current_tab = 0;

    self.addTab(@embedFile("App.zig"));
}
pub fn deinit(self: *App) void {
    for (self.tabs.items) |tab| {
        tab.editor_view.deinit();
        self.gpa.destroy(tab);
    }
    self.tabs.deinit();
    self.markdown_language.deinit();
    self.zig_language.deinit();
    self.counter_component.unref();
    self.counter_block.unref();
    self.db_sync.deinit();
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

    id.b2.persistent.wm.addWindow(id.sub(@src()), .from(self, render__scrollDemo));
    id.b2.persistent.wm.addWindow(id.sub(@src()), .from(self, render__window));
}
fn render__scrollDemo(self: *App, call_info: B2.StandardCallInfo, _: void) B2.StandardChild {
    const ui = call_info.ui(@src());
    return B2.Theme.windowChrome(ui.sub(@src()), .{}, .from(self, render__scrollDemo__child));
}
fn render__scrollDemo__child(_: *App, call_info: B2.StandardCallInfo, _: void) B2.StandardChild {
    const ui = call_info.ui(@src());
    return B2.scrollDemo(ui.sub(@src()));
}
fn render__window(self: *App, call_info: B2.StandardCallInfo, _: void) B2.StandardChild {
    const ui = call_info.ui(@src());
    return B2.Theme.windowChrome(ui.sub(@src()), .{}, .from(self, render__window__child));
}
fn render__window__child(self: *App, call_info: B2.StandardCallInfo, _: void) B2.StandardChild {
    const ui = call_info.ui(@src());

    return self.tabs.items[self.current_tab].editor_view.gui(ui.sub(@src()), ui.id.b2.persistent.beui1);
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
