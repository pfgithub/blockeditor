# Changelog

## 2024-09-21

- Add sheen_bidi package that builds sheen_bidi, exports translate-c
  bindings, and has a test of example usage
- Load truetype font, lay out glyphs with harfbuzz, render glyphs to texture,
  load and update texture in gpu, switch text rendering to truetype+harfbuzz,
  add theme constant for cursor style, render selection and cursor again with
  new text, support cursor positions partway through bytes in rendering
- Remove the rainbow translucency test squares
- Switch from using a magic number to disable texture sampling to using
  any uv coordinate outside of 0.0...1.1
- Add back showing invisibles under text selection

## 2024-09-22

- Fix kerning being wrong
- Create tracy package that builds tracy client and profiler with bindings
- Create anywhere package that allows calling tracy methods from packages
  that don't depend on tracy. They do nothing unless the root module defines
  anywhere_cfg containing tracy.
- Add tracy traces to many functions and to allocator
- Support building editor from root folder with `-Dtracy` which will link tracy
  client lib, compile tracy exe, and spawn both the editor and tracy.
- Cache harfbuzz runs, speed up draw list appends, speed up (~10x) finding
  character syntax highlighting scope
- Create idiomatic zig bindings for the portion of tree sitter we use and update
  to use them everywhere
- Add zgui to anywhere and use this to create an inspector UI to show the
  current tree sitter nodes under the cursor
- Add more search paths for verdana.ttf. We can't really use fontconfig, it's
  a horrible library to build.
- Fix syntax highlighting not supporting `//!` comments and not marking
  the character immediately after the slashes as a comment
- Some progress towards initial server

## 2024-09-22

Milestone: our editor is usable. If it could save and browse files, we could
start using it right now to do editing. It feels pretty nice.

- Disable TcpSync on windows for now: https://github.com/ziglang/zig/issues/21492
- Move files around: editor_view -> beui and some files -> structs
- Implement Position <-> LynCol functions in Document and update editor core functions
  to use them
- Add a toggle button for syntax highlighting to see the perf cost (not as high anymore
  compared to the other things eating miliseconds)
- Fix running with -Dtracy wasn't keeping imgui.ini settings because it was using the wrong
  folder
- Add frame prepare time display
- Change doc comment body to be white
- Change block.applyOperation to accept multiple operations at once
- Start thinking about Beui
- Change tint in vertex struct to take just one u32 instead of 4xf32
- Upgrade tree_sitter and tree-sitter-zig
- Fix "{{" in syntax highlighting
- Fix ctrl+enter at end of line
- Pipe undo operations all the way through in preperation for supporting undo/redo
- Simplify insert applyOperation logic
- Simplify delete applyOperation logic
- Begin work on new combined replace_and_delete operation

## 2024-09-23


