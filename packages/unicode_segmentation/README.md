Locally testing rust changes:

Requires rustup installed and in path, as well as cargo which maybe comes from rustup?

```
bun rust_build.ts # TODO: this builds for every target, but there should be a way to build for just one
zig build test -Dlocal
```