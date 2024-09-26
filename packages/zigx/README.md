adds syntax sugar for limited stack-capturing macros with shadowing arg names

```
const result = MyFn(12, |arg| arg.value + 25)
```

transforms to:

```
const result = _0: {
    const arg = MyFn.begin(12);
    break :_0 arg.end(arg.value + 25);
};
```

for usage with a struct like

```
const MyFn = struct {
    value: i32,
    pub fn begin(value: i32) MyFn {
        return .{.value = value};
    }
    pub fn end(self: MyFn, value: i32) i32 {
        _ = self;
        return value;
    }
};
```

todo support:

- notify the fn if cancelled (ie `MyFn(12, |_| return 25)`) so it can do cleanup
- allow shadowing arg names
- compile zls with support for stack capturing macros
- update zig extension with support for zigx file format

does not support (yet?):

- loops (no `.iterate(|item| item + 2)`)
- multi arg (no `.sort(|lhs, rhs| lhs < rhs)`)
- nice definition (`fn use(value: @StackCapturingMacro()) i32 { return value(); }`)