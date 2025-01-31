const std = @import("std");
const runtime_safety = switch (@import("builtin").mode) {
    .Debug => true,
    .ReleaseSafe => true,
    else => false,
};
const Range = struct {
    generation: u32,
    min: usize,
    max: usize,
    /// stacktrace to show for out-of-bounds access "note: allocated here"
    allocated_at_stacktrace: Stacktrace,
    /// stacktrace to show for UAF, only if r.range.generation === r.generation + 1
    ///   for "note: freed here" (or "cannot display freed location stacktrace because the range was used multiple ")
    freed_at_stacktrace: Stacktrace,
    first_child: ?*Range,
    next: ?*Range,
};
var range_pool: struct {} = .{};
fn allocRange() *Range {
    // freelist range:
    // new range:
    // generation = 0
    // freed_at_stacktrace = 0
}
fn reuseRange(_: *Range) void {}
const PtrRange = struct {
    range: *Range,
    generation: Stacktrace,
    pub fn validate(range: PtrRange, min: usize, max: usize) void {
        std.debug.assert(range.range.generation == range.generation);
        std.debug.assert(max >= min);
        std.debug.assert(min >= range.range.min and max < range.range.max);
    }
    /// creates a new range owned by the parent range
    pub fn allow(parent: ?PtrRange, min: usize, max: usize) PtrRange {
        if (parent) |p| p.validate(min, max);
        const range = allocRange();
        range.* = .{
            .generation = range.generation,
            .min = min,
            .max = max,
            .allocated_at_stacktrace = getStacktrace(),
            .freed_at_stacktrace = range.freed_at_stacktrace,
            .first_child = null,
            .prev = null,
            .next = null,
        };
        if (parent) |p| {
            if (p.range.first_child) |fc| {
                range.next = fc;
                p.range.first_child = range;
            } else {
                p.range.first_child = range;
            }
        }
    }
    /// blocks the range & any subranges belonging to it as dead
    pub fn block(range: PtrRange) void {
        std.debug.assert(range.range.generation == range.generation); // not already freed
        range.range.generation += 1;
        range.range.freed_at_stacktrace = getStacktrace();
        var ch = range.range.first_child;
        while (ch != null) {
            const child = ch.?;
            ch = child.next;
            child.block();
        }
        reuseRange(range);
    }
};
pub fn SafePtr(comptime Child: type) type {
    return struct {
        ptr: [*]Child,
        range: if (runtime_safety) PtrRange else void,
    };
}

const Stacktrace = enum(u128) { _ };
fn getStacktrace() Stacktrace {
    return @enumFromInt(0); // get current time since program start
}
fn printStacktrace(trace: Stacktrace) void {
    // replay the program, stop at the point referenced by trace, print the stacktrace there
    _ = trace;
}

fn demo() void {
    // page allocator -> gpa -> arena
    // destroying the page kills the arena ptrs & gpa ptrs
}

// question:
// - is there a way to implement this in the host rather than the guest
// answer:
// - only if we do riscv64. because then pointers would be:
//   [u32 range_id] [u32 generation] [u64 ptr_value]
// - and we would add an extension providing 'range_allow', 'ranage_block'
//   - although all 'allow' must have a parent
// - with riscv32 it would be more difficult
// answer 2:
// - yes!
// - along with int_regs: [32]i32, add int_reg_ptr_ranges: [32]PtrFlag
// - const PtrFlag = struct { range: u32, generation: u32 };
// - when loading from memory, validate the pointer flag
// - when performing an operation, store the pointer flag from one of
//   the operands
// - 'add <25>1 + 1 => <25>2'
// - 'add 1 + <25>1 => <25>2'
// - 'add <25>1 + <25>1 => <25>2'
// - 'add <25>1 + <36>1 => 2'
// - when storing a pointerflagged value in memory, indicate it so next
//   load of the same value
// - errors:
//   - store/load out of range
//   - store/load from non-pointer
// - globals:
//   - needs compiler cooperation. without cooperation, globals are exempt
//     from range checking.
//   - with cooperation, we can make sure you can't do `(&global + 1).*`
//   - cooperation = mark in the elf that globals are ptrflagged. whenever
//     getting a pointer to a global, use <set_flag>
// - stack:
//   - needs cooperation from the program
// - sub-allocators:
//   - needs cooperation from the program
// - ptrFromInt:
//   - fine as long as the int originally came from a pointer & hasn't lost its tag
//     - will break with the linked list xor trick because:
//     - <25>ptr1 ^ <36>ptr2 => ptr1^ptr2 (loses tag because the tags are different)
// - executable memory
//   - we can set access_min and access_max based on the range of the executable
//     memory being jumped to & crash when out of range

// question:
// - undefined safety in rvemu
// answer:
// - another flag

// imagine the traces we could have
// might get messy when it is very long
//
// x := i32: 25;
// y := i32: undefined;
// if(x == y) {}
//   ^ branch on 'undefined'
// y := i32: undefined;
//               ^
//      note: 'undefined' started here
// if(x == y) {}
//       ^
//      note: result was undefined because one operand was undefined
//
// called from ...
//

// question:
// - does it have false negatives:
// answser:
// - yes: if the ptr+metadata is random or attacker-controlled, it can refer
//   to any valid range the program has access to
// - combined with undefined protection & untagged enum protection &
//   add overflow protection, it should be difficult to get into that state.
//   a bad ptrcast could trigger it though.
