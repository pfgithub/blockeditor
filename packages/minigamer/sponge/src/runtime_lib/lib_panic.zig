const std = @import("std");
const lib = @import("lib.zig");

// UPDATE 2024-08-03: zig has updated its std.debug to allow reading
// from anything as long as it's the same target. so since this is on the risc-v side
// we can read, but we can't do it on the emulator side.
// TODO: impl once mach-gamedev updates zig (if it tracks mach that will be in a while)

// https://ziggit.dev/t/logging-a-stack-trace-on-bare-metal/4132

// Unfortunately! std.DebugInfo calls out to `os.dl_iterate_phdr`
// which calls std.process.getBaseAddress
// which calls os.system.getauxval
// ...
// anyway basically we need to reach deeper into the stdlib
// can't use 'printSourceAtAddress' because it relies on DebugInfo which relies on an OS and
//   we can't redefine it
// it looks like things were better at the time of andrewrk's blog post :/

var panic_stage = 0;
pub fn panic(message: []const u8, stack_trace_opt: ?*std.builtin.StackTrace, pc_at_panic: ?usize) noreturn {
    panic_stage += 1;
    if (panic_stage == 2) {
        std.log.err("Panicked during a panic: {s}", .{message});
        @trap();
    } else if (panic_stage > 2) {
        @trap();
    }

    std.log.err("PANIC: {s}", .{message});

    const writer = lib.StderrWriter{ .context = {} };

    // Make sure to release the mutex when done
    if (stack_trace_opt) |t| {
        // // and now it has to lookupModuleDl
        // const debug_info = try SelfInfo.open(getDebugInfoAllocator());
        // writeStackTrace(stack_trace, writer, getDebugInfoAllocator(), debug_info, .no_color) catch |err| {
        //     stderr.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
        //     return;
        // };
        // dumpStackTrace(t.*);
        _ = t;
    }
    // dumpCurrentStackTrace(pc_at_panic);
    _ = writer;
    _ = pc_at_panic;
}

// https://andrewkelley.me/post/zig-stack-traces-kernel-panic-bare-bones-os.html

// we would like our program to have nice panics
// std.debug.readElfDebugInfo exists, but
// - it mmaps the file
// and we can't mmap a file, we'd like to pass in the file as a slice
//
// assuming the stuff from that blog post is still around, this is definitely a way to do it
// so the question is: should the risc v side have to read the elf and find the symbols,
// or should the loader do that and pass them to the risc v side
//
// also, it's nice to mmap the file but we don't support that in our emulator. so we'll
// have to copy in the whole file to memory

// THIS WORKS
// but zig has a fn 'readElfDebugInfo'
// so we might as well use it for panic()
// dang, that calls

//     // we want:
//     // - debug_info
//     // - debug_abbrev
//     // - debug_str
//     // - debug_line
//     // - debug_ranges
//     std.debug.openSelfDebugInfo(allocator: mem.Allocator)

//     // find sections (for debug info)
//     {
//         var i: usize = 0;
//         var sh_addr = file[eh.e_shoff..];
//         while (i < eh.e_shnum) : ({
//             i += 1;
//             sh_addr = sh_addr[eh.e_shentsize..];
//         }) {
//             const sh: *const std.elf.Elf32_Shdr = try util.safePtrCast(std.elf.Elf32_Shdr, sh_addr[0..@sizeOf(std.elf.Elf32_Shdr)]);

//             const name: []const u8 = blk: {
//                 var name = file[header_names_start + sh.sh_name ..];
//                 for (name, 0..) |byte, i_| {
//                     if (byte == 0) {
//                         name.len = i_;
//                         break :blk name;
//                     }
//                 }
//                 break :blk "";
//             };

//             std.log.info("section name: {d},{d} / {s}", .{ header_names_start, sh.sh_name, name });
//         }
//     }
