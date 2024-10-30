https://blockeditor.pfg.pw

# Building

Requires zig `0.14.0-dev.2064+b5cafe223`

Recommended to use zls commit `b2e89dfe92850cf02cbd4b73004aaaecd5cf1739`

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
zig build run --prominent-compile-errors
# run with tracy
zig build run -Dtracy -Doptimize=ReleaseSafe --prominent-compile-errors
```

# Debugging

## Linux (recommended)

- install rr debugger
- install [midas for vscode](https://marketplace.visualstudio.com/items?itemName=farrese.midas)
  - [bug workaround](https://github.com/farre/midas/issues/197)
- cd to package
- build package: `zig build`
- record application: `rr record ./zig-out/bin/test`
  - rr may require you to make a system configuration change, or alternatively run with `-n`. `-n` is slow, so make the system configuration change.
- run "rr" debug profile in vscode to replay trace
  - to run gdb commands, open the "debug console": click the problems button at the bottom of
    vscode and switch tabs to debug console, then select rr.
    - an example command is `print &myvar` to get the address of a variable
    - to read memory (vscode's "hex editor" thing doesn't seem to work at all), use `x/LENcb value` eg `x/160cb myslice.ptr`. to read array items, can `print myslice.ptr[index]` 
