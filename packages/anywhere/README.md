allows calling zgui or tracy fns from anywhere, even if zgui or tracy is not in the compilation

internally it

- redefines all fn protos
- finds tracy/zgui if available from `@import("root")`, and uses them only if available. else all fn calls are stubs.