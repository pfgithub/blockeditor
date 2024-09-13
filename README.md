# Building

Requires zig `0.14.0-dev.1417+242d268a0` with zls commit `ace6f6da90a4420cd6632363b30762e577e2b922`

## Zig setup:

- install zig & add to path
  - for asahi linux: apply patch to `lib/std/mem.zig`: 
    - `pub const page_size = ... .arch64 => .{ ... .visionos }` add `, .linux`
- `git clone https://github.com/zigtools/zls`
- `zig build -Doptimize=ReleaseSafe`
- add zls to path from `zig-out/bin/zls`

## Build project

```
# test
zig build test
# run blockeditor
zig build run
```

# Debugging

## Linux (recommended)

- install rr debugger
- install [midas for vscode](https://marketplace.visualstudio.com/items?itemName=farrese.midas)
- cd to package
- build package: `zig build`
- record application: `rr record ./zig-out/bin/test`
  - rr may require you to make a system configuration change, or alternatively run with `-n`. `-n` is slow, so make the system configuration change.
- run "rr" debug profile in vscode to replay trace
