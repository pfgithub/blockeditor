// events:
//    /// indicates that there is data or EOF waiting in stdin, and stdin_read
//    /// can be called with the token to retrieve it. a new stdin event will not
//    /// be sent until the read token is used up. if the result of the read is '0',
//    /// that indicates eof and no more read tokens will be sent for the handle.
//    /// or there could be an error waiting (ie the log group was closed that
//    /// contained the update group that had the stdin)
// - stdin : StdinReadToken
// methods:
// - stdin_tryTake(UpdateGroupID, cfg: StdinCfg) ?(StdinHandle, StdinReadToken)
// - stdin_config(StdinHandle, StdinCfg) void
// - stdin_read(StdinHandle, StdinReadToken, [*]u8, usize) usize
// - stdin_close(StdinHandle) void
// - update_group_begin(LogGroupID, Rendered) : UpdateGroupID
// - update_group_update(UpdateGroupID, Rendered)
// - update_group_finish(UpdateGroupFinishMode, UpdateGroupID, Rendered)
// - log(LogGroupID, Rendered)
// - log_group_begin(parent: LogGroupID) : LogGroupID
// - log_group_end(LogGroupID)
// types:
// - StdinHandle = enum(u64) (_);
// - StdinReadToken = enum(u64) (_);
// - StdinCfg = struct (
//     /// if set to 'line', stdin is only updated after 'enter' is pressed. the terminal
//     /// will provide an editable buffer with support for arrow keys and backspace
//     /// and such. if set to 'raw', stdin is updated as soon as new characters are
//     /// available.
//     mode: enum(line, raw),
//     /// mouse events are only available within update groups.
//     enable_mouse_clicks: bool,
//     enable_mouse_scroll: bool,
//     intercept_ctrl_c: bool,
//   );
// - Rendered = struct ();
// - UpdateGroupID = enum(u64) (_);
// - UpdateGroupFinishMode = enum(log, discard);
// - LogGroupID = enum(u64) (_);

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
