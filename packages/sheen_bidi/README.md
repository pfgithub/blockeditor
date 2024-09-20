# SheenBidi packaged for the zig build system

install:

```
zig fetch --save=sheen_bidi <TODO>
```

build.zig:

```
const sheen_bidi = b.dependency("sheen_bidi", .{.target = target, .optimize = optimize});

// to use with @import("sheen_bidi")
exe.root_module.addImport("sheen_bidi", sheen_bidi.module("sheen_bidi"));

// to use with c or something
exe.root_module.linkLibrary(sheen_bidi.artifact("sheen_bidi_lib"));
```

usage:

see example in `src/test.zig`