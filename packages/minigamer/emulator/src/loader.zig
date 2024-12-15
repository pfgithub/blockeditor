const std = @import("std");
const util = @import("util.zig");

const rvemu = @import("rvemu.zig");

// based on std.DynLib (ElfDynLib)
// since we're emitting an exe, we'll need to find the start address
// which is different than what ElfDynLib does
// https://stackoverflow.com/questions/71366471/calculate-the-entry-point-of-an-elf-file-as-a-physical-address-offset-from-0
// oh it's easy. it's 'eh.e_entry'
// so once we load everything in to the memory, jump to eh.e_entry
// for our file, it's 69876

pub fn loadElf(file: []align(@alignOf(u128)) const u8, mem_out: []align(@alignOf(u128)) u8) !struct {
    main_ptr: u32,
    stack_ptr: u32,
} {
    // carful with this thing! there's some untagged enums, they'll crash if you try to use them.
    const eh = @as(*const std.elf.Elf32_Ehdr, @ptrCast(file.ptr));

    if (!std.mem.eql(u8, eh.e_ident[0..4], std.elf.MAGIC)) return error.NotElfFile;
    if (eh.e_machine != .RISCV) return error.BadMachine;
    std.log.info("eh_ident: `{s}`", .{eh.e_ident});
    std.log.info("eh: {any}", .{eh.*});

    // var maybe_phdr: ?*const std.elf.Elf32_Phdr = null;
    var virt_addr_start: u32 = std.math.maxInt(u32);
    var virt_addr_end: u32 = 0;
    {
        var i: u32 = 0;

        var ph_addr = file[eh.e_phoff..];
        while (i < eh.e_phnum) : ({
            i += 1;
            ph_addr = ph_addr[eh.e_phentsize..];
        }) {
            const ph: *const std.elf.Elf32_Phdr = try util.safePtrCast(std.elf.Elf32_Phdr, ph_addr[0..@sizeOf(std.elf.Elf32_Phdr)]);

            switch (ph.p_type) {
                std.elf.PT_LOAD => {
                    virt_addr_start = @min(virt_addr_start, ph.p_vaddr);
                    virt_addr_end = @max(virt_addr_end, ph.p_vaddr + ph.p_memsz);
                },
                else => {},
            }

            switch (ph.p_type) {
                else => {},
            }
            inline for (&.{
                "PT_NULL",
                "PT_LOAD",
                "PT_DYNAMIC",
                "PT_INTERP",
                "PT_NOTE",
                "PT_SHLIB",
                "PT_PHDR",
                "PT_TLS",
                "PT_NUM",
                "PT_LOOS",
                "PT_GNU_STACK",
                "PT_GNU_RELRO",
                "PT_LOSUNW",
                "PT_SUNWBSS",
                "PT_SUNWSTACK",
                "PT_HISUNW",
                "PT_HIOS",
                "PT_LOPROC",
                "PT_HIPROC",
            }) |pt| {
                if (ph.p_type == @field(std.elf, pt)) {
                    std.log.info("pt: {s}", .{pt});
                    break;
                }
            } else {
                std.log.info("pt: {d}", .{ph.p_type});
            }
        }
    }
    if (virt_addr_end > mem_out.len) return error.ElfTooBig;
    std.log.info("virt addr space: {d} / {d}", .{ virt_addr_start, virt_addr_end });
    std.log.info("start addr: {d}", .{eh.e_entry});

    // load the data
    {
        var i: usize = 0;

        var ph_addr = file[eh.e_phoff..];
        while (i < eh.e_phnum) : ({
            i += 1;
            ph_addr = ph_addr[eh.e_phentsize..];
        }) {
            const ph: *const std.elf.Elf32_Phdr = try util.safePtrCast(std.elf.Elf32_Phdr, ph_addr[0..@sizeOf(std.elf.Elf32_Phdr)]);

            switch (ph.p_type) {
                std.elf.PT_LOAD => {
                    const mem_size = ph.p_memsz;
                    const file_size = ph.p_filesz;
                    if (file_size > mem_size) return error.BadLoadSize;
                    // bytes > file_size hold '0'

                    // p_flags holds x|r|w. we're ignoring that for now.

                    const bytes = file[ph.p_offset..][0..file_size];
                    if (ph.p_vaddr + mem_size > mem_out.len) return error.LoadOutOfRange;
                    std.log.info("load bytes: {d}/{d} -> {d}/{d}", .{ ph.p_offset, file_size, ph.p_vaddr, file_size });
                    @memcpy(mem_out[ph.p_vaddr..][0..file_size], bytes);
                    for (file_size..mem_size) |ii| {
                        if (mem_out[ph.p_vaddr + ii] != 0) return error.Neq0;
                    }
                },
                std.elf.PT_DYNAMIC => {
                    return error.DynamicExecutableNotSupported;
                },
                else => {},
            }
        }
    }
    std.log.info("load success!", .{});

    return .{
        .main_ptr = eh.e_entry,
        .stack_ptr = virt_addr_start, // probably not right
    };
}
