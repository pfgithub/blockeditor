// temporary until https://github.com/ziglang/zig/issues/20649 is fixed
pub usingnamespace @cImport({
    @cInclude("wuffs-v0.4.c");
});
