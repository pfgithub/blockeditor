TODO

- [ ] Get instruments.app, figure out why cpu is so high for blockeditor. Even in ReleaseSafe? Some kind of gpu problem?
  - doesn't show high cpu usage on instruments?
- [ ] Try renderdoc https://renderdoc.org/ (linux or windows)
- [x] Use rr next time there's a bug

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
- [ ] update tree sitter
- [ ] text editor tree sitter: `"hi{a}"` highlights the brackets. and `"hi{{ }}` shows the
  brackets as invalid. Check if an update fixes this
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
- [ ] text editor: pressing esc closes app. remove this.
- [ ] text editor: pressing esc should remove all but the top multicursor
- [ ] text editor: fix whatever's wrong with the last line. it's rendering twice and cursor
  doesn't show at the last location.

wishlist:

- [ ] move tree sitter into its own package
- [ ] move tree sitter advanceAndRead logic into struct TreeCursor
- [ ] text editor tree sitter: add a button to copy dot graph of the current syntax tree to
  clipboard
- [ ] text editor tree sitter: documentation comments should have markdown bodies. for this, we need to use the sub tree sitter support with a commonmark parser. and we want to render contents of doc comments as well as we render regular markdown files.
- [ ] bbt findNodeForQuery only needs to have a compare fn signature be
  `(lhs: Query, rhs: Count) -> std.math.Order`. if it returns `.gt` but the node to the right of it
  returns `.lt` then we know the target node.


future blocks:

- [ ] spreadsheet (ideally that can be put on a whiteboard, like numbers)
- [ ] whiteboard
- [ ] desmos-like calculator
- [ ] presentation editor
- [ ] video editor
- [ ] minecraft save file (combined with version) manager
- [ ] chat app
- [ ] rss reader