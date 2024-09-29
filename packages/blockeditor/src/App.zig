const std = @import("std");
const default_image = Beui.default_image; // 97x161, 255 = white / 0 = black
const draw_lists = Beui.draw_lists;
const blocks_mod = @import("blocks");
const bi = blocks_mod.blockinterface2;
const db_mod = blocks_mod.blockdb;
const Beui = @import("beui").Beui;
const blocks_net = @import("blocks_net");
const anywhere = @import("anywhere");
const tracy = anywhere.tracy;
const build_options = @import("build_options");
const zgui = anywhere.zgui;
const B2 = Beui.beui_experiment;

const App = @This();

db: db_mod.BlockDB,
db_sync: blocks_net.TcpSync,

counter_block: *db_mod.BlockRef,
counter_component: db_mod.TypedComponentRef(bi.CounterComponent),

text_block: *db_mod.BlockRef,
text_component: db_mod.TypedComponentRef(bi.text_component.TextDocument),

zig_language: Beui.EditorView.Core.highlighters_zig.HlZig,
markdown_language: Beui.EditorView.Core.highlighters_markdown.HlMd,

text_editor: Beui.EditorView,

pub fn init(self: *App, gpa: std.mem.Allocator) void {
    self.db = db_mod.BlockDB.init(gpa);
    self.db_sync.init(gpa, &self.db);

    self.counter_block = self.db.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    self.counter_component = self.counter_block.typedComponent(bi.CounterBlock).?;

    self.text_block = self.db.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
    self.text_component = self.text_block.typedComponent(bi.TextDocumentBlock).?;

    self.zig_language = Beui.EditorView.Core.highlighters_zig.HlZig.init(gpa);
    self.markdown_language = Beui.EditorView.Core.highlighters_markdown.HlMd.init();

    self.text_editor.initFromDoc(gpa, self.text_component);
    self.text_editor.core.setSynHl(self.zig_language.language());

    self.text_editor.core.document.applySimpleOperation(.{
        .position = self.text_editor.core.document.value.positionFromDocbyte(0),
        .delete_len = 0,
        .insert_text = @embedFile("beui_impl.zig"),
    }, null);
    self.text_editor.core.executeCommand(.{ .set_cursor_pos = .{ .position = self.text_editor.core.document.value.positionFromDocbyte(0) } });
}
pub fn deinit(self: *App) void {
    self.text_editor.deinit();
    self.markdown_language.deinit();
    self.zig_language.deinit();
    self.text_component.unref();
    self.text_block.unref();
    self.counter_component.unref();
    self.counter_block.unref();
    self.db_sync.deinit();
    self.db.deinit();
}

pub fn render(self: *App, call_info: B2.StandardCallInfo, b1: *Beui) B2.StandardChild {
    const ui = call_info.ui(@src());

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
            self.text_editor.core.setSynHl(self.zig_language.language());
        }
        if (zgui.button("markdown", .{})) {
            self.text_editor.core.setSynHl(self.markdown_language.language());
        }
        if (zgui.button("plaintext", .{})) {
            self.text_editor.core.setSynHl(null);
        }
    }

    return self.text_editor.gui(ui.sub(@src()), b1);
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
