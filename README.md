For zig `0.14.0-dev.1417+242d268a0` with zls commit `ace6f6da90a4420cd6632363b30762e577e2b922`

- install zig & add to path
  - for asahi linux: apply patch to `lib/std/mem.zig`: 
    - `pub const page_size = ... .arch64 => .{ ... .visionos }` add `, .linux`
- `git clone https://github.com/zigtools/zls`
- `zig build -Doptimize=ReleaseSafe`
- add zls to path from `zig-out/bin/zls`