!important!

- [ ] the appliation freezes the whole computer on mac if you leave it open
       for like 10sec. this was introduced in the commit that also introduced:
  - updating an image every frame 
  - the two uniforms
  - what happens:
    - if "update tex" checkbox is enabled:
      - after some time, the zgui will disappear on the app and the entire system will freeze
      - after holding cmd option shift esc for a while, the system will come back alive
        and the application will be toggling every other frame between solid pink and showing
        the last rendered frame. it's not updating anymore.
      - the application can be ctrl+c'd normally from the terminal at this point
    - if "update tex" is not enabled:
      - this doesn't seem to happen
    - if run through lldb:
      - this doesn't seem to happen
    - if run in ReleaseSafe with -Dtracy:
      - doesn't seem to happen

TODO

- [ ] Get instruments.app, figure out why cpu is so high for blockeditor. Even in ReleaseSafe? Some kind of gpu problem?
  - doesn't show high cpu usage on instruments?
- [x] Try renderdoc https://renderdoc.org/ (linux or windows)
- [x] Use rr next time there's a bug
- [ ] Try android gpu inspector https://developer.android.com/agi/start
- [x] Try undo.io on x86_64 linux to see if it works with the gpu
  - Didn't seem to work very well
- [ ] Try [jj](https://github.com/martinvonz/jj)

Tasks:

- [ ] implement server & try collaborative
  - [ ] later: presence
- [x] freetype font rendering
- [x] increase scroll speed
- [ ] text editor: ctrl or alt + up / ctrl or alt + down to move lines
  - Document 'move' is not implemented yet so we'll have to copy/paste for now
- [ ] text editor: hard tab emulation (grapheme_cluster boundary treats INDENT_WIDTH spaces as a single character)
  - seek left to find where spaces start. if char before spaces is '\n' then it's an indent and use the logic
  - seek right to see how many spaces are remaining. if it is less than INDENT_WIDTH, treat each space individually
  - return a boundary only if the space index % INDENT_WIDTH == 0
- [x] text editor: ctrl+enter = insert new line at end of current line
- [ ] replace all uses of 'std.log' with 'log' + ban unscoped 'std.log'
- [x] text editor: add back selection
- [x] text editor: impl scroll algorithm described in editor_view.zig
- [x] text editor: cache harfbuzz layout results
- [ ] text editor: use sheen_bidi for bidi & script run splitting (and maybe glyph mirroring, if required?)
- [ ] text editor: to get the cursor position for a click:
  - given the mouse x, prev stop location, and next stop location, use the location nearest to mouse x
  - eg for `.{.stop = .word, .select = false}`: clicking `hell|o` there should put the cursor at `hello|` there
- [x] text editor: show invisibles in selection
- [ ] text editor: show invisibles for any spaces before a newline (ie `abcd efg  ` the last two spaces should show)
- [ ] text editor: position visible invisibles halfway through the original width they would have taken
- [x] text editor: fix kerning problems. `"vert"` has trouble between the v, e, and r
  - "type" has trouble between y and p
- [ ] text editor: copying a single byte of a multi-byte codepoint and pasting it back pastes '?'. it should detect
  that the pasted string is identical to the copied string and paste the original byte.
- [ ] text editor: undo! depends on document implementation of 'replace' undo
- [ ] document: merge multiple operations into one equivalent one
- [ ] document: make id u128 and have it be generated randomly? reserve 64 bits for id of the current client? or
  store all ids the current client has made so we know when we can extend.
- [x] fix bug where scrolling in zgui scrolls the editor
- [ ] text editor: up and down while in a selection do not work as expected. up should go up
  from the left of the selection (cursor or anchor) and down should go down from the right of
  the selection (cursor or anchor)
- [x] update tree sitter
- [x] text editor tree sitter: `"hi{a}"` highlights the brackets. and `"hi{{ }}` shows the
  brackets as invalid. Make `{{` within a string highlight to `<punctuation>{<string>{`.
- [x] Document: expose line_count functionality and two way fns for (line, col) -> Position
  and Position -> (line, col)
  - [x] Use this new functionality for tree sitter rather than calculating from the start of the file
- [ ] application takes a while to close until ConnectionRefused on tcp. windows
  takes a while to send this, and presumably it could take a while over a real
  network. Ideally we could kill this while it's in progress on app close.
- [ ] client.zig close logic does not work. on windows, it freezes while trying
  to close. on linux, it sends a message to the server?
  - we need to find out how to kill the connection and stop the thread
    that is waiting on read()
- [x] text editor: pressing esc closes app. remove this.
- [ ] text editor: pressing esc should remove all but the top multicursor
- [ ] text editor: fix whatever's wrong with the last line. it's rendering twice and cursor
  doesn't show at the last location.
- [x] text editor: ctrl+enter from the end of a line inserts two lines below
- [ ] document: finish replace_and_delete impl, remove replace and remove delete. replace
  and delete will be easier to undo than seperate ops.
- [ ] applySimpleOperation: if you apply operation A and then B, undo should undo B and then A.
  this was missed in multi-operation logic.
- [ ] beui2: only rerender after user input or a timer runs out / another thread triggers a signal. no
  need to be running at 240fps when nothing's even being pressed. instead, we can render at 240fps
  while you move your mouse around over the app.
- [ ] beui_impl_android: support tracy with -Dtracy (& in cmake it needs to be a release build and
  DOptimize=ReleaseSafe) (maybe: automatically launch tracy on the native platform when the build
  is complete?)
- [ ] update tracy. the new version fixes the performance problem in the flamegraph. unfortunately,
  they moved imgui to cmake, with patches. so maybe we can depend on cmake and make and use
  that in the build script to build tracy.
- [ ] text editor: fix the last line is buggy
- [ ] document: limit the length of combined spans to MAX_LEN.
  - when parsing, split any spans longer than MAX_LEN into multiple
  - when inserting, split into chunks of MAX_LEN
  - when extending, chunk into MAX_LEN
- [ ] implement rounding
- [ ] implement CPU-side clipping for draw lists. as long as it contains only axis-aligned rectangles, we
  can clip easily. if it's not axis-aligned rectangles then we might have to do gpu clipping (in the draw
  list Command struct, add an option for clipping and then add extra commands to clip). collision based
  event handlers definitely need to be cpu clipped, not gpu clipped.
- [ ] switch event handling to be callback based. we'll have to figure out how to in the callback make
  sure a pointer hasn't invalidated. and then the callback can tell us if we should render a frame or not.
- [ ] ~~switch to allyourcodebase/tracy & remove the local port except bindings. it has support for building the profiler too & maybe even a more recent version than us with the flamegraph updates & new features.~~ does not track latest main from tracy & tracy has not yet released flamegraphs
- [ ] try using libghostty to add an integrated terminal emulator
- [ ] consider switching to sdl3 https://ziggit.dev/t/sdl3-ported-to-the-zig-build-system-with-example-games/7606 (supports cross-compiling to windows & linux. not mac though :/) (also missing aarch64-linux)
- [x] pdb is not outputted on windows for blockeditor.exe
- [ ] maybe try https://github.com/benburkert/freestanding.zig?tab=readme-ov-file#freestandingdebuginfo for risc-v?
- [ ] make risc-v emulator fully serializable & reproducible
  - all syscalls that mutate memory have to save what they changed
  - this gives us fun stuff: capturing a stack trace in debug is as simple
    as `mytrace = emu.getTime()` and then when it's needed, we can
    say `emu.getStacktraces(trace_1, trace_2, ...)` and it will sort them
    and replay the emu to get the traces.
    - in zig, gpa incurs a high cost saving all those stacktraces
    - in rvemu, saving stacktraces is practically free. but getting them
      back takes some time.
- [ ] switch to using non-collaborative storage & three way diffs
- [ ] can we host zig ourself? host binaries & zipped lib folder. same lib folder for all platforms, one binary per platform. zig binary is 164MB though so that's still maybe a gigabyte of storage to host all the binaries 
- [ ] would like to host downloads ourself but kind of waiting on https://github.com/ziglang/zig/pull/22994 oh wait that's a pr. it's coming. we're going to get it soon!
  - not sure if just that PR is enough. it also needs lockfiles and newest-version conflict resolution doesn't it?
  - nvm. we're actually waiting on https://github.com/ziglang/zig/issues/14288 . the other pr doesn't matter.
- [ ] delete zgui! get rid of it!
- [ ] perf: flip the loops. rather than for(operation) block.applyOperation() instead use block.applyOperations(operations). and this way if we have like 3000 operations to apply, we can sort them by block and apply them to every block individually. saves perf.
  - that's probably not the main reason applyOperation is slow right now though
  - our current issue is *all* in beforeUpdateCallback. we need to
    eliminate beforeUpdateCallback and just do diffing.

wishlist:

- [ ] custom build_runner like zls has that generates a graph of all the steps that are going to run and shows it to you
- [ ] for minimum input latency, wait to begin the frame until (frame end time) - (time it took to
  calculate and render last frame) * (150%). this way we can collect more events before starting
  the frame, but sometimes we'll skip a frame by accident because of this.
- [ ] in text editor, if the newline before the start of this line is selected, render selection in the gutter to make it even more clear.
- [ ] text_editor.Core undo and redo don't have to be seperate stacks. they can be just
  one arraylist where when you read an undo, you move the cursor left, and read a redo
  move the cursor right. and to add a new undo, clear everything right of the cursor.
- [ ] automatically disable tree sitter once document length passes a certian value, and re-enable it when it gets below the value. this will also prevent crashing for files larger than maxInt(u32).
- [ ] introduce editor core test recorder. fix a bug or add a feature, then record a session
  and generate tests from it.
- [x] packages/texteditor should not contain View. Instead, it should be part of beui, and
  beui should depend on texteditor.
- [x] change beui_mod.Beui -> Beui, text_editor.core.EditorCore -> text_editor.Core,
  text_editor.view.EditorView -> text_editor.EditorView
- [ ] create virtual scroll view. create text component. text editor rendering then becomes:
  `while(beui.virtualScroll(&self.scroll)) |line_middle| { beui.renderTextLine( <text>, <cursor positions>, <syn hl fonts and ranges> ) }`.
- [x] move tree sitter into its own package
- [x] move tree sitter advanceAndRead logic into struct TreeCursor
- [ ] text editor tree sitter: add a button to copy dot graph of the current syntax tree to
  clipboard
- [ ] text editor tree sitter: documentation comments should have markdown bodies. for this, we need to use the sub tree sitter support with a commonmark parser. and we want to render contents of doc comments as well as we render regular markdown files.
- [ ] bbt findNodeForQuery only needs to have a compare fn signature be
  `(lhs: Query, rhs: Count) -> std.math.Order`. if it returns `.gt` but the node to the right of it
  returns `.lt` then we know the target node.
- [ ] in editor, pinch to zoom out and see an overview of all the decls. pinch to zoom back in.
- [ ] get input latency to 0 by using wayland https://stackoverflow.com/questions/19102189/noticable-lag-in-a-simple-opengl-program-with-mouse-input-through-glfw
  - wayland makes it possible for your application to consistently send its frames at the same
    rate as the mouse cursor updates. that's not zero delay but that's probably the lowest
    possible amount of delay you could get on a computer program running within a 
  - glfw pr: https://github.com/glfw/glfw/pull/1406 . we can merge that locally along with
    trackpad gestures https://github.com/glfw/glfw/pull/2419 in our copy of glfw.
  - it still won't be perfect - the trick is the wayland compositor keeps capturing cursor events
    until the end of the frame, while our application captures it at the start of the frame.
    and apparently gpus have a special mechanism for rendering a perfect cursor.
- [x] upgrade zig-gamedev to the new multirepo structure, so we don't have to download a huge git repo every time


future blocks:

- [ ] spreadsheet (ideally that can be put on a whiteboard, like numbers)
- [ ] whiteboard
- [ ] desmos-like calculator
- [ ] presentation editor
- [ ] video editor
- [ ] minecraft save file (combined with version) manager
- [ ] chat app
- [ ] rss reader
