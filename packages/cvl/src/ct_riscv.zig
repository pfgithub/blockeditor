// input: a comptemp program with instructions replaced for risc-v target
// output: risc-v binary

// sample comptemp:
// unlike ast, comptemp needs to be manipulated. eg before emitting risc-v,
// we change every int[min, max] type to b8|b16|b32|b64

// const Comptemp = struct {
//     instrs: []ComptempInstr,
// };

fn passConvertRangedIntToBInt() void {
    // visit all ct:ranged ints
    // change their type to a bin:sized int
}
