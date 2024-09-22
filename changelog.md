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