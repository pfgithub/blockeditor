// we may want to run blocks in wasm or rvemu

pub const AnyBlock = struct {};
pub const AnyOperation = struct {};
pub const AnyUndoToken = struct {};

pub const BlockInterface = struct {
    applyOperation: fn(self: AnyBlock, operation: AnyOperation) AnyUndoToken,
    undoOperation: fn(self: AnyBlock, undo_token: AnyUndoToken) AnyUndoToken,
    
    // TODO: all blocks have:
    // - parent
    // - references
    // we need to be able to track this
};