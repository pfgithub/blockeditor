const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;
const draw_lists = Beui.draw_lists;
const Beui = @import("Beui.zig");
const tracy = @import("anywhere").tracy;
const zgui = @import("anywhere").zgui;
const LayoutCache = @import("LayoutCache.zig");
const B2 = Beui.beui_experiment;

const ft = Beui.font_experiment.ft;
const hb = Beui.font_experiment.hb;
const sb = Beui.font_experiment.sb;

pub const Core = @import("texteditor").Core;
const EditorView = @This();

gpa: std.mem.Allocator,
core: Core,
selecting: bool = false,
_layout_temp_al: std.ArrayList(u8),

verdana_ttf: ?[]const u8,
layout_cache_2: LayoutCache,

config: struct {
    syntax_highlighting: bool = true,
} = .{},

scroll: struct {
    /// null = start of file
    line_before_anchor: ?Core.Position = null,
    offset: f32 = 0.0,
},

pub fn initFromDoc(self: *EditorView, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
    const verdana_ttf: ?[]const u8 = for (&[_][]const u8{
        // cwd
        "Verdana.ttf",
        // linux
        "/usr/share/fonts/TTF/verdana.ttf",
        // mac
        "/System/Library/Fonts/Supplemental/Verdana.ttf",
        // windows
        "c:\\WINDOWS\\Fonts\\VERDANA.TTF",
    }) |search_path| {
        break std.fs.cwd().readFileAlloc(gpa, search_path, std.math.maxInt(usize)) catch continue;
    } else null;
    if (verdana_ttf == null) std.log.info("Verdana could not be found. Falling back to Noto Sans.", .{});
    const font = LayoutCache.Font.init(verdana_ttf orelse Beui.font_experiment.NotoSansMono_wght) orelse @panic("no font");

    self.* = .{
        .gpa = gpa,
        .core = undefined,
        .scroll = .{},
        ._layout_temp_al = .init(gpa),
        .layout_cache_2 = .init(gpa, font),

        .verdana_ttf = verdana_ttf,
    };
    self.core.initFromDoc(gpa, document);
}
pub fn deinit(self: *EditorView) void {
    self.layout_cache_2.deinit();
    if (self.verdana_ttf) |v| self.gpa.free(v);
    self._layout_temp_al.deinit();
    self.core.deinit();
}

fn layoutLine(self: *EditorView, beui: *Beui, line_middle: Core.Position) LayoutCache.LayoutInfo {
    std.debug.assert(self._layout_temp_al.items.len == 0);
    defer self._layout_temp_al.clearRetainingCapacity();

    const line_start = self.core.getLineStart(line_middle);
    const line_end = self.core.getNextLineStart(line_start); // includes the '\n' character because that shows up in invisibles selection
    const line_start_docbyte = self.core.document.value.docbyteFromPosition(line_start);
    const line_len = self.core.document.value.docbyteFromPosition(line_end) - line_start_docbyte;

    self.core.document.value.readSlice(line_start, self._layout_temp_al.addManyAsSlice(line_len) catch @panic("oom"));

    return self.layout_cache_2.layoutLine(beui, self._layout_temp_al.items);
}

pub fn gui(self: *EditorView, call_info: B2.StandardCallInfo, beui: *Beui) B2.StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    const text_bg_rdl = ui.id.b2.draw();
    const text_rdl = ui.id.b2.draw();
    const text_cursor_rdl = ui.id.b2.draw();
    rdl.place(text_cursor_rdl, .{ 0, 0 });
    rdl.place(text_rdl, .{ 0, 0 });
    rdl.place(text_bg_rdl, .{ 0, 0 });

    const content_region_size: @Vector(2, f32) = .{ @floatFromInt(call_info.constraints.available_size.w.?), @floatFromInt(call_info.constraints.available_size.h.?) };

    self.layout_cache_2.tick(beui);

    const arena = beui.arena();
    _ = arena;
    const block = self.core.document.value;

    if (beui.hotkey(.{ .alt = .maybe, .ctrl_or_cmd = .maybe, .shift = .maybe }, &.{ .left, .right })) |hk| {
        self.core.executeCommand(.{ .move_cursor_left_right = .{
            .direction = switch (hk.key) {
                .left => .left,
                .right => .right,
            },
            .stop = switch (hk.alt or hk.ctrl_or_cmd) {
                false => .unicode_grapheme_cluster,
                true => .word,
            },
            .mode = switch (hk.shift) {
                false => .move,
                true => .select,
            },
        } });
    }
    if (beui.hotkey(.{ .shift = .maybe }, &.{ .home, .end })) |hk| {
        // maybe should be .move_cursor_to_line_side
        self.core.executeCommand(.{ .move_cursor_left_right = .{
            .direction = switch (hk.key) {
                .home => .left,
                .end => .right,
            },
            .stop = .line,
            .mode = switch (hk.shift) {
                false => .move,
                true => .select,
            },
        } });
    }
    if (beui.hotkey(.{ .alt = .maybe, .ctrl_or_cmd = .maybe }, &.{ .backspace, .delete })) |hk| {
        self.core.executeCommand(.{ .delete = .{
            .direction = switch (hk.key) {
                .backspace => .left,
                .delete => .right,
            },
            .stop = switch (hk.alt or hk.ctrl_or_cmd) {
                false => .unicode_grapheme_cluster,
                true => .word,
            },
        } });
    }
    if (beui.hotkey(.{ .alt = .yes }, &.{ .down, .up })) |hk| {
        self.core.executeCommand(.{ .ts_select_node = .{
            .direction = switch (hk.key) {
                .down => .child,
                .up => .parent,
            },
        } });
    }
    if (beui.hotkey(.{ .shift = .maybe }, &.{ .down, .up })) |hk| {
        self.core.executeCommand(.{ .move_cursor_up_down = .{
            .direction = switch (hk.key) {
                .down => .down,
                .up => .up,
            },
            .metric = .byte,
            .mode = switch (hk.shift) {
                false => .move,
                true => .select,
            },
        } });
    }
    if (beui.hotkey(.{ .alt = .yes, .ctrl_or_cmd = .yes }, &.{ .down, .up })) |hk| {
        self.core.executeCommand(.{ .move_cursor_up_down = .{
            .direction = switch (hk.key) {
                .down => .down,
                .up => .up,
            },
            .metric = .byte,
            .mode = .duplicate,
        } });
    }
    if (beui.hotkey(.{}, &.{.enter})) |_| {
        self.core.executeCommand(.newline);
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .maybe }, &.{.enter})) |hk| {
        self.core.executeCommand(.{ .insert_line = .{
            .direction = switch (hk.shift) {
                false => .down,
                true => .up,
            },
        } });
    }
    if (beui.hotkey(.{ .shift = .maybe }, &.{.tab})) |hk| {
        self.core.executeCommand(.{ .indent_selection = .{
            .direction = switch (hk.shift) {
                false => .right,
                true => .left,
            },
        } });
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.a})) |_| {
        self.core.executeCommand(.select_all);
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .maybe }, &.{.z})) |hk| {
        self.core.executeCommand(switch (hk.shift) {
            false => .undo,
            true => .redo,
        });
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.y})) |_| {
        self.core.executeCommand(.redo);
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes, .shift = .yes }, &.{.d})) |_| {
        self.core.executeCommand(.{ .duplicate_line = .{ .direction = .down } });
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{ .x, .c })) |hk| {
        var copy_txt = std.ArrayList(u8).init(self.gpa);
        defer copy_txt.deinit();
        self.core.copyArrayListUtf8(&copy_txt, switch (hk.key) {
            .x => .cut,
            .c => .copy,
        });
        copy_txt.append('\x00') catch @panic("oom");
        beui.setClipboard(copy_txt.items[0 .. copy_txt.items.len - 1 :0]);
    }
    if (beui.hotkey(.{ .ctrl_or_cmd = .yes }, &.{.v})) |_| {
        var paste_txt = std.ArrayList(u8).init(self.gpa);
        defer paste_txt.deinit();
        beui.getClipboard(&paste_txt);
        self.core.executeCommand(.{ .paste = .{ .text = paste_txt.items } });
    }

    if (beui.textInput()) |text| {
        self.core.executeCommand(.{ .insert_text = .{ .text = text } });
    }

    self.scroll.offset -= beui.frame.scroll_px[1];

    if (self.scroll.line_before_anchor != null) self.scroll.line_before_anchor = self.core.getLineStart(self.scroll.line_before_anchor.?);
    blk: {
        const tctx_ = tracy.traceNamed(@src(), "handle scroll offsets");
        defer tctx_.end();

        if (self.scroll.offset < 0) {
            while (self.scroll.line_before_anchor != null and self.scroll.offset < 0) {
                var prev_line: ?Core.Position = self.core.getPrevLineStart(self.scroll.line_before_anchor.?);
                if (block.docbyteFromPosition(prev_line.?) == block.docbyteFromPosition(self.scroll.line_before_anchor.?)) {
                    // no prev line
                    prev_line = null;
                }
                const line_measure = self.layoutLine(beui, self.scroll.line_before_anchor.?);
                self.scroll.offset += @floatFromInt(line_measure.height);
                self.scroll.line_before_anchor = prev_line;
            }
            break :blk;
        }
        while (true) {
            const this_line = self.core.getLineStart(blk2: {
                if (self.scroll.line_before_anchor) |v| break :blk2 self.core.getNextLineStart(v);
                break :blk2 block.positionFromDocbyte(0);
            });
            if (self.scroll.line_before_anchor != null and block.docbyteFromPosition(this_line) == block.docbyteFromPosition(self.scroll.line_before_anchor.?)) {
                // no next line
                break :blk;
            }
            const this_measure = self.layoutLine(beui, this_line);
            if (self.scroll.offset > @as(f32, @floatFromInt(this_measure.height))) {
                self.scroll.offset -= @floatFromInt(this_measure.height);
                self.scroll.line_before_anchor = this_line;
                continue;
            } else {
                break;
            }
        }
    }

    const render_start_pos = self.core.getLineStart(blk: {
        if (self.scroll.line_before_anchor) |v| break :blk self.core.getNextLineStart(v);
        break :blk block.positionFromDocbyte(0);
    });

    const window_pos: @Vector(2, f32) = .{ 10, 10 };
    const window_size: @Vector(2, f32) = content_region_size - @Vector(2, f32){ 20, 20 };

    var cursor_positions = self.core.getCursorPositions();
    defer cursor_positions.deinit();

    var syn_hl = self.core.highlight();
    defer syn_hl.deinit();

    const replace_space = self.layout_cache_2.font.ft_face.getCharIndex('·') orelse self.layout_cache_2.font.ft_face.getCharIndex('_');
    const replace_tab = self.layout_cache_2.font.ft_face.getCharIndex('⇥') orelse self.layout_cache_2.font.ft_face.getCharIndex('→') orelse self.layout_cache_2.font.ft_face.getCharIndex('>');
    const replace_newline = self.layout_cache_2.font.ft_face.getCharIndex('⏎') orelse self.layout_cache_2.font.ft_face.getCharIndex('␊') orelse self.layout_cache_2.font.ft_face.getCharIndex('\\');
    const replace_cr = self.layout_cache_2.font.ft_face.getCharIndex('␍') orelse self.layout_cache_2.font.ft_face.getCharIndex('<');

    var line_to_render = render_start_pos;
    var line_pos: @Vector(2, f32) = @floor(@Vector(2, f32){ 10, 10 - self.scroll.offset });
    var click_target: ?usize = 0;
    while (true) {
        const tctx_ = tracy.traceNamed(@src(), "handle line");
        defer tctx_.end();

        if (line_pos[1] > (window_pos + window_size)[1]) break;

        const layout_test = self.layoutLine(beui, line_to_render);
        const line_start_docbyte = block.docbyteFromPosition(self.core.getLineStart(line_to_render));
        var cursor_pos: @Vector(2, f32) = .{ 0, 0 };
        var length_with_no_selection_render: f32 = 0.0;
        for (layout_test.items, 0..) |item, i| {
            const item_docbyte = line_start_docbyte + item.docbyte_offset_from_layout_line_start;
            const next_glyph_docbyte: u64 = if (i + 1 >= layout_test.items.len) item_docbyte + 1 else line_start_docbyte + layout_test.items[i + 1].docbyte_offset_from_layout_line_start;
            const len = next_glyph_docbyte - item_docbyte;
            if (next_glyph_docbyte == item_docbyte) {
                length_with_no_selection_render += item.advance[0];
            } else {
                length_with_no_selection_render = 0;
            }
            const single_char: u8 = if (len == 1) blk: {
                break :blk block.read(block.positionFromDocbyte(item_docbyte))[0];
            } else '?';
            const replace_invisible_glyph_id: ?u32 = switch (single_char) {
                '\n' => replace_newline,
                '\r' => replace_cr,
                ' ' => replace_space,
                '\t' => replace_tab,
                else => null,
            };
            const start_docbyte_selected = cursor_positions.advanceAndRead(item_docbyte).selected;
            const item_offset = @round(item.offset);

            if (replace_invisible_glyph_id) |invis_glyph| {
                const tctx__ = tracy.traceNamed(@src(), "render invisible glyph");
                defer tctx__.end();

                // TODO: also show invisibles for trailing whitespace
                if (start_docbyte_selected) {
                    const tint = DefaultTheme.synHlColor(.invisible);

                    const invis_glyph_info = self.layout_cache_2.renderGlyph(invis_glyph, layout_test.height);
                    if (invis_glyph_info.region) |region| {
                        const glyph_size: @Vector(2, f32) = @floatFromInt(invis_glyph_info.size);
                        const glyph_offset: @Vector(2, f32) = @floatFromInt(invis_glyph_info.offset);

                        text_rdl.addRegion(.{
                            .pos = line_pos + cursor_pos + item_offset + glyph_offset,
                            .size = glyph_size,
                            .region = region,
                            .image = .editor_view_glyphs,
                            .image_size = self.layout_cache_2.glyphs.size,
                            .tint = tint,
                        });
                    }
                }
            } else {
                const tctx__ = tracy.traceNamed(@src(), "render glyph");
                defer tctx__.end();

                const glyph_info = self.layout_cache_2.renderGlyph(item.glyph_id, layout_test.height);
                if (glyph_info.region) |region| {
                    const glyph_size: @Vector(2, f32) = @floatFromInt(glyph_info.size);
                    const glyph_offset: @Vector(2, f32) = @floatFromInt(glyph_info.offset);

                    const tint: Core.Highlighter.SynHlColorScope = switch (self.config.syntax_highlighting) {
                        true => syn_hl.advanceAndRead(item_docbyte),
                        false => .unstyled,
                    };
                    text_rdl.addRegion(.{
                        .pos = line_pos + cursor_pos + item_offset + glyph_offset,
                        .size = glyph_size,
                        .region = region,
                        .image = .editor_view_glyphs,
                        .image_size = self.layout_cache_2.glyphs.size,
                        .tint = DefaultTheme.synHlColor(tint),
                    });
                }
            }

            const total_width: f32 = length_with_no_selection_render + item.advance[0];
            // "…" is composed of "\xE2\x80\xA6" - this means it has three valid cursor positions (when moving with .byte). Include them all.
            for (0..@intCast(len)) |docbyte_offset| {
                const tctx__ = tracy.traceNamed(@src(), "render cursor and highlight");
                defer tctx__.end();

                const docbyte = item_docbyte + docbyte_offset;
                const cursor_info = cursor_positions.advanceAndRead(docbyte);

                const portion = @floor(@as(f32, @floatFromInt(docbyte_offset)) / @as(f32, @floatFromInt(len)) * total_width);
                const portion_next = @floor(@as(f32, @floatFromInt(docbyte_offset + 1)) / @as(f32, @floatFromInt(len)) * total_width);
                const portion_width = portion_next - portion;

                if (cursor_info.left_cursor == .focus) {
                    text_cursor_rdl.addRect(.{
                        .pos = @floor(line_pos + cursor_pos + @Vector(2, f32){ -length_with_no_selection_render + portion, -1 }),
                        .size = .{ 2, @floatFromInt(layout_test.height) },
                        .tint = DefaultTheme.cursor_color,
                    });
                }
                if (cursor_info.selected) {
                    text_bg_rdl.addRect(.{
                        .pos = @floor(line_pos + cursor_pos + @Vector(2, f32){ -length_with_no_selection_render + portion, 0 }),
                        .size = .{ portion_width, @floatFromInt(layout_test.height) },
                        .tint = DefaultTheme.selection_color,
                    });
                }

                // click target problem
                // imagine the character "𒐫" <- this is composed of four bytes, so it will be split up into
                // [ ][ ][ ][ ]. then if we cut those in half that's [|][|][|][|]. so you will be clicking on the left side
                // of this four byte char for three out of the four cursor positions. only halfway through the last byte
                // will you click on the right.
                //
                // so for now let's just set the click target if >. later we can make it properly handle clicking halfway. somehow.
                // - some kind of thing about going left and right to the nearest stops, measuring their on-screen distances,
                //   and picking the one closer to the mouse x position. or something like that.

                const min = @floor(line_pos + cursor_pos + @Vector(2, f32){ -length_with_no_selection_render + portion, 0 });
                if (@reduce(.And, beui.persistent.mouse_pos > min)) {
                    click_target = docbyte;
                }
            }

            cursor_pos += item.advance;
            cursor_pos = @floor(cursor_pos);
        }
        line_pos[1] += @floatFromInt(layout_test.height);

        const next_line = self.core.getNextLineStart(line_to_render);
        if (block.docbyteFromPosition(next_line) == block.docbyteFromPosition(line_to_render)) break;
        line_to_render = next_line;
    }

    if (click_target) |clicked_bufbyte| {
        const clicked_pos = block.positionFromDocbyte(clicked_bufbyte);
        const shift_held = beui.isKeyHeld(.left_shift) or beui.isKeyHeld(.right_shift);
        const alt_held = (beui.isKeyHeld(.left_alt) or beui.isKeyHeld(.right_alt)) != (beui.isKeyHeld(.left_control) or beui.isKeyHeld(.right_control));

        // if we're going to support ctrl+left click to jump to definition, then maybe select ts node needs to be on ctrl right click

        // we would like:
        // - alt click -> jump to defintion
        // - ctrl click -> add multi cursor
        //   - dragging this should select with the just-added multicursor. onDrag isn't set up for that yet, but we'll fix it
        //   - ideally if you drag over a previous cursor and drag back, it won't eat up the previous cursor. but vscode does eat it
        //     so we can eat it too for now
        // - some kind of click -> select ts node
        //   - ideally you can both add multi cursor and select ts node, so if it's alt right click then you should be able to
        //     hold ctrl and the new multicursor you're adding with select_ts_node true
        // - these conflict on mac. that's why vscode has different buttons for these two on mac, windows, and linux. you can
        //   never learn the right buttons

        if (beui.isKeyPressed(.mouse_left)) {
            const mode: ?Core.DragSelectionMode = switch (beui.leftMouseClickedCount()) {
                1 => .{ .stop = .unicode_grapheme_cluster, .select = false },
                2 => .{ .stop = .word, .select = true },
                3 => .{ .stop = .line, .select = true },
                else => null,
            };
            if (mode) |sel_mode| {
                self.core.executeCommand(.{ .click = .{
                    .pos = clicked_pos,
                    .mode = sel_mode,
                    .extend = shift_held,
                    .select_ts_node = alt_held,
                } });
            } else {
                self.core.executeCommand(.select_all);
            }
            self.selecting = true;
        } else if (self.selecting and beui.isKeyHeld(.mouse_left)) {
            self.core.executeCommand(.{ .drag = .{ .pos = clicked_pos } });
        }
    }
    if (!beui.isKeyHeld(.mouse_left)) {
        self.selecting = false;
    }

    if (zgui.beginWindow("Editor Debug", .{})) {
        defer zgui.endWindow();

        zgui.text("click_target: {?d}", .{click_target});

        zgui.checkbox("Syntax Highlighting", &self.config.syntax_highlighting);

        for (self.core.cursor_positions.items) |cursor| {
            const lyncol = block.lynColFromPosition(cursor.pos.focus);
            zgui.text("current pos: Ln {d}, Col {d}", .{ lyncol.lyn + 1, lyncol.col + 1 });
        }
    }

    if (zgui.beginWindow("Tree Sitter Info", .{})) {
        defer zgui.endWindow();

        for (self.core.cursor_positions.items) |cursor_pos| {
            const range = self.core.selectionToPosLen(cursor_pos.pos);
            if (self.core.syn_hl_ctx) |*c| c.guiInspectNodeUnderCursor(range.left_docbyte, range.right_docbyte);
        }
    }

    // background
    rdl.addRect(.{ .pos = .{ 0, 0 }, .size = content_region_size, .tint = DefaultTheme.editor_bg });
    return .{ .rdl = rdl, .size = @intFromFloat(content_region_size) };
}

const DefaultTheme = struct {
    // colors are defined in srgb
    // we can make this a simple json file with {"editor_bg": "#mycolor"}
    pub const editor_bg: Beui.Color = .fromHexRgb(0x1d252c);
    pub const selection_color: Beui.Color = .fromHexRgb(0x28323a);
    pub const cursor_color: Beui.Color = .fromHexRgb(0x5EC4FF);

    pub fn synHlColor(syn_hl_color: Core.Highlighter.SynHlColorScope) Beui.Color {
        return .fromHexRgb(switch (syn_hl_color) {
            .invalid => 0xFF0000,

            .keyword_storage => 0x008B94,
            .literal => 0xe27e8d,
            .variable_function => 0x70e1e8,
            .punctuation_important => 0xb7c5d3,
            .variable => 0x718ca1,
            .variable_parameter => 0xEBBF83,
            .literal_string => 0x68a1f0,
            .keyword_primitive_type => 0x70e1e8,
            .punctuation => 0x718ca1,
            .keyword => 0x5ec4ff,
            .variable_constant => 0x8BD49C,
            .variable_mutable => 0xB7C5D3,
            .comment => 0xff9d1c,
            .markdown_plain_text => 0xFFFFFF,

            .unstyled => 0xB7C5D3,
            .invisible => 0x43515c,
        });
    }
};

// CLIPBOARD:
// https://github.com/microsoft/vscode/blob/faf7a5c748720c4f7962f462de058da4c12b54f5/src/vs/editor/browser/controller/editContext/native/nativeEditContext.ts#L370
// - vscode stores clipboard metadata and writes text to the clipboard
// - vscode copies as an array of lines
// - we could copy a block with text fallback, or we could copy text and store a lines array somewhere and only use it if the hash matches.
// - we'll want to copy blocks eventually but it doesn't have to be now.
// copy with glfw_window.clipboard something
