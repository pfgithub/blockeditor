//! editor that edits a text block

// TODO:
// - [ ] zoom out to view just the top level stuff

const std = @import("std");
const core = @import("mach").core;
const util = @import("../../util.zig");
const build_options = @import("build-options");
const global = @import("../lib/global.zig");
const imgui = global.imgui;
const tracy = @import("../../lib/tracy.zig");
const tree_sitter_zig = @import("./code_editor/languages/tree_sitter.zig");
const tree_sitter = @import("tree-sitter");
const code_globals = @import("./code_editor/code_globals.zig");
const language_interface = @import("./code_editor/languages/language_interface.zig");

const blocks = @import("../blocks.zig");
const block_text_v1 = blocks.block_text_v1;
const BlockTextCallback = blocks.BlockTextCallback;

const editor_core_zig = @import("code_editor/code_editor_core.zig");
const EditorCore = editor_core_zig.EditorCore;
const ByteOffsetConfigurable = editor_core_zig.ByteOffsetConfigurable;
const ByteOffset = editor_core_zig.ByteOffset;
const InsertOp = editor_core_zig.InsertOp;
const DefaultConfig = editor_core_zig.DefaultConfig;

pub const EditorView = struct {
    // each editorcore belongs to only one editorview
    core: EditorCore,

    current_drag_ptr: ?*blocks.block_text_v1 = null,
    current_drag_range: ?struct {
        start: ByteOffset,
        end: ByteOffset,
    } = null,

    focused: bool = false,
    selecting: bool = false,

    prev_height_estimation: f32 = 0,

    pub fn init(self: *EditorView, block_ref: blocks.BlockRef(blocks.block_text_v1), alloc: std.mem.Allocator) void {
        self.core.initFromBlock(block_ref, alloc);
        block_ref.addUpdateListener(self, updateForInsert);
        self.* = .{
            .core = self.core,
        };
    }
    pub fn deinit(self: *EditorView) void {
        global.unsetDragDeleteCallback(util.Callback(void, void).from(self, dragDelete));

        self.core.block_ref.removeUpdateListener(self, updateForInsert);
        self.core.deinit();
    }

    pub fn updateForInsert(self: *EditorView, insert_op: InsertOp) void {
        if (self.current_drag_range) |*range| {
            range.start.updateForInsert(insert_op);
            range.end.updateForInsert(insert_op);
        }
    }

    pub fn charInputEvent(editor: *EditorView, codepoint: u21) void {
        if (!editor.focused) return;
        var out_buf: [4]u8 = undefined;
        const out_len = std.unicode.utf8Encode(codepoint, &out_buf) catch 0;
        if (out_len > 0) editor.core.executeCommand(.{ .insert_text = .{ .text = out_buf[0..out_len] } });
    }
    pub fn gui(editor_view: *EditorView) void {
        const ev_trace = tracy.traceNamed(@src(), "code_editor_view:gui");
        defer ev_trace.end();

        editor_view.focused = false;
        const editor_core = &editor_view.core;

        const block: *const blocks.block_text_v1 = editor_core.block_ref.getDataConst() orelse {
            imgui.text("Loading…");
            return;
        };

        const io = imgui.getIO();

        const window_offset = util.imguiVecToVec2f(imgui.getWindowPos());
        const window_size = util.imguiVecToVec2f(imgui.getWindowSize());
        const content_region_min = util.imguiVecToVec2f(imgui.getWindowContentRegionMin());
        const content_region_max = util.imguiVecToVec2f(imgui.getWindowContentRegionMax());
        const font_size = imgui.getFontSize();
        const window_scroll_y = imgui.getScrollY();

        const draw_list = imgui.getWindowDrawList() orelse return;
        const font = imgui.getFont() orelse return;
        const space_width = imgui.Font_getCharAdvance(font, ' ');

        const content_region_absolute_pos = window_offset + content_region_min;
        const content_region_size = content_region_max - content_region_min;

        // it would be very nice to have text pre layed out
        // that way, we can:
        // - instantly jump to a scroll position
        // - know how tall the scroll is
        // the layout can update on updateForInsert()
        const line_height = font_size;
        const text_ul = content_region_absolute_pos;

        // this is really just an estimate
        // prevent 0-size crash with the max(1, 1)
        // oops! content_region_size isn't good to measure against because then this can only get bigger
        const scroll_region_size = @max(@Vector(2, f32){ 1, 1 }, @max(content_region_size, @Vector(2, f32){ 0, content_region_size[1] - line_height + editor_view.prev_height_estimation }));

        _ = imgui.invisibleButton("gamecanvas", util.vec2fToImguiVec(scroll_region_size), imgui.ButtonFlags_MouseButtonLeft | imgui.ButtonFlags_MouseButtonRight | imgui.ButtonFlags_MouseButtonMiddle);
        const is_hovered = imgui.isItemHovered(0);
        const is_active = imgui.isItemActive();

        if (imgui.isWindowFocused(0)) {
            editor_view.focused = true;
        }
        // if(is_active) {
        //     imgui.setKeyboardFocusHereEx(-1);

        //     // SetActiveID(id, window);
        //     // SetFocusID(id, window);
        // }
        // if(imgui.isItemFocused()) {
        //     editor_view.focused = true;

        //     // SetKeyOwner(ImGuiKey_Enter, id);
        //     // SetKeyOwner(ImGuiKey_KeypadEnter, id);
        //     // SetKeyOwner(ImGuiKey_Home, id);
        //     // SetKeyOwner(ImGuiKey_End, id);
        // }

        if (editor_view.focused) {
            imgui.setNextFrameWantCaptureKeyboard(true);
            const mod_stop_word = imgui.isKeyDown(imgui.Mod_Alt) or imgui.isKeyDown(imgui.Mod_Ctrl);
            const mod_select = imgui.isKeyDown(imgui.Mod_Shift);
            if (imgui.isKeyPressed(imgui.Key_LeftArrow) or imgui.isKeyPressed(imgui.Key_RightArrow)) editor_core.executeCommand(.{
                .move_cursor_left_right = .{
                    .direction = if (imgui.isKeyPressed(imgui.Key_LeftArrow)) .left else .right,
                    .stop = if (mod_stop_word) .word else .byte,
                    .mode = if (mod_select) .select else .move,
                },
            });
            if (imgui.isKeyPressed(imgui.Key_Backspace) or imgui.isKeyPressed(imgui.Key_Delete)) editor_core.executeCommand(.{
                .move_cursor_left_right = .{
                    .direction = if (imgui.isKeyPressed(imgui.Key_Backspace)) .left else .right,
                    .stop = if (mod_stop_word) .word else .byte,
                    .mode = .delete,
                },
            });
            if (imgui.isKeyPressed(imgui.Key_UpArrow) or imgui.isKeyPressed(imgui.Key_DownArrow)) {
                if (mod_stop_word) {
                    editor_core.executeCommand(.{
                        .ts_select_node = .{
                            .direction = if (imgui.isKeyPressed(imgui.Key_UpArrow)) .parent else .child,
                        },
                    });
                } else {
                    editor_core.executeCommand(.{
                        .move_cursor_up_down = .{
                            .direction = if (imgui.isKeyPressed(imgui.Key_UpArrow)) .up else .down,
                            .stop = .line,
                            .mode = if (mod_select) .select else .move,
                        },
                    });
                }
            }
            if (imgui.isKeyPressed(imgui.Key_Enter)) {
                editor_core.executeCommand(.newline);
            }
            // these should support key repeat. whatever.
            if (imgui.isKeyChordPressed(imgui.Key_Tab)) {
                editor_core.executeCommand(.{
                    .indent_selection = .{
                        .direction = .right,
                    },
                });
            }
            if (imgui.isKeyChordPressed(imgui.Mod_Shift | imgui.Key_Tab)) {
                editor_core.executeCommand(.{
                    .indent_selection = .{
                        .direction = .left,
                    },
                });
            }
            if (imgui.isKeyChordPressed(imgui.Mod_Shortcut | imgui.Key_A)) {
                editor_core.executeCommand(.select_all);
            }
            if (imgui.isKeyChordPressed(imgui.Mod_Shortcut | imgui.Key_Z)) {
                editor_core.executeCommand(.undo);
            }
            if (imgui.isKeyChordPressed(imgui.Mod_Shortcut | imgui.Mod_Shift | imgui.Key_Z) or imgui.isKeyChordPressed(imgui.Mod_Shortcut | imgui.Key_Y)) {
                editor_core.executeCommand(.redo);
            }
            if (io.input_queue_characters.size > 0) {
                // never true for some reason
                // maybe the zig-imgui io struct is broken? `io.key_shift` is always true
            }
        }

        // read text
        const gpa = global.global().allocator;
        const buffer = gpa.alloc(u8, block.document.length()) catch @panic("oom");
        defer gpa.free(buffer);
        block.document.readSlice(block.document.positionFromDocbyte(0), buffer);
        // const buffer = block.buffer.items;

        // estimate!
        var code_height: f32 = 0;
        var line_len: f32 = 0;
        var start_idx: usize = 0;
        var start_offset: f32 = 0;
        {
            const ev_trace_1 = tracy.traceNamed(@src(), "premeasure");
            defer ev_trace_1.end();
            for (buffer, 0..) |char, i| {
                if (char == '\n') {
                    code_height += line_height;
                    line_len = 0;
                    if (code_height < window_scroll_y) {
                        start_idx = i + 1;
                        start_offset = code_height;
                    }
                } else {
                    const advance = imgui.Font_getCharAdvance(font, char);
                    if (line_len + advance > content_region_size[0]) {
                        code_height += line_height;
                        line_len = 0;
                    }
                    line_len += advance;
                }
            }
        }
        if (imgui.begin("Debug_", null, 0)) {
            imgui.text(imgui.fmt("start_idx = {d} / {d}", .{ start_idx, start_offset }));
        }
        imgui.end();
        editor_view.prev_height_estimation = code_height;

        var char_offset = @Vector(2, f32){ 0, start_offset };
        const selection_min = editor_core.cursor_position.left();
        const selection_max = editor_core.cursor_position.right();

        const mouse_clicked = is_hovered and imgui.isMouseClicked(imgui.MouseButton_Left);
        const mouse_clicked_count: i32 = imgui.getMouseClickedCount(imgui.MouseButton_Left);
        const mouse_held = is_active and imgui.isMouseDown(imgui.MouseButton_Left);
        const mouse_dragged_abit = is_active and imgui.isMouseDragging(imgui.MouseButton_Left, 4.0);
        const mouse_released = is_hovered and imgui.isMouseReleased(imgui.MouseButton_Left);

        const mouse_pos = util.imguiVecToVec2f(imgui.getMousePos());

        var cursor_offset = @Vector(2, f32){ -1, -1 };

        const syn_hl = editor_core.hlctx.?.language.begin_highlight(editor_core.hlctx.?.context);
        defer editor_core.hlctx.?.language.end_highlight(editor_core.hlctx.?.context, syn_hl);

        // if (editor_core.hlctx == null) @panic("TODO tree sitter init failed");
        // var syn_hl = editor_core.tree_sitter_ctx.?.highlight();
        // defer editor_core.tree_sitter_ctx.?.endHighlight();
        // defer syn_hl.deinit();

        var click_target: ?usize = null;
        var click_target_screen_pos = @Vector(2, f32){ 0, 0 };

        imgui.DrawList_addRectFilled(draw_list, util.vec2fToImguiVec(window_offset), util.vec2fToImguiVec(window_offset + window_size), util.hexToImguiColor(DefaultTheme.editor_bg));

        var prev_char_advance: f32 = 0.0;
        const rlctx = RlCtx{
            .buffer = buffer,
            .syn_hl = .{ .highlighter = syn_hl, .language = editor_core.hlctx.?.language },
            .font = font,
            .text_ul = text_ul,
            .char_offset = &char_offset,
            .prev_char_advance = &prev_char_advance,
            .mouse_pos = mouse_pos,
            .click_target = &click_target,
            .click_target_screen_pos = &click_target_screen_pos,
            .cursor_offset = &cursor_offset,
            .content_region_size = content_region_size,
            .line_height = line_height,
            .selection_min = selection_min,
            .selection_max = selection_max,
            .draw_list = draw_list,
            .font_size = font_size,
            .space_width = space_width,

            .cursor_position_byte = editor_core.cursor_position.pos.focus.value,
        };

        var i: usize = start_idx;
        {
            const ev_trace_1 = tracy.traceNamed(@src(), "highlight and render");
            defer ev_trace_1.end();
            while (i < buffer.len) : (i += 1) {
                if (text_ul[1] + char_offset[1] > content_region_absolute_pos[1] + content_region_size[1] + window_scroll_y) break; // past bottom of page
                // this shouldn't have to handle click_target / click_target_screen_pos,
                // we can handle that before the actual render
                // that would remove a bunch of junk from this struct
                renderChar(rlctx, i);
            }
        }
        if (editor_core.cursor_position.pos.focus.value == block.len()) {
            cursor_offset = char_offset;
        }
        {
            const min = text_ul + char_offset + @Vector(2, f32){ -prev_char_advance / 2, 0 };
            if (@reduce(.And, mouse_pos > min)) {
                click_target = i;
                click_target_screen_pos = char_offset;
            }
        }

        if (imgui.begin("Debug_", null, 0)) {
            imgui.text("Window:");
            imgui.text(imgui.fmt("is_hovered = {}", .{is_hovered}));
            imgui.text(imgui.fmt("is_active = {}", .{is_active}));
            imgui.text(imgui.fmt("mouse_clicked = {}", .{mouse_clicked}));
            imgui.text(imgui.fmt("mouse_clicked_count = {}", .{mouse_clicked_count}));
            imgui.text(imgui.fmt("mouse_released = {}", .{mouse_released}));
            imgui.text(imgui.fmt("mouse_held = {}", .{mouse_held}));
            imgui.text(imgui.fmt("mouse_dragged_abit = {}", .{mouse_dragged_abit}));

            if (click_target) |v| {
                // arena.format(). can reset when the imgui frame resets
                imgui.text(imgui.fmt("target = {d}", .{v}));
            } else {
                imgui.text("target = null");
            }
        }
        imgui.end();

        // WARNING:
        // after this if, indices may be changed
        if (click_target) |target_raw| {
            var target_tracked: ByteOffset = .{ .value = target_raw };
            editor_core.trackPosition(&target_tracked);
            defer editor_core.untrackPosition(&target_tracked);

            const hovering_selection = target_tracked.value >= selection_min and target_tracked.value < selection_max;
            if (mouse_clicked and mouse_clicked_count == 1 and hovering_selection) {
                // clicked in selection; post drag
                // TODO only post drag after the mouse has moved a little to confirm the drag
                if (global.postDrag(true, blocks.block_text_v1)) |drag_ptr| {
                    drag_ptr.initText(editor_core.alloc, block.prevSliceTemp(selection_min, selection_max));

                    // keep track of the drag so if the drop is in the same buffer, a move is done
                    // instead of a copy
                    editor_view.current_drag_ptr = drag_ptr;
                    editor_view.current_drag_range = .{
                        .start = .{ .value = selection_min },
                        .end = .{ .value = selection_max },
                    };
                    global.setDragDeleteCallback(util.Callback(void, void).from(editor_view, dragDelete));
                }
            } else {
                if (if (!hovering_selection) global.peekDrag(is_hovered) else null) |drag| {
                    if (drag.block.getAs(blocks.block_text_v1)) |block_v| {
                        {
                            // maybe we should move the cursor instead?
                            const min = text_ul + click_target_screen_pos + @Vector(2, f32){ 0, -1 };
                            const max = min + @Vector(2, f32){ 1, line_height + 2 };
                            imgui.DrawList_addRectFilled(draw_list, util.vec2fToImguiVec(min), util.vec2fToImguiVec(max), 0xFFFFFFFF);
                            // we want a dashed line, like vscode
                        }
                        // [!] may cause buffers to change
                        if (drag.accept()) {
                            editor_core.moveCursor(target_tracked.value);
                            var it = block_v.document.readIterator(block_v.document.positionFromDocbyte(0));
                            while (it.next()) |text| {
                                editor_core.executeCommand(.{
                                    .insert_text = .{ .text = text },
                                });
                                // these will become extend ops internally so it's okay to put multiple
                            }
                        }
                    }
                } else {
                    if (mouse_clicked) {
                        // click one place then shift click another to select
                        // double click one place then click another to word select
                        editor_core.onClick(target_tracked.value, mouse_clicked_count, imgui.isKeyDown(imgui.Mod_Shift));
                        editor_view.selecting = true;
                    }
                    if (editor_view.selecting and mouse_held) {
                        editor_core.onDrag(target_tracked.value);
                    }
                }
            }
        }
        if (!mouse_held) {
            editor_view.selecting = false;
        }

        if (cursor_offset[0] != -1) {
            const min = text_ul + cursor_offset + @Vector(2, f32){ 0, -1 };
            const max = min + @Vector(2, f32){ 1, line_height + 2 };
            imgui.DrawList_addRectFilled(draw_list, util.vec2fToImguiVec(min), util.vec2fToImguiVec(max), 0xFFFFFFFF);
        }
    }

    const RlCtx = struct {
        buffer: []const u8,
        syn_hl: language_interface.Synhlctx,
        font: *const imgui.Font,
        text_ul: @Vector(2, f32),
        char_offset: *@Vector(2, f32),
        prev_char_advance: *f32,
        mouse_pos: @Vector(2, f32),
        click_target: *?usize,
        click_target_screen_pos: *@Vector(2, f32),
        cursor_offset: *@Vector(2, f32),
        content_region_size: @Vector(2, f32),
        line_height: f32,
        selection_min: usize,
        selection_max: usize,
        draw_list: *imgui.DrawList,
        font_size: f32,
        space_width: f32,

        cursor_position_byte: usize,
    };
    fn renderChar(ctx: RlCtx, i: usize) void {
        const buffer = ctx.buffer;
        const syn_hl = ctx.syn_hl;
        const font = ctx.font;
        const text_ul = ctx.text_ul;
        const char_offset = ctx.char_offset;
        const prev_char_advance = ctx.prev_char_advance;
        const mouse_pos = ctx.mouse_pos;
        const click_target = ctx.click_target;
        const click_target_screen_pos = ctx.click_target_screen_pos;
        const content_region_size = ctx.content_region_size;
        const line_height = ctx.line_height;
        const selection_min = ctx.selection_min;
        const selection_max = ctx.selection_max;
        const draw_list = ctx.draw_list;
        const font_size = ctx.font_size;
        const space_width = ctx.space_width;

        const char = switch (buffer[i]) {
            '\n', ' '...'~' => |c| c,
            0...0x09, 0x0B...0x1F, 0x7F => '?',
            0x80...0xFF => '?', // TODO utf-8
        };
        const syn_hl_color = syn_hl.language.highlight_advanceAndRead(syn_hl.highlighter, i);

        const advance = imgui.Font_getCharAdvance(font, char);
        defer prev_char_advance.* = advance;

        // input handling within draw, odd.
        {
            const min = text_ul + char_offset.* + @Vector(2, f32){ -prev_char_advance.* / 2.0, 0 };
            if (@reduce(.And, mouse_pos > min)) {
                click_target.* = i;
                click_target_screen_pos.* = char_offset.*;
            }
        }

        if (ctx.cursor_position_byte == i) {
            ctx.cursor_offset.* = char_offset.*;
        }

        // maybe this shouldn't be handled here?
        if (char_offset[0] + advance > content_region_size[0]) {
            char_offset.* = .{ 0, char_offset[1] + line_height };
        }
        var char_show_invisibles: u16 = char;
        var char_show_invisibles_advance: f32 = advance;
        const in_selection = i >= selection_min and i < selection_max;
        const show_invisibles = in_selection;
        const is_invisible = switch (char) {
            ' ', '\n', '\t' => true,
            else => false,
        };
        if (show_invisibles) {
            char_show_invisibles = switch (char) {
                ' ' => '·',
                '\n' => '⏎',
                '\t' => '⇥',
                else => char,
            };
            char_show_invisibles_advance = imgui.Font_getCharAdvance(font, char);
        }
        const pos = text_ul + char_offset.*;
        const color_hex = if (is_invisible) DefaultTheme.synHlColor(.invisible) else DefaultTheme.synHlColor(syn_hl_color);
        if (in_selection) {
            // if char is '\n', we still want to render selection to make it clear you have the newline selected
            const min = text_ul + char_offset.*;
            const max = min + @Vector(2, f32){ advance, line_height };
            imgui.DrawList_addRectFilled(draw_list, util.vec2fToImguiVec(min), util.vec2fToImguiVec(max), util.hexToImguiColor(DefaultTheme.selection_color));
        }
        if (!is_invisible or show_invisibles) {
            // note: invisibles will need to be recentered based on their advance
            const actual_width = char_show_invisibles_advance;
            const target_width = advance;
            const char_center_offset = @Vector(2, f32){ (target_width - actual_width) / 2.0, 0 };
            imgui.Font_renderChar(font, draw_list, font_size, util.vec2fToImguiVec(pos + char_center_offset), util.hexToImguiColor(color_hex), char_show_invisibles);
        }
        if (char == '\t') {
            // not how tabs work but it's fine for now
            // we have to do like. add one and round up to the nearest multiple of char_size_mul
            char_offset.* += .{ space_width * DefaultConfig.indent_len, 0 };
            var co0 = char_offset.*[0];
            co0 = std.math.divCeil(f32, co0, DefaultConfig.indent_len) catch @panic("divCeil error");
            co0 = co0 * DefaultConfig.indent_len;
            char_offset.* = .{ co0, char_offset.*[1] };
        } else if (char == '\n') {
            char_offset.* = .{ 0, char_offset.*[1] + line_height };
        } else {
            char_offset.* += .{ advance, 0 };
        }
    }

    fn dragDelete(self: *EditorView, _: void) void {
        const block = self.core.block_ref.getDataAssumeLoadedConst();
        if (self.current_drag_ptr != null) {
            // delete the source range
            self.core.applyInsert(.{
                .pos = self.current_drag_range.?.start.value,
                .prev_slice = block.prevSliceTemp(self.current_drag_range.?.start.value, self.current_drag_range.?.end.value),
                .next_slice = "",
            });
            self.current_drag_ptr = null;
            self.current_drag_range = null;
        }
    }
};

pub const SynHlColorScope = enum {
    //! sample containing all color scopes. syn hl colors are postfix in brackets
    //! ```ts
    //!     //<punctuation> The main function<comment>
    //!     export<keyword> function<keyword_storage> main<variable_function>(<punctuation>
    //!         argv<variable_parameter>:<punctuation_important> string<keyword_primitive_type>,<punctuation>
    //!     ) {<punctuation>
    //!         const<keyword_storage> res<variable_constant> =<keyword> argv<variable>.<punctuation>map<variable_function>(<punctuation>translate<variable>);<punctuation>
    //!         return<keyword> res<variable>;<punctuation>
    //!     }<punctuation>
    //!
    //!     let<keyword_storage> res<variable_mutable> =<keyword> main<variable_function>(["\<punctuation>\usr<literal_string>\<punctuation>"(MAIN)<literal_string>\<punctuation>x<keyword_storage>00<literal>"]);<punctuation>
    //!     #<invalid>
    //! ```

    // notes:
    // - punctuation_important has the same style as variable_mutable?
    // - 'keyword_storage' is used in string escapes? '\x55' the 'x' is keyword_storage for some reason.

    /// syntax error
    invalid,

    /// more important punctuation. also used for mutable variables? unclear
    punctuation_important,
    /// less important punctuation
    punctuation,

    /// variable defined as a function or called
    variable_function,
    /// variable defined as a paremeter
    variable_parameter,
    /// variable defined (or used?) as a constant
    variable_constant,
    /// variable defined (*maybe: or used?) as mutable
    variable_mutable,
    /// other variable
    variable,

    /// string literal (within the quotes only)
    literal_string,
    /// other types of literals (actual value portion only)
    literal,

    /// storage keywords, ie `var` / `const` / `function`
    keyword_storage,
    /// primitive type keywords, ie `void` / `string` / `i32`
    keyword_primitive_type,
    /// other keywords
    keyword,

    /// comment body text, excluding '//'
    comment,

    /// editor color - your syntax highlighter never needs to output this
    invisible,
};

const DefaultTheme = struct {
    pub const editor_bg: u32 = 0x1F252B;
    pub const selection_color: u32 = 0x2A3239;

    pub fn synHlColor(syn_hl_color: SynHlColorScope) u32 {
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

pub const module_v1 = blocks.interface_module_v1.from(struct {
    pub fn create(alloc: std.mem.Allocator, block_id: blocks.BlockID) ?*EditorView {
        const block_ref = blocks.BlockRef(blocks.block_text_v1).refFromID(block_id);
        const view = alloc.create(EditorView) catch @panic("oom");
        view.init(block_ref, alloc);
        return view;
    }
    pub fn destroy(view: *EditorView) void {
        const valloc = view.core.alloc;
        view.deinit();
        valloc.destroy(view);
    }

    pub fn charInputEvent(view: *EditorView, codepoint: u21) void {
        view.charInputEvent(codepoint);
    }
    pub fn gui(view: *EditorView) void {
        view.gui();
    }

    pub fn init(alloc: std.mem.Allocator) void {
        code_globals.init(alloc);
    }
    pub fn tick() void {
        code_globals.instance().tick();
    }
    pub fn deinit() void {
        code_globals.deinit();
    }
});

// collapsing old ranges:
// - if a document is edited for a long time in a single session,
//   spans will grow forever. to resolve this, we could
//   compact spans:
//   - take a range of spans
//   - delete them all & replace them with a single compacted span
// - now, make all future references based on the new span
// - if something references an old span, we need to go look
//   somewhere and ask how to uncompact the compacted span
//   to know where the reference is pointing
