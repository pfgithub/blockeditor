const Sys = extern struct {
    data: *SysData,
    vtable: *const SysVtable,
};
const SysData = opaque {};
const SysVtable = struct {
    waitEvent: *const fn (sys: *SysData) Event,
    log: ?LogVtable,
};
const LogVtable = struct {
    event_stdin: u64,
    event_stdout: u64,
    event_resize: u64,

    group_log: *const fn (sys: *SysData, group: LogGroup, rendered: Rendered) void,
    group_begin: *const fn (sys: *SysData, group: LogGroup) LogGroup,
    group_end: *const fn (sys: *SysData, group: LogGroup) void,
    group_beginUpdate: *const fn (sys: *SysData, group: LogGroup) UpdateGroup,

    /// .none is returned for non-TTY outputs
    group_registerResizeListener: *const fn (sys: *SysData, group: LogGroup) StdoutResizeListener,
    group_unregisterResizeListener: *const fn (sys: *SysData, listener: StdoutResizeListener) void,

    resizeToken_getSize: *const fn (sys: *SysData, token: StdoutResizeToken) [2]u32,

    updateGroup_update: *const fn (sys: *SysData, group: UpdateGroup, rendered: Rendered) void,
    updateGroup_end: *const fn (sys: *SysData, group: UpdateGroup, rendered: Rendered, mode: enum(u32) { clear, log }) void,

    /// returns .none if someone else owns the stdin and it cannot be acquired
    /// if data is available to read, a 'readable' event will be sent immediately.
    updateGroup_tryTakeStdin: *const fn (sys: *SysData) StdinHandle,

    stdinHandle_updateConfig: *const fn (sys: *SysData, handle: StdinHandle, cfg: StdinCfg) void,
    stdinHandle_read: *const fn (sys: *SysData, handle: StdinHandle, token: StdinReadToken, buf: Slice) usize,
    stdinHandle_close: *const fn (sys: *SysData, handle: StdinHandle) void,

    /// if this returns a length < msg.len, you must wait for a new StdoutEvent before
    /// you can write again.
    group_writeStdout: *const fn (sys: *SysData, group: LogGroup, msg: Slice) usize,
};

const Event = extern struct {
    id: u64,
    value: u64,
};
const StdoutEvent = void;
const StdinEvent = StdinReadToken;
const ResizeEvent = void;

const LogGroup = enum(u64) { _ };
const UpdateGroup = enum(u64) { none, _ };
const StdinHandle = enum(u64) { none, _ };
const StdinCfg = extern struct {
    /// in line mode, echo is true. in raw, echo is false.
    mode: enum { line, raw },
    /// mouse events are only available within update groups.
    enable_mouse_clicks: bool,
    enable_mouse_scroll: bool,
    intercept_ctrl_c: bool,
};
const StdinReadToken = enum(u64) { _ };
const StdoutResizeListener = enum(u64) { none, _ };
const StdoutResizeToken = enum(u64) { _ };
const Slice = extern struct {
    ptr: [*]u8,
    len: usize,
};
const Rendered = extern struct {
    msg: Slice,
    cursor_pos: i32 = -1,
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
