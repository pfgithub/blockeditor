const std = @import("std");
const blocks_mod = @import("blocks");
const db_mod = blocks_mod.blockdb;
const bi = blocks_mod.blockinterface2;
const util = blocks_mod.util;
const draw_lists = beui_mod.draw_lists;
const zglfw = @import("zglfw");
const zgui = @import("zgui"); // zgui doesn't have everything! we should use cimgui + translate-c like we used to
const beui_mod = @import("beui");

const ft = beui_mod.font_experiment.ft;
const hb = beui_mod.font_experiment.hb;
const sb = beui_mod.font_experiment.sb;

const editor_core = @import("texteditor").core;

pub const LayoutItem = struct {
    docbyte: u64,
    glyph_id: u32,
    pos: @Vector(2, f32),
};
pub const LayoutInfo = struct {
    height: f64,
    items: []LayoutItem,
};
const ShapingSegment = struct {
    length: usize,

    // TODO more stuff in here, ie text direction, ...
};

const Font = struct {
    // TODO
    // beui can hold a font cache
    // this can also be where getFtLib is defined

    hb_font: hb.Font,
    ft_face: ft.Face,

    pub fn init(font_data: []const u8) ?Font {
        // const hb_blob = hb.Blob.init(@constCast(font_data), .readonly) orelse return null;
        // errdefer hb_blob.deinit();

        // const hb_face = hb.Face.init(hb_blob, 0);
        // errdefer hb_face.deinit();

        // const hb_font = hb.Font.init(hb_face);
        // errdefer hb_font.deinit();

        const ft_face = beui_mod.font_experiment.getFtLib().createFaceMemory(font_data, 0) catch |err| {
            std.log.err("ft createFaceMemory fail: {s}", .{@errorName(err)});
            return null;
        };
        errdefer ft_face.deinit();

        ft_face.setCharSize(12 * 64, 12 * 64, 0, 0) catch return null;

        const hb_font = hb.Font.fromFreetypeFace(ft_face);
        errdefer hb_font.deinit();

        return .{
            .hb_font = hb_font,
            .ft_face = ft_face,
        };
    }

    pub fn deinit(self: *Font) void {
        self.hb_font.deinit();
        self.ft_face.deinit();
    }
};

const GlyphCacheEntry = struct { size: @Vector(2, u32), offset: @Vector(2, i32) = .{ 0, 0 }, region: ?beui_mod.texpack.Region };

pub const EditorView = struct {
    gpa: std.mem.Allocator,
    core: editor_core.EditorCore,
    selecting: bool = false,
    _layout_temp_al: std.ArrayList(u8),
    _layout_result_temp_al: std.ArrayList(LayoutItem),

    font: ?Font,
    glyphs: beui_mod.texpack,
    glyph_cache: std.AutoHashMap(u32, GlyphCacheEntry),
    glyphs_cache_full: bool,
    verdana_ttf: ?[]const u8,

    scroll: struct {
        /// null = start of file
        line_before_anchor: ?editor_core.Position = null,
        offset: f64 = 0.0,
    },

    pub fn initFromDoc(self: *EditorView, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
        const verdana_ttf: ?[]const u8 = std.fs.cwd().readFileAlloc(gpa, "/usr/share/fonts/TTF/verdana.ttf", std.math.maxInt(usize)) catch null;

        self.* = .{
            .gpa = gpa,
            .core = undefined,
            .scroll = .{},
            ._layout_temp_al = .init(gpa),
            ._layout_result_temp_al = .init(gpa),
            .font = .init(verdana_ttf orelse beui_mod.font_experiment.NotoSansMono_wght),
            .glyphs = beui_mod.texpack.init(gpa, 2048, .greyscale) catch @panic("oom"),
            .glyph_cache = .init(gpa),
            .glyphs_cache_full = false,

            .verdana_ttf = verdana_ttf,
        };
        self.core.initFromDoc(gpa, document);
    }
    pub fn deinit(self: *EditorView) void {
        if (self.verdana_ttf) |v| self.gpa.free(v);
        self.glyph_cache.deinit();
        self.glyphs.deinit(self.gpa);
        if (self.font) |*font| font.deinit();
        self._layout_temp_al.deinit();
        self._layout_result_temp_al.deinit();
        self.core.deinit();
    }

    // if we add an event listener for changes to the component:
    // - we could maintain our own list of every character and its size, and modify
    //   it when the component is edited
    // - this will let us quickly go from bufbyte -> screen position
    // - or from screen position -> bufbyte
    // - and it will always give us access to total scroll height

    /// result pointer is valid until next layoutLine() call
    fn layoutLine(self: *EditorView, line_middle: editor_core.Position) LayoutInfo {
        std.debug.assert(self._layout_temp_al.items.len == 0);
        defer self._layout_temp_al.clearRetainingCapacity();

        // TODO: cache layouts. use an addUpdateListener handler to invalidate caches.
        const line_start = self.core.getLineStart(line_middle);
        const line_end = self.core.getNextLineStart(line_start); // includes the '\n' character because that shows up in invisibles selection
        const line_start_docbyte = self.core.document.value.docbyteFromPosition(line_start);
        const line_len = self.core.document.value.docbyteFromPosition(line_end) - line_start_docbyte;

        self.core.document.value.readSlice(line_start, self._layout_temp_al.addManyAsSlice(line_len) catch @panic("oom"));

        // TODO: segment shape() calls based on:
        // - syntax highlighting style (eg in markdown we want to have some text rendered bold, or some as a heading)
        //   - syntax highlighting can change if a line above this one changed, so we will need to throw out the cache of
        //     anything below a changed line
        // - unicode bidi algorithm (fribidi or sheenbidi)
        // - different languages or something??
        //   - UAX 24, SheenBidi has a method for this
        // - fallback characters in different fonts????
        // - maybe use libraqm. it should handle all of this except fallback characters
        // - alternatively, use pango. it handles fallback characters too, if we can get it to build.

        const segments = [_]ShapingSegment{.{ .length = line_len }};

        self._layout_result_temp_al.clearRetainingCapacity();

        var start_offset: usize = 0;
        var cursor_pos: @Vector(2, i64) = .{ 64 * 10, 64 * 10 };
        for (segments) |segment| {
            const buf: hb.Buffer = hb.Buffer.init() orelse @panic("oom");
            defer buf.deinit();

            buf.addUTF8(self._layout_temp_al.items, @intCast(start_offset), @intCast(segment.length)); // invalid utf-8 is ok, so we don't have to call the replace fn ourselves
            defer start_offset += segment.length;

            buf.setDirection(.ltr);
            buf.setScript(.latin);
            buf.setLanguage(.fromString("en"));

            self.font.?.hb_font.shape(buf, null);

            for (
                buf.getGlyphInfos(),
                buf.getGlyphPositions().?,
            ) |glyph_info, glyph_relative_pos| {
                const glyph_id = glyph_info.codepoint;
                const glyph_docbyte = line_start_docbyte + start_offset + glyph_info.cluster;
                const glyph_flags = glyph_info.getFlags();

                const glyph_offset: @Vector(2, i64) = .{ glyph_relative_pos.x_offset, glyph_relative_pos.y_offset };
                const glyph_pos = cursor_pos + glyph_offset;
                cursor_pos += .{ glyph_relative_pos.x_advance, glyph_relative_pos.y_advance };

                self._layout_result_temp_al.append(.{
                    .glyph_id = glyph_id,
                    .docbyte = glyph_docbyte,
                    .pos = @as(@Vector(2, f32), @floatFromInt(glyph_pos)) / @as(@Vector(2, f32), @splat(64.0)),
                }) catch @panic("oom");

                _ = glyph_flags;
            }
        }

        return .{
            .height = 0.0,
            .items = self._layout_result_temp_al.items,
        };
    }

    fn renderGlyph(self: *EditorView, glyph_id: u32) GlyphCacheEntry {
        if (self.glyph_cache.get(glyph_id)) |v| return v;
        const result: GlyphCacheEntry = self.renderGlyph_nocache(glyph_id) catch |e| blk: {
            std.log.err("render glyph error: {s}", .{@errorName(e)});
            break :blk .{ .size = .{ 0, 0 }, .region = null };
        };
        self.glyph_cache.putNoClobber(glyph_id, result) catch @panic("oom");
        return result;
    }
    fn renderGlyph_nocache(self: *EditorView, glyph_id: u32) !GlyphCacheEntry {
        try self.font.?.ft_face.loadGlyph(glyph_id, .{ .render = true });
        const glyph = self.font.?.ft_face.glyph();
        const bitmap = glyph.bitmap();
        const line_height: i32 = 25;

        if (bitmap.buffer() == null) return error.NoBitmapBuffer;

        const region = self.glyphs.reserve(self.gpa, bitmap.width(), bitmap.rows()) catch |e| switch (e) {
            error.AtlasFull => {
                self.glyphs_cache_full = true;
                return .{ .size = .{ bitmap.width(), bitmap.rows() }, .region = null };
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        self.glyphs.set(region, bitmap.buffer().?);

        return .{
            .offset = .{ glyph.bitmapLeft(), line_height - glyph.bitmapTop() },
            .size = .{ bitmap.width(), bitmap.rows() },
            .region = region,
        };
    }

    pub fn gui(self: *EditorView, beui: *beui_mod.Beui, content_region_size: @Vector(2, f32)) void {
        if (self.glyphs_cache_full) {
            self.glyphs.clear();
            self.glyph_cache.clearRetainingCapacity();
            self.glyphs_cache_full = false;
            // TODO if it's full two frames in a row, give up for a little while
        }

        const arena = beui.arena();
        _ = arena;
        const draw_list = beui.draw();
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

        self.scroll.offset += @floatCast(beui.frame.scroll_px[1]);
        const render_start_pos = self.core.getLineStart(blk: {
            if (self.scroll.line_before_anchor == null) break :blk block.positionFromDocbyte(0);
            break :blk self.core.getNextLineStart(self.scroll.line_before_anchor.?);
        });

        // todo: measure height starting line
        // we can offer a function layoutLine(line) to layout and soft wrap a single line, and return metrics about it
        // - eventually, this won't be enough. natural language documents and random binary files will have very
        //   long lines
        // if scroll offset < 0:
        // - measureLineHeight(line_before_anchor)
        // - scroll_offset += line height
        // - line before anchor = block.getThisLineStart(line_before_anchor) - 1
        // else if scroll offset > line height:
        // - line_before_anchor = block.getNextLineStart(line_before_anchor)
        // - scroll offset -= line height
        // and some edge cases for first and last lines

        const window_pos: @Vector(2, f32) = .{ 10, 10 };
        const window_size: @Vector(2, f32) = content_region_size - @Vector(2, f32){ 20, 20 };

        var cursor_positions = self.core.getCursorPositions();
        defer cursor_positions.deinit();

        var syn_hl = self.core.syn_hl_ctx.highlight();
        defer syn_hl.deinit();

        const layout_test = self.layoutLine(render_start_pos);
        for (layout_test.items) |item| {
            const glyph_info = self.renderGlyph(item.glyph_id);
            if (glyph_info.region) |region| {
                const syn_hl_info = syn_hl.advanceAndRead(item.docbyte);
                const glyph_size: @Vector(2, f32) = @floatFromInt(glyph_info.size);
                const glyph_offset: @Vector(2, f32) = @floatFromInt(glyph_info.offset);
                draw_list.addRegion(.{
                    .pos = @floor(item.pos + glyph_offset),
                    .size = glyph_size,
                    .region = region,
                    .image = .editor_view_glyphs,
                    .image_size = self.glyphs.size,
                    .tint = hexToFloat(DefaultTheme.synHlColor(syn_hl_info)),
                });
                // _ = region;
                // draw_list.addRect(item.pos + glyph_offset, glyph_size, .{
                //     .image = null,
                //     .tint = hexToFloat(DefaultTheme.synHlColor(syn_hl_info)),
                // });
                // _ = syn_hl_info;
            }
        }
        draw_list.addRect(.{ 0, 100 }, .{ 2048, 2048 }, .{
            .image = .editor_view_glyphs,
            .uv_pos = .{ 0, 0 },
            .uv_size = .{ 1, 1 },
            .tint = .{ 1, 1, 1, 1 },
        });

        var pos: @Vector(2, f32) = .{ 0, @floatCast(self.scroll.offset) };
        var prev_char_advance: f32 = 0;
        var click_target: ?usize = null;
        for (block.docbyteFromPosition(render_start_pos)..block.length() + 1) |i| {
            const cursor_info = cursor_positions.advanceAndRead(i);
            const char = syn_hl.znh.charAt(i);

            if (cursor_info.left_cursor == .focus) {
                draw_list.addRect(window_pos + pos + @Vector(2, f32){ -1, -1 }, .{
                    1, draw_list.getCharHeight() + 2,
                }, .{ .tint = .{ 1, 1, 1, 1 } });
            }
            const show_invisibles = cursor_info.selected;
            const is_invisible: ?u8 = switch (char) {
                '\x00' => '\x00',
                ' ' => '_', // '·'
                '\n' => '\n', // '⏎'
                '\t' => '\t', // '⇥'
                else => null,
            };
            var char_or_invisible = char;
            if (show_invisibles and is_invisible != null) {
                char_or_invisible = is_invisible.?;
            }

            {
                const min = window_pos + pos + @Vector(2, f32){ -prev_char_advance / 2.0, 0 };
                if (@reduce(.And, beui.persistent.mouse_pos > min)) {
                    click_target = i;
                }
            }

            const char_advance: f32 = draw_list.getCharAdvance(char);
            prev_char_advance = char_advance;
            const invisible_advance: f32 = draw_list.getCharAdvance(char_or_invisible);

            if (pos[0] + char_advance > window_size[0]) {
                pos = .{ 0, pos[1] + draw_list.getCharHeight() };
            }

            const char_offset = @Vector(2, f32){ (invisible_advance - char_advance) / 2.0, 0.0 };

            if ((show_invisibles or is_invisible == null) and pos[0] <= window_size[0] and pos[1] <= window_size[1] and pos[0] >= 0 and pos[1] >= 0) {
                // _ = char_offset;
                draw_list.addChar(char_or_invisible, window_pos + pos + char_offset, hexToFloat(DefaultTheme.synHlColor(switch (is_invisible != null) {
                    true => .invisible,
                    false => syn_hl.advanceAndRead(i),
                })));
            }
            if (cursor_info.selected) {
                draw_list.addRect(window_pos + pos + @Vector(2, f32){ -1, -1 }, .{ char_advance, draw_list.getCharHeight() + 2 - 1 }, .{ .tint = hexToFloat(DefaultTheme.selection_color) });
            }
            if (pos[1] > window_size[1]) break;

            if (char == '\n') {
                pos = .{ 0, pos[1] + draw_list.getCharHeight() };
            } else {
                pos += .{ char_advance, 0 };
            }
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
                const mode: ?editor_core.DragSelectionMode = switch (beui.leftMouseClickedCount()) {
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

        if (zgui.begin("Editor Debug", .{})) {
            zgui.text("draw_list items: {d} / {d}", .{ draw_list.vertices.items.len, draw_list.indices.items.len });
            zgui.text("click_target: {?d}", .{click_target});
            zgui.text("click_count: {d}", .{beui.leftMouseClickedCount()});
        }
        zgui.end();

        // background
        draw_list.addRect(.{ 0, 0 }, content_region_size, .{ .tint = hexToFloat(DefaultTheme.editor_bg) });
    }
};

fn hexToFloat(hex: u32) @Vector(4, f32) {
    const conv_f: @Vector(4, f32) = .{
        @floatFromInt((hex >> 16) & 0xFF),
        @floatFromInt((hex >> 8) & 0xFF),
        @floatFromInt((hex >> 0) & 0xFF),
        255.0,
    };
    return conv_f / @as(@Vector(4, f32), @splat(255.0));
}

const DefaultTheme = struct {
    // colors are defined in srgb
    // we can make this a simple json file with {"editor_bg": "#mycolor"}
    pub const editor_bg: u32 = 0x1d252c;
    pub const selection_color: u32 = 0x28323a;

    pub fn synHlColor(syn_hl_color: editor_core.SynHlColorScope) u32 {
        return switch (syn_hl_color) {
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

            .invisible => 0x2e3c47,
        };
    }
};

// CLIPBOARD:
// https://github.com/microsoft/vscode/blob/faf7a5c748720c4f7962f462de058da4c12b54f5/src/vs/editor/browser/controller/editContext/native/nativeEditContext.ts#L370
// - vscode stores clipboard metadata and writes text to the clipboard
// - vscode copies as an array of lines
// - we could copy a block with text fallback, or we could copy text and store a lines array somewhere and only use it if the hash matches.
// - we'll want to copy blocks eventually but it doesn't have to be now.
// copy with glfw_window.clipboard something
