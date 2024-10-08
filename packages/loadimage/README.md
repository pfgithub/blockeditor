# loadimage

simple, safe image loading using wuffs

supported image formats:

- tested: png
- untested:
  - bmp, jpeg, nie, qoi, tga, webp
  - netpbm, wbmp (not sure what this is)
  - gif (TODO support for extracting specific frames)

usage:

```
// build.zig
    const loadimage_mod = b.dependency("loadimage", .{ .target = target, .optimize = optimize });
    genfont_tool.root_module.addImport("loadimage", loadimage_mod.module("loadimage"));
```

```
// usage
const loadimage = @import("loadimage");

    const image_file_cont = try std.fs.cwd().readFileAlloc(gpa, "myimage.png", std.math.maxInt(usize));
    defer gpa.free(image_file_cont);

    const image = try loadimage.loadImage(gpa, image_file_cont);
    defer image.deinit(gpa);
```

image contains:

```
struct Image {
    w: usize,
    h: usize,
    rgba: []align(@alignOf(u32)) const u8,
}
```

image data is in RGBA order. use `std.mem.bytesAsSlice(u32, image.rgba)` to read whole pixels at a time.

# TODO

- support extracting all frames from gif, rather than just the first
- export a seperate module "loadimage_zig_only" and an artifact "loadimage_obj" for manually linking the object if wanted
- remove dependency on libc
- don't leak any symbols into parent compilation

# building

```
zig build test
```