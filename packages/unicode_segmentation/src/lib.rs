use std::{alloc::Layout};
use std::mem;
use unicode_segmentation::GraphemeCursor;

#[repr(C)]
pub struct AndStr {
    ptr: *mut u8,
    len: usize,
}

// the library supports no_std so if we provide our own allocation functions in zig we can skip using std at all
// we don't have to provide allocation functions in zig, we just have to pass in the *mut GraphemeCursor to init

// consider https://github.com/mozilla/cbindgen

// extern fn unicode_segmentation__GraphemeCursor__new(offset: usize, len: usize, is_extended: bool) *GraphemeCursor;
#[export_name = "unicode_segmentation__GraphemeCursor__new"]
pub extern "C" fn new(offset: usize, len: usize, is_extended: bool) -> *mut GraphemeCursor {
    unsafe {
        let layout = Layout::from_size_align(
            mem::size_of::<GraphemeCursor>(),
            mem::align_of::<GraphemeCursor>(),
        ).expect("Bad layout");
        let result_ptr = std::alloc::alloc(layout) as *mut GraphemeCursor;

        result_ptr.write(GraphemeCursor::new(offset, len, is_extended));

        result_ptr
    }
}

// extern fn unicode_segmentation__GraphemeCursor__drop(self: *GraphemeCursor) void;
#[export_name = "unicode_segmentation__GraphemeCursor__drop"]
pub extern "C" fn drop(this: *mut GraphemeCursor) -> () {
    unsafe {
        std::ptr::drop_in_place(this);

        let layout = Layout::from_size_align(
            mem::size_of::<GraphemeCursor>(),
            mem::align_of::<GraphemeCursor>(),
        ).expect("Bad layout");

        std::alloc::dealloc(this as *mut u8, layout);
    }
}

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
pub extern "C" fn provide_context(this: &mut GraphemeCursor, chunk: AndStr, chunk_start: usize) -> () {
    unsafe {
        let chunk_str = std::slice::from_raw_parts(chunk.ptr, chunk.len);
        let chunk_str_utf8 = match std::str::from_utf8(chunk_str) {
            Ok(str) => str,
            Err(_) => {
                // uh oh :/
                // on the zig side, we're fine with invalid utf-8
                // maybe before psasing to provide_context, we can replace invalid utf-8 bytes with '?'
                panic!("err(emsg)");
            },
        };
        this.provide_context(chunk_str_utf8, chunk_start);
    }
}

// extern fn unicode_segmentation__GraphemeCursor__is_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) IsBoundaryResult;
// extern fn unicode_segmentation__GraphemeCursor__next_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) NextPrevBoundaryResult;
// extern fn unicode_segmentation__GraphemeCursor__prev_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) NextPrevBoundaryResult;


