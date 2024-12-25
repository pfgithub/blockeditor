// ImageCache is used to draw images:
// - rdl entries reference an Image
// - Images which are used in an rdl this frame are flagged to keep
// - Images not used this frame are flagged as dead, and will be cleaned
//   up next time their texture is full

const std = @import("std");
const Texpack = @import("Texpack.zig");
const B2 = @import("beui_experiment.zig");

var _image_id: usize = 0;

// an image that is actively being rendered on the screen ends existing twice
// in cpu memory - once for the image contents and once in the atlas. wasted space.
pub const Image = struct {
    pub const ID = enum(usize) { _ };
    id: ID,
    size: @Vector(2, u16),
    format: Format,
    contents: []align(@alignOf(u32)) const u8,
    /// set to false once the image is written to an atlas. true means to write it again
    modified: bool,
    pub const Format = enum {
        grayscale,
        rgb,
        rgba,
        fn nchannels(format: Format) usize {
            return switch (format) {
                .grayscale => 1,
                .rgb => 3,
                .rgba => 4,
            };
        }
    };

    /// must fill image.mutate() after creating the image! otherwise it's uninitialized!
    pub fn create(b2: *B2.Beui2, size: @Vector(2, u16), format: Format) *Image {
        const npx = @as(usize, size[0]) * @as(usize, size[1]) * format.nchannels();
        const image = b2.persistent.gpa.create(Image) catch @panic("oom");
        _image_id += 1;
        image.* = .{
            ._image_id = @enumFromInt(_image_id),
            .size = size,
            .format = format,
            .contents = b2.persistent.gpa.alignedAlloc(u8, @alignOf(u32), npx) catch @panic("oom"),
        };
        return image;
    }
    pub fn mutate(self: *Image) []align(@alignOf(u32)) u8 {
        self.modified = true;
        return @constCast(self.contents);
    }
    pub fn destroy(self: *Image, b2: *B2.Beui2) void {
        b2.persistent.gpa.free(self.contents);
        b2.persistent.gpa.destroy(self);
    }
};

// here's how it works:
// - store your image in a state - Image.create(width, height), Image.fill(value), ...
// - add the item to an rdl containing your image
// - at rdl expansion time:
//   - here, we add the images to the cache
//   - if we run out of space in the cache, flag the cache for regeneration next frame

pub const Cache = struct {
    caches: std.EnumArray(Image.Format, OneFormatCache),
};
pub const OneFormatCache = struct {
    texpack: Texpack,
    image_id_to_region_map: std.AutoArrayHashMapUnmanaged(Image.ID, Texpack.Region),
    // ^ can't use *Image as the key because image destroy() doesn't notify the cache

    pub fn init(gpa: std.mem.Allocator, format: Image.Format) OneFormatCache {
        return .{
            .texpack = Texpack.init(gpa, 2048, switch (format) {
                .grayscale => .greyscale,
                .rgb => .rgb,
                .rgba => .rgba,
            }),
        };
    }
};
