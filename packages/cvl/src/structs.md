mixed comptime & runtime in a struct

so for the `asm` instr, its arg is a struct with:

```
%comptime .op: OpCode
%comptime_optional .x10: i32
```

this is odd.

- comptime_optional is saying that if the field is not defined, that is ok

so in order to have this info in the struct type, then
the comptime data has to be stored in the type and the runtime
data in the value

that means we need a substruct type that is able to cast to the struct type
that has the values

so it would be like if you could do this in zig:

```
const MyStruct = struct {
    comptime value: i32,
    arg: i32,
};
const MyStructInitialized: extends<T, MyStruct> = .{.value = 25, .arg = 36};
@TypeOf(MyStructInitialized): struct<from MyStruct>{comptime value: i32 = 25, arg: i32}
@valueOf(MyStructInitialized): .{.arg = 36}
```
