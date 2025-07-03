/*
sample target: mcfunction

sample code:

mc := std.targets.mc;

hello_world := (entity: mc.Entity) kw.void: {
    // it returns mc.Status so you have to discard it
    _ = entity.tellraw([("text" = "hello")])
}
// mc.Status is `kw.union(kw.i32, .fail)`
status_native_number := () kw.i32: 5
status_number := () mc.Status: 5
status_fail := () mc.Status: .fail
status_native_fail := () mc.Status.fail: .fail

std.build = mc.Datapack (
    "example" = (
        .functions = (
            "hello_world" = hello_world
        )
    )
),

// for '{}' instead of implicit return, we can do '->'
// '{a; -> b}'
// that way we can still have implicit semicolons/commas
// (mandatory to not have a semicolon/comma at the end of a line)

// at emit time we'll enforce the restrictions
// (ie fn args may only have one Entity, one Position, and one Nbt<Record<string, number | object | list>>)
//  (string nbt is for true macros which we have to be careful of)

// Entity implicitly casts to EntityList, but not EntityList to Entity
*/
type Slot = {
    src: Node | Fn,
    dst: Node | Fn,
};
type Fn = {
    args: Slot[],
    ret: Slot[],
};
type Node = {
    referenced_by: Slot[],
    references: Slot[],
    data: {
        kind: "number",
        value: number,
    } | {
        kind: "call",
        target: Fn,
        args: Slot[],
    },
};

const example = `
i, world =>
world = print(i)
=> world
`;
