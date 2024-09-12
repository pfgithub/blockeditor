#![no_std]
// use core::fmt;
// use core::fmt::Write;
// use core::panic::PanicInfo;
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
impl AndStr {
    fn val(self: &AndStr) -> &str {
        unsafe {
            let chunk_str = core::slice::from_raw_parts(self.ptr, self.len);
            core::str::from_utf8_unchecked(chunk_str)
        }
    }
}

fn cr_ok<A: core::marker::Copy, B: core::marker::Copy>(val: A) -> CResult<A, B> {
    CResult {
        tag: Result_union_tag::ok,
        value: Result_union { ok: val },
    }
}
fn cr_err<A: core::marker::Copy, B: core::marker::Copy>(val: B) -> CResult<A, B> {
    CResult {
        tag: Result_union_tag::err,
        value: Result_union { err: val },
    }
}
impl From<unicode_segmentation::GraphemeIncomplete> for GraphemeIncomplete {
    fn from(itm: unicode_segmentation::GraphemeIncomplete) -> GraphemeIncomplete {
        GraphemeIncomplete {
            tag: match itm {
                unicode_segmentation::GraphemeIncomplete::PreContext(_) => {
                    GraphemeIncomplete_tag::pre_context
                }
                unicode_segmentation::GraphemeIncomplete::PrevChunk => {
                    GraphemeIncomplete_tag::prev_chunk
                }
                unicode_segmentation::GraphemeIncomplete::NextChunk => {
                    GraphemeIncomplete_tag::next_chunk
                }
                unicode_segmentation::GraphemeIncomplete::InvalidOffset => {
                    GraphemeIncomplete_tag::invalid_offset
                }
            },
            pre_context_offset: match itm {
                unicode_segmentation::GraphemeIncomplete::PreContext(v) => v,
                _ => 0,
            },
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone)]
#[allow(non_camel_case_types)]
pub struct CResult<Ok: core::marker::Copy, Err: core::marker::Copy> {
    tag: Result_union_tag,
    value: Result_union<Ok, Err>,
}
#[repr(u8)]
#[derive(Copy, Clone)]
#[allow(non_camel_case_types)]
pub enum Result_union_tag {
    ok,
    err,
}
#[repr(C)]
#[derive(Copy, Clone)]
#[allow(non_camel_case_types)]
pub union Result_union<Ok: core::marker::Copy, Err: core::marker::Copy> {
    ok: Ok,
    err: Err,
}
#[repr(C)]
#[derive(Copy, Clone)]
#[allow(non_camel_case_types)]
pub struct GraphemeIncomplete {
    tag: GraphemeIncomplete_tag,
    pre_context_offset: usize,
}
#[repr(u8)]
#[derive(Copy, Clone)]
#[allow(non_camel_case_types)]
pub enum GraphemeIncomplete_tag {
    pre_context,
    prev_chunk,
    next_chunk,
    invalid_offset,
}

// extern "C" {
//     fn zig_panic(ptr: *const u8, len: usize) -> !;
// }

// struct BufWriter<'a> {
//     // with no_std rust doesn't even have a FixedBufferStream :/
//     buf: &'a mut [u8],
//     pos: usize,
// }
// impl<'a> fmt::Write for BufWriter<'a> {
//     fn write_str(&mut self, s: &str) -> fmt::Result {
//         let bytes = s.as_bytes();
//         let len = bytes.len();

//         if self.pos + len > self.buf.len() {
//             return Err(core::fmt::Error);
//         }

//         self.buf[self.pos..self.pos + len].copy_from_slice(bytes);
//         self.pos += len;
//         Ok(())
//     }
// }

// #[panic_handler]
// fn panic(info: &PanicInfo) -> ! {
//     let mut buf = [0u8; 65536];
//     let mut writer = BufWriter {
//         buf: &mut buf,
//         pos: 0,
//     };
//     write!(writer, "{}", info).unwrap();

//     unsafe { zig_panic(writer.buf.as_ptr(), writer.pos) }
// }

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
    this.provide_context(chunk.val(), chunk_start);
}

// extern fn unicode_segmentation__GraphemeCursor__is_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) Result(bool, GraphemeIncomplete);
#[export_name = "unicode_segmentation__GraphemeCursor__is_boundary"]
pub extern "C" fn is_boundary(
    this: &mut GraphemeCursor,
    chunk: AndStr,
    chunk_start: usize,
) -> CResult<bool, GraphemeIncomplete> {
    match this.is_boundary(chunk.val(), chunk_start) {
        Ok(result) => cr_ok(result),
        Err(eval) => cr_err(eval.into()),
    }
}

// extern fn unicode_segmentation__GraphemeCursor__next_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) Result(Result(usize, void), GraphemeIncomplete);
#[export_name = "unicode_segmentation__GraphemeCursor__next_boundary"]
pub extern "C" fn next_boundary(
    this: &mut GraphemeCursor,
    chunk: AndStr,
    chunk_start: usize,
) -> CResult<CResult<usize, ()>, GraphemeIncomplete> {
    match this.next_boundary(chunk.val(), chunk_start) {
        Ok(Some(result)) => cr_ok(cr_ok(result)),
        Ok(None) => cr_ok(cr_err(())),
        Err(eval) => cr_err(eval.into()),
    }
}

// extern fn unicode_segmentation__GraphemeCursor__prev_boundary(self: *GraphemeCursor, chunk: AndStr, chunk_start: usize) Result(Result(usize, void), GraphemeIncomplete);
#[export_name = "unicode_segmentation__GraphemeCursor__prev_boundary"]
pub extern "C" fn prev_boundary(
    this: &mut GraphemeCursor,
    chunk: AndStr,
    chunk_start: usize,
) -> CResult<CResult<usize, ()>, GraphemeIncomplete> {
    match this.prev_boundary(chunk.val(), chunk_start) {
        Ok(Some(result)) => cr_ok(cr_ok(result)),
        Ok(None) => cr_ok(cr_err(())),
        Err(eval) => cr_err(eval.into()),
    }
}

#[cfg(test)]
mod tests {
    // uh oh! https://github.com/unicode-rs/unicode-segmentation/issues/139

    use unicode_segmentation::{GraphemeCursor, GraphemeIncomplete::*};

    const family_emoji: &str = "A\u{1F468}\u{200D}\u{1F469}\u{1F467}B";
    // "A👨‍👩‍👧‍👧B" : [A] [MAN] [ZWJ] [WOMAN] [GIRL] [B]

    #[test]
    fn passes() {
        let mut cursor = GraphemeCursor::new(8, family_emoji.len(), true);
        assert_eq!(
            cursor.is_boundary(&family_emoji[8..], 8),
            Err(PreContext(8))
        );
        cursor.provide_context(&family_emoji[1..8], 1);
        assert_eq!(cursor.is_boundary(&family_emoji[8..], 8), Ok(false));
    }

    #[test]
    fn fails() {
        let mut cursor = GraphemeCursor::new(8, family_emoji.len(), true);
        assert_eq!(
            cursor.is_boundary(&family_emoji[8..], 8),
            Err(PreContext(8))
        );
        cursor.provide_context(&family_emoji[5..8], 5);
        assert_eq!(
            cursor.is_boundary(&family_emoji[8..], 8),
            Err(PreContext(5))
        );
        cursor.provide_context(&family_emoji[1..5], 1);
        assert_eq!(cursor.is_boundary(&family_emoji[8..], 8), Ok(false));
    }
}
