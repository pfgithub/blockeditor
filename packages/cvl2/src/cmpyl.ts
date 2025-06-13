/*
sample target: mcfunction

sample code:

mc := std.targets.mc;

hello_world := (entity: mc.Entity) kw.void: {
    entity.tellraw([("text" = "hello")])
}
status_number := () mc.Status: 5
status_fail := () mc.Status: .fail

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