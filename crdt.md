
We can skip CRDT and unapplyOperation like this:

- Two copies of each block are stored
  - One is the latest server-approved version, and one is the latest version
  
Also, a queue of unapproved operations is kept
- When you apply an operation, you add it to this queue and send it to the server

When the server sends you an operation:
- If it's yours, you pop it from the front of your unapproved operations queue and apply
  it to the server-approved copy of the block
- If it's someone else's:
  - You apply it to the server-approved block version
  - You clone the block
  - You apply all unapproved operations to the cloned block, and set this to the latest version

All this requires is:
- Serialize, deserialize (which we need anyway)
- ApplyOperation

Clone is implemented as deserialize(serialize)

We only have to keep a list of operations that the server has not yet sent back to us to confirm

Everyone's server-approved list will be in the same order because the server sends them out in a single order



Compare/contrast:

- If the block is big, cloning it will be expensive. This can be mitigated by introducing actual cloning and making it as copy-on-write as possible. If blocks were actually stored as []u8, there is likely a kernel function to do it trivially, otherwise it will take a bit of effort with ref-counting
- If applying operations is expensive, that is bad because the further behind you are the more operations you will need to apply when a new one comes in from the server


CRDT makes things complicated, replay is simple

- With replay, there's no mathematical properties you have to adhere to, you just have to make sure your applyOperation preserves user intent
- With CRDT, you need to preserve user intent and adhere to a mathematical property

```zig
// set/reset counter using replay:

const operation = union(enum) {
    set: i32,
    add: i32,
}
value: i32
fn applyOperation(self, operation) {
    switch(operation) {
        .set => |v| self.value = v,
        .add => |o| self.value +%= o,
    }
}


// set/reset counter using crdt:

const operation = union(enum) {
    set: struct {set_owner: Clock, value: i32},
    add: struct {when_owner: Clock, value: i32},
}
owner: Clock,
value: i32,
fn applyOperation(self, operation) {
    switch(operation) {
        .add => |add| if(add.when_owner == self.owner) self.value += 1,
        .set => |set| {
            if(self.owner.order(set_owner) == .lt) {
                self.owner = set_owner;
                self.value += 1;
            }
        }
    }
}
```

in the replay method, operation implementation is pretty simple

in the crdt method, we have to make sure applyOperation adheres to the property so that:
- a: set 0, add 1
- b: set 0

what is the final outcome? it depends on who's 'set' won

in replay, that's inherent. there will be a final true order that operations are implied in

in crdt, the only order is dependency order. an operation that depends on another one won't be applied until all its dependencies have been applied, but otherwise could happen in any order. so we have to keep track of who won the set to skip the add if it isn't applicable

---

offline:

- don't think you need a crdt for offline. just when you come back online, send in all your events and apply all the ones that come in. if you have lots of events, you can temporarily skip updating the true version until all of the events have come in and your unapproved operations queue is empty
  - offline isn't great because you lack realtime feedback of what's happening, but it should work just fine with record/replay

---

so basically the one downside of this method is that we frequently need to clone the block that we're working on. CRDT just prevents that need.

- every time you type a letter:
  - apply locally
  - send to server
  - recieve from server
  - apply locally again

clones only happen when in a session with multiple people. a clone only happens when you recieve
an event from the server and have no 

and we can make them as copy-on-write as possible

I think it's fine

---

so what's the point of crdts anyway? why isn't anyone using this method?

- video games are somewhat with clientside prediction? you apply the event yourself, then send it off to the server

> You can only assume the server is authorative if there will not be network partitions or if writes are not accepted on the other side of the network partition (meaning on the client). As soon as the client accepts writes while offline those writes become authorative and will need to be merged with whatever changes the server saw.

this isn't true is it?

as long as only authoritative order is sent to clients, you're fine

a client can accept writes just fine while offline - it applies them before its own writes

it's basically rollback netcode isn't it? maybe?

---

the one problem with the replay method is that it relies on a source of truth for the history:

- if you have four clients: A, B, C, D:
  - if you sync client A and B and seperately sync client C and D, their histories are now unmergable
    - well not really, you just have to go back to the point where they diverged, choose an order, and replay them together
    - but you have to be careful about it, you can't just sync them randomly whenever you want