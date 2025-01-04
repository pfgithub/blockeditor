pub const hash = 0; // this is the hash of the block. it may not be referenced from any other decl here.
pub const upgrades = struct {};

const TextureViewerBlock = struct {
    viewing_texture_id: u16,

    pub const Operation = struct {
        set_viewing_texture_id: u16,
    };
};

// the id of a block is equal to the hash of its compiled module
// - this is odd. what if the compiler updates and generates new code? it shouldn't be required
//   to perform a block update if the only thing that changed is the compiler updated
//   - if you write a text document using TextBlock@1, then the compiler updates
//     now the text block hash is TextBlock@2 and your old files are incompatible. but
//     that's obviously not true. so you have to define an upgrade from TextBlock@1 to
//     TextBlock@2. and it's a no-op upgrade, the only thing that changed is like a few
//     cpu instructions but ideally all the behaviour is identical.

// maybe that's okay though?
// - whenever you update zig and try to compile, it will have errors: block hashes changed
//   - when this happens, you have to add a no-op upgrade from <previous hash> to <next hash>

// actually
// - updating a block won't be a problem. blocks are little wasm or riscv blobs, so if a client is outdated
//   it can download the new version
//   * that only applies if only merging logic changed. if the block layout changed, it is a problem, the
//      client still needs to update. so that is one problem with this method, forcing client updates. if any
//      one user updates. but that's probably fine.
