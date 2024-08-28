//! text editing core that is mostly agnostic to the visual editor

const std = @import("std");
const db_mod = @import("../blockdb.zig");
const bi = @import("../blockinterface2.zig");
const util = @import("../util.zig");

pub const Position = bi.text_component.Position;
pub const Selection = struct {
    anchor: Position,
    focus: Position,

    pub fn left(self: Selection) usize {
        return @min(self.anchor.value, self.focus.value);
    }
    pub fn right(self: Selection) usize {
        return @max(self.anchor.value, self.focus.value);
    }
};
pub const CursorPosition = struct {
    pos: Selection,

    /// for pressing the up/down arrow going from [aaaa|a] ↓ to [a|] to [aaaa|a]. resets on move.
    vertical_move_start: ?Position = null,
    /// when selecting up with tree-sitter to allow selecting back down. resets on move.
    node_select_start: ?Selection = null,
};

pub const DragInfo = struct {
    start_pos: ?Position = null,
    selection_mode: DragSelectionMode = .ignore_drag,
};
pub const DragSelectionMode = enum {
    none,
    word,
    line,

    ignore_drag,
};

// we would like EditorCore to edit any TextDocument component
// in order to apply operations to the document, we need to be able to wrap an operation
// with whatever is needed to target the right document
pub const EditorCore = struct {
    gpa: std.mem.Allocator,
    document: db_mod.TypedComponentRef(bi.text_component.TextDocument),

    cursor_position: CursorPosition = .{
        .pos = .{ .anchor = Position.end, .focus = Position.end },
    },
    drag_info: DragInfo = .{},

    /// refs document
    pub fn initFromDoc(self: *EditorCore, gpa: std.mem.Allocator, document: db_mod.TypedComponentRef(bi.text_component.TextDocument)) void {
        self.* = .{
            .gpa = gpa,
            .document = document,
        };
        document.ref();
        document.addUpdateListener(util.Callback(bi.text_component.TextDocument.SimpleOperation, void).from(self, cb_onEdit)); // to keep the language server up to date
    }
    pub fn deinit(self: *EditorCore) void {
        self.document.removeUpdateListener(util.Callback(bi.text_component.TextDocument.SimpleOperation, void).from(self, cb_onEdit));
        self.document.unref();
    }

    fn cb_onEdit(self: *EditorCore, edit: bi.text_component.TextDocument.SimpleOperation) void {
        // TODO: keep tree-sitter updated
        _ = self;
        _ = edit;
    }
};

test EditorCore {
    const gpa = std.testing.allocator;
    var my_db = db_mod.BlockDB.init(gpa);
    defer my_db.deinit();
    const src_block = my_db.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
    defer src_block.unref();

    // now we need to get a TypedComponentRef from src_block
    const src_component: db_mod.TypedComponentRef(bi.text_component.TextDocument) = .{
        .block_ref = src_block,
    };

    // now initialize the editor
    var editor: EditorCore = undefined;
    editor.initFromDoc(gpa, src_component);
    defer editor.deinit();
}
