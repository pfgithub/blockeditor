TODO

- [ ] Get instruments.app, figure out why cpu is so high for blockeditor. Even in ReleaseSafe? Some kind of gpu problem?
  - doesn't show high cpu usage on instruments?
- [ ] Try renderdoc https://renderdoc.org/ (linux or windows)
- [x] Use rr next time there's a bug

Tasks:

- [ ] implement server & try collaborative
  - [ ] later: presence
- [ ] freetype font rendering
  - [ ] later: harfbuzz layout
- [x] increase scroll speed
- [ ] text editor: ctrl or alt + up / ctrl or alt + down to move lines
  - Document 'move' is not implemented yet so we'll have to copy/paste for now
- [ ] text editor: hard tab emulation (grapheme_cluster boundary treats INDENT_WIDTH spaces as a single character)
  - seek left to find where spaces start. if char before spaces is '\n' then it's an indent and use the logic
  - seek right to see how many spaces are remaining. if it is less than INDENT_WIDTH, treat each space individually
  - return a boundary only if the space index % INDENT_WIDTH == 0

future blocks:

- [ ] spreadsheet (ideally that can be put on a whiteboard, like numbers)
- [ ] whiteboard
- [ ] desmos-like calculator
- [ ] presentation editor
- [ ] video editor
- [ ] minecraft save file (combined with version) manager
- [ ] chat app
- [ ] rss reader