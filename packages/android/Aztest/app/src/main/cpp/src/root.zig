const App = @import("app");

export fn zig_get_string() [*:0]const u8 {
    _ = App;
    return "hello from zig";
}
