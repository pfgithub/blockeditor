# SheenBidi packaged for the zig build system

For use with zig `0.13.0`

## Add to project

```bash
zig fetch --save=sheen_bidi <TODO>
```

build.zig:

```zig
const sheen_bidi = b.dependency("sheen_bidi", .{.target = target, .optimize = optimize});

// to link and use with @import("sheen_bidi")
exe.root_module.addImport("sheen_bidi", sheen_bidi.module("sheen_bidi"));

// to link the library only
exe.root_module.linkLibrary(sheen_bidi.artifact("sheen_bidi"));
```

## Usage

See example in `src/example.zig`