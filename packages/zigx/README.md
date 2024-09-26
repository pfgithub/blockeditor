## usage

```
    const run_zigx_fmt = b.addRunArtifact(b.dependency("zigx").artifact("zigx_fmt"));
    run_zigx_fmt.setCwd(b.path("."));
    run_zigx_fmt.addArgs(&.{ "src", "build.zig", "build.zig.zon" });
    const beforeall = &run_zigx_fmt.step;
    const beforeall_genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
    beforeall_genf.* = .{
        .step = beforeall,
        .path = b.path("build.zig").getPath(b),
    };
    const beforeall_lazypath: std.Build.LazyPath = .{ .generated = .{ .file = beforeall_genf } };
    const beforeall_mod = b.createModule(.{ .root_source_file = beforeall_lazypath });
```

then, import beforeall_mod or depend on beforeall step before any steps that depend on source
code containing zigx files

## what

adds syntax sugar for limited stack-capturing macros with shadowing arg names

```
const result = Demo(6, |val| val + 4);
```

transforms to:

```zig
const result = _0: {
    var _0 = (Demo).begin(6);
    while(_0.next()) |val| _0.post(val + 4);
    break :_0 _0.end();
};
```

for usage with a struct like

```
const Demo = struct {
    value: ?i32,
    posted: ?i32,
    fn begin(value: i32) Demo {
        return .{ .value = value, .posted = null };
    }
    fn next(self: *Demo) ?i32 {
        defer self.value = null;
        return self.value;
    }
    fn post(self: *Demo, value: i32) void {
        self.posted = value;
    }
    fn end(self: Demo) i32 {
        std.debug.assert(self.value == null);
        std.debug.assert(self.posted != null);
        return self.posted.?;
    }
};
```

todo support:

- notify the fn if cancelled (ie `MyFn(12, |_| return 25)`) so it can do cleanup
- allow shadowing arg names
- compile zls with support for stack capturing macros
- update zig extension with support for zigx file format

does not support (yet?):

- multi arg (no `.sort(|lhs, rhs| lhs < rhs)`)
- nice definition (`fn use(value: @StackCapturingMacro(i32, i32)) i32 { return value(10); }`)
