const std = @import("std");
const Beui = @import("Beui.zig");
const ft = Beui.font_experiment.ft;
const hb = Beui.font_experiment.hb;
const sb = Beui.font_experiment.sb;
const tracy = @import("anywhere").tracy;

const LayoutCache = @This();

// will also hold glyph cache and glyph images
layout_cache: std.StringArrayHashMap(LayoutInfo),
font: Font,
gpa: std.mem.Allocator,
glyphs: Beui.Texpack,
glyph_cache: std.AutoHashMap(u32, GlyphCacheEntry),
glyphs_cache_full: bool,

pub fn init(gpa: std.mem.Allocator, font: Font) LayoutCache {
    return .{
        .layout_cache = .init(gpa),
        .font = font,
        .gpa = gpa,
        .glyphs = Beui.Texpack.init(gpa, 2048, .greyscale) catch @panic("oom"),
        .glyph_cache = .init(gpa),
        .glyphs_cache_full = false,
    };
}
pub fn deinit(self: *LayoutCache) void {
    for (self.layout_cache.keys()) |k| self.gpa.free(k);
    for (self.layout_cache.values()) |v| self.gpa.free(v.items);
    self.layout_cache.deinit();
    self.glyph_cache.deinit();
    self.glyphs.deinit(self.gpa);
    self.font.deinit();
}

pub const LayoutItem = struct {
    docbyte_offset_from_layout_line_start: u64,
    glyph_id: u32,
    offset: @Vector(2, f32),
    advance: @Vector(2, f32),
};
pub const LayoutInfo = struct {
    last_used: i64,
    ticked_last_frame: bool,
    height: f32,
    items: []LayoutItem,
};
const ShapingSegment = struct {
    length: usize,
    replace_text: ?[]const u8 = null,

    // TODO more stuff in here, ie text direction, ...
};
pub const Font = struct {
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

        const ft_face = Beui.font_experiment.getFtLib().createFaceMemory(font_data, 0) catch |err| {
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

// if we add an event listener for changes to the component:
// - we could maintain our own list of every character and its size, and modify
//   it when the component is edited
// - this will let us quickly go from bufbyte -> screen position
// - or from screen position -> bufbyte
// - and it will always give us access to total scroll height

pub fn tick(self: *LayoutCache, beui: *Beui) void {
    const max_time = 10_000;
    const last_valid_time = beui.frame.frame_cfg.?.now_ms - max_time;

    if (self.glyphs_cache_full) {
        std.log.info("recreating glyph cache", .{});
        self.glyphs.clear();
        self.glyph_cache.clearRetainingCapacity();
        self.glyphs_cache_full = false;
        // TODO if it's full two frames in a row, give up for a little while
    }

    var i: usize = 0;
    while (i < self.layout_cache.count()) {
        const key = self.layout_cache.keys()[i];
        const value = &self.layout_cache.values()[i];
        if (!value.ticked_last_frame and value.last_used < last_valid_time) {
            self.gpa.free(value.items);
            // value pointer invalidates after this line
            std.debug.assert(self.layout_cache.swapRemove(key));
            self.gpa.free(key);
            // don't increment i; must process this item again because it just changed
        } else {
            value.ticked_last_frame = false;
            i += 1;
        }
    }
}

/// result pointer is valid until next layoutLine() call
pub fn layoutLine(self: *LayoutCache, beui: *Beui, line_text: []const u8) LayoutInfo {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const gpres = self.layout_cache.getOrPut(line_text) catch @panic("oom");
    if (gpres.found_existing) {
        gpres.value_ptr.last_used = beui.frame.frame_cfg.?.now_ms;
        gpres.value_ptr.ticked_last_frame = true;
        return gpres.value_ptr.*;
    }

    var layout_result_al: std.ArrayList(LayoutItem) = .init(self.gpa);
    defer layout_result_al.deinit();

    gpres.value_ptr.* = layoutLine_internal(self, line_text, &layout_result_al);
    gpres.key_ptr.* = self.gpa.dupe(u8, line_text) catch @panic("oom");
    gpres.value_ptr.last_used = beui.frame.frame_cfg.?.now_ms;
    gpres.value_ptr.ticked_last_frame = true;
    gpres.value_ptr.items = layout_result_al.toOwnedSlice() catch @panic("oom");

    return gpres.value_ptr.*;
}
fn layoutLine_internal(self: *LayoutCache, line_text: []const u8, layout_result_al: *std.ArrayList(LayoutItem)) LayoutInfo {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const line_height: f32 = 16;

    if (line_text.len == 0) return .{
        .last_used = 0,
        .ticked_last_frame = true,
        .height = line_height,
        .items = &.{
            // TODO add an invisible char for the last one or something
        },
    };

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

    var segments_al = std.ArrayList(ShapingSegment).init(self.gpa);
    defer segments_al.deinit();

    segments_al.append(.{ .length = line_text.len }) catch @panic("oom");
    std.debug.assert(line_text.len > 0); // handled above
    if (line_text[line_text.len - 1] == '\n') {
        var last = segments_al.pop();
        last.length -= 1;
        if (last.length > 0) segments_al.append(last) catch @panic("oom");
        segments_al.append(.{ .length = 1, .replace_text = "_" }) catch @panic("oom");
    }

    layout_result_al.clearRetainingCapacity();

    var start_offset: usize = 0;
    for (segments_al.items) |segment| {
        const buf: hb.Buffer = hb.Buffer.init() orelse @panic("oom");
        defer buf.deinit();

        if (segment.replace_text) |rpl| {
            std.debug.assert(rpl.len == segment.length);
            buf.addUTF8(rpl, 0, @intCast(segment.length));
        } else {
            _ = line_text[start_offset..][0..segment.length];
            buf.addUTF8(line_text, @intCast(start_offset), @intCast(segment.length)); // invalid utf-8 is ok, so we don't have to call the replace fn ourselves
        }
        defer start_offset += segment.length;

        buf.setDirection(.ltr);
        buf.setScript(.latin);
        buf.setLanguage(.fromString("en"));

        self.font.hb_font.shape(buf, null);

        for (
            buf.getGlyphInfos(),
            buf.getGlyphPositions().?,
        ) |glyph_info, glyph_relative_pos| {
            const glyph_id = glyph_info.codepoint;
            const glyph_docbyte = start_offset + glyph_info.cluster;
            const glyph_flags = glyph_info.getFlags();

            const glyph_offset: @Vector(2, i64) = .{ glyph_relative_pos.x_offset, glyph_relative_pos.y_offset };
            const glyph_advance: @Vector(2, i64) = .{ glyph_relative_pos.x_advance, glyph_relative_pos.y_advance };

            layout_result_al.append(.{
                .glyph_id = glyph_id,
                .docbyte_offset_from_layout_line_start = glyph_docbyte,
                .offset = @as(@Vector(2, f32), @floatFromInt(glyph_offset)) / @as(@Vector(2, f32), @splat(64.0)),
                .advance = @as(@Vector(2, f32), @floatFromInt(glyph_advance)) / @as(@Vector(2, f32), @splat(64.0)),
            }) catch @panic("oom");

            _ = glyph_flags;
        }
    }

    return .{
        .last_used = 0,
        .ticked_last_frame = true,
        .height = line_height,
        .items = layout_result_al.items,
    };
}

pub fn renderGlyph(self: *LayoutCache, glyph_id: u32, line_height: f32) GlyphCacheEntry {
    const gpres = self.glyph_cache.getOrPut(glyph_id) catch @panic("oom");
    if (gpres.found_existing) return gpres.value_ptr.*;
    const result: GlyphCacheEntry = self.renderGlyph_nocache(glyph_id, line_height) catch |e| blk: {
        std.log.err("render glyph error: glyph={d}, err={s}", .{ glyph_id, @errorName(e) });
        break :blk .{ .size = .{ 0, 0 }, .region = null };
    };
    gpres.value_ptr.* = result;
    return result;
}
fn renderGlyph_nocache(self: *LayoutCache, glyph_id: u32, line_height: f32) !GlyphCacheEntry {
    try self.font.ft_face.loadGlyph(glyph_id, .{ .render = true });
    const glyph = self.font.ft_face.glyph();
    const bitmap = glyph.bitmap();

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
        .offset = .{ @floatFromInt(glyph.bitmapLeft()), (line_height - 4) - @as(f32, @floatFromInt(glyph.bitmapTop())) },
        .size = .{ bitmap.width(), bitmap.rows() },
        .region = region,
    };
}

pub const GlyphCacheEntry = struct {
    size: @Vector(2, u32),
    offset: @Vector(2, f32) = .{ 0, 0 },
    region: ?Beui.Texpack.Region,
};
