const std = @import("std");

const Circuit = struct {
    sorted_components: std.MultiArrayList(Component),
};
const Component = struct {
    const Op = enum {
        input, // result is set by the caller. execute does not modify result.
        wire, // result = src[0]
        nand, // ~(src[0] & src[1])
        fn argsLen(op: Op) usize {
            return switch (op) {
                .input => 0,
                .wire => 1,
                .nand => 2,
            };
        }
    };
    op: Op,
    src_start: usize,
    result: u64,
};

// sample: switch, switch => nand => lamp
// 0: switch_off(0):0
// 1: switch_off(0):0
// 2: nand(0):2
// output: [2..][0..1]

fn execute(circuit: *Circuit) void {
    const results = circuit.sorted_components.slice(.result);
    for (
        circuit.sorted_components.slice(.op),
        circuit.sorted_components.slice(.src_start),
        results,
    ) |op, src_start, *result| switch (op) {
        .input => {
            // component.result is not mutated
        },
        .wire => {
            result.* = results[src_start];
        },
        .nand => {
            result.* = ~(results[src_start] & results[src_start + 1]);
        },
    };
}
