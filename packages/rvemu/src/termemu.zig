const Event = extern struct {
    id: u64,
    value: u64,
};
extern fn waitEvent() Event;

const LogGroup = enum(u64) {
    _,

    pub extern fn log(group: LogGroup, rendered: Rendered) void;
    pub extern fn begin(group: LogGroup) LogGroup;
    pub extern fn end(group: LogGroup) void;
    pub extern fn beginUpdate(group: LogGroup) UpdateGroup;
};
const UpdateGroup = enum(u64) {
    none,
    _,

    pub extern fn update(group: UpdateGroup, rendered: Rendered) void;
    pub extern fn end(group: UpdateGroup, rendered: Rendered, mode: enum { clear, log }) void;

    // returns .none if someone else owns the stdin and it cannot be acquired
    pub extern fn tryTakeStdin(group: UpdateGroup, cfg: StdinCfg) StdinHandle;
};
const StdinHandle = enum(u64) {
    none,
    _,

    pub extern fn updateConfig(handle: StdinHandle, cfg: StdinCfg) void;
    pub extern fn read(handle: StdinHandle, token: StdinReadToken, buf: Slice) usize;
    /// after closing, any future operations on this handle are errors. any unread data is sent to the
    /// next reader. (this means the next reader might get a few unwanted mouse events. not ideal.)
    pub extern fn close(handle: StdinHandle) void;
};
const StdinCfg = extern struct {
    mode: enum { line, raw },
    /// mouse events are only available within update groups.
    enable_mouse_clicks: bool,
    enable_mouse_scroll: bool,
    intercept_ctrl_c: bool,
};
const StdinReadToken = enum(u64) {
    _,
};
const Slice = extern struct {
    ptr: [*]u8,
    len: usize,
};
const Rendered = extern struct {
    msg: Slice,
};

// notes
// - if an outer log group is closed, the inner log group is removed. further attempts to use it are an error
//   - system pointers can be (generation, pointer) style in order to error in this case
// missing:
// - how does the program get its LogGroupID to start?
// - what happens as log groups are interleaved?
// - do log groups have names? do they auto log timestamps?
// critical:
// - how do programs write to stdout for processing by other programs
// - how do programs read clean stdin from a pipe
//   - stdin tryTake has to indicate if stdin isatty. if it is, none of the options do anything
// with stdout, we want write(writable_token, slice): len, and if write returned len < slice.len, then
// writable_token is discarded and you have to wait for a new write event.
