export type PresentUserID = string;
export type u128 = bigint;
export type Encrypted = Uint8Array;
export type Action = {
    kind: "create_and_watch_block",
    block: u128,
    data: Encrypted,
} | {
    kind: "update_presence",
    block: u128,
    data: Encrypted,
} | {
    kind: "update_block",
    block: u128,
    operation: Encrypted,
} | {
    kind: "checkpoint_block",
    block: u128,
    operation_seq: number,
    data: Encrypted,
} | {
    kind: "tag_block",
    block: u128,
    mode: "add" | "remove"
    tag: "recently_deleted",
} | {
    kind: "unwatch_block",
    block: u128,
} | {
    kind: "fetch_and_watch_block",
    block: u128,
};
export type Commit = Action[]; // a commit of actions succeeds or fails as a single unit

export type StatusUpdate = {
    kind: "block_updated",
    user: PresentUserID,
    block: u128,
    operation: Encrypted,
} | {
    kind: "presence_updated",
    user: PresentUserID,
    block: u128,
    data: Encrypted,
} | {
    kind: "fetch_block_data",
    block: u128,
    checkpoint: Encrypted,
    operations: Encrypted[],
};

/*
the tigerbeetle method is 'tagged enum arrays'
so you would have []created_blocks then []updated_blocks then []deleted_blocks
rather than [](created|updated|deleted)

question: should the server know about block relations?
whether it knows directly or not, it has some capacity to intuit them
but if it knows directly we can have easy methods for listing a tree, ...
for now let's say no because it complicates things
we'll have clients maintain backlinks by sending a commit updating both the linked block and the linking block

if no, we at least should store them somewhere we can read without reading the whole block. would be a waste
to need to read the whole contents of the file tree just to show it

maybe they can go in a seperate block? like $uuid_refs? or even a single block for the whole tree? something like that
*/
