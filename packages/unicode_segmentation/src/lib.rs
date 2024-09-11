#![no_std]
use core::fmt;
use core::fmt::Write;
use core::panic::PanicInfo;
use unicode_segmentation::GraphemeCursor;

#[repr(C)]
pub struct Layout {
    size: usize,
    alignment: usize,
}

#[repr(C)]
pub struct AndStr {
    ptr: *mut u8,
    len: usize,
}

extern "C" {
    fn zig_panic(ptr: *const u8, len: usize) -> !;
}

struct BufWriter<'a> {
    // with no_std rust doesn't even have a FixedBufferStream :/
    buf: &'a mut [u8],
    pos: usize,
}
impl<'a> fmt::Write for BufWriter<'a> {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        let bytes = s.as_bytes();
        let len = bytes.len();

        if self.pos + len > self.buf.len() {
            return Err(core::fmt::Error);
        }

        self.buf[self.pos..self.pos + len].copy_from_slice(bytes);
        self.pos += len;
        Ok(())
    }
}

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut buf = [0u8; 65536];
    let mut writer = BufWriter {
        buf: &mut buf,
        pos: 0,
    };
    write!(writer, "{}", info).unwrap();

    unsafe { zig_panic(writer.buf.as_ptr(), writer.pos) }
}

// consider https://github.com/mozilla/cbindgen

// extern fn unicode_segmentation__GraphemeCursor__layout() RsLayout;
#[export_name = "unicode_segmentation__GraphemeCursor__layout"]
pub extern "C" fn layout() -> Layout {
    Layout {
        size: core::mem::size_of::<GraphemeCursor>(),
        alignment: core::mem::align_of::<GraphemeCursor>(),
    }
}

// extern fn unicode_segmentation__GraphemeCursor__init(self: *GraphemeCursor, offset: usize, len: usize, is_extended: bool) void;
#[export_name = "unicode_segmentation__GraphemeCursor__init"]
pub extern "C" fn init(
    this: *mut GraphemeCursor,
    offset: usize,
    len: usize,
    is_extended: bool,
) -> () {
    unsafe {
        this.write(GraphemeCursor::new(offset, len, is_extended));
    }
}

// disabled because GraphemeCursor doesn't do any stuff on deinit, we can just let it go away in zig
// // extern fn unicode_segmentation__GraphemeCursor__drop(self: *GraphemeCursor) void;
// #[export_name = "unicode_segmentation__GraphemeCursor__drop"]
// pub extern "C" fn drop(this: *mut GraphemeCursor) -> () {
//     unsafe {
//         core::ptr::drop_in_place(this);
//     }
// }

// extern fn unicode_segmentation__GraphemeCursor__set_cursor(self: *GraphemeCursor, offset: usize) void;
#[export_name = "unicode_segmentation__GraphemeCursor__set_cursor"]
pub extern "C" fn set_cursor(this: &mut GraphemeCursor, offset: usize) -> () {
    this.set_cursor(offset);
}

// extern fn unicode_segmentation__GraphemeCursor__cur_cursor(self: *GraphemeCursor) usize;
#[export_name = "unicode_segmentation__GraphemeCursor__cur_cursor"]
pub extern "C" fn cur_cursor(this: &mut GraphemeCursor) -> usize {
    this.cur_cursor()
}

// extern fn unicode_segmentation__GraphemeCursor__provide_context(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) void;
#[export_name = "unicode_segmentation__GraphemeCursor__provide_context"]
pub extern "C" fn provide_context(
    this: &mut GraphemeCursor,
    chunk: AndStr,
    chunk_start: usize,
) -> () {
    unsafe {
        let chunk_str = core::slice::from_raw_parts(chunk.ptr, chunk.len);
        let chunk_str_utf8 = match core::str::from_utf8(chunk_str) {
            Ok(str) => str,
            Err(_) => {
                // uh oh :/
                // on the zig side, we're fine with invalid utf-8
                // maybe before psasing to provide_context, we can replace invalid utf-8 bytes with '?'
                panic!("err(emsg)");
            }
        };
        this.provide_context(chunk_str_utf8, chunk_start);
    }
}

// extern fn unicode_segmentation__GraphemeCursor__is_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) IsBoundaryResult;
// extern fn unicode_segmentation__GraphemeCursor__next_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) NextPrevBoundaryResult;
// extern fn unicode_segmentation__GraphemeCursor__prev_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) NextPrevBoundaryResult;
