type SendEvent = {
    kind: "start_update_group_from_group",
    group: Group,
    update_group: UpdateGroup,
    rendered: Rendered,
} | {
    kind: "update_group_update",
    rendered: Rendered,
} | {
    kind: "end_update_group",
    update_group: UpdateGroup,
    mode: "log" | "delete",
} | {
    kind: "stdin_read",
    update_group: UpdateGroup,
    token: EventToken<string | null>,
} | {
    kind: "group_log",
    rendered: Rendered,
} | {
    kind: "group_writeData",
    data: string,
} | {
    kind: "timeout",
    duration_ms: number,
    token: EventToken<undefined>,
} | {
    kind: "cancel_token",
    token: EventToken<any>,
};
type EventToken<T> = {filled: false} | {filled: true, value: T};
let send_queue: SendEvent[] = [];

type Defer = {
    (cb: () => undefined): undefined,
    execute: () => undefined,
};
function genDefer(): Defer {
    let list: (() => undefined)[] | null = [];
    const res: Defer = (cb: () => undefined) => {
        list!.push(cb);
    };
    res.execute = () => {
        const prev_list = list!;
        list = null;
        for(let i = prev_list.length; i > 0; ) {
            i -= 1;
            prev_list[i]();
        }
    };
    return res;
}

class Done<U> {
    constructor(public value: U) {}
}
class Token<T> {
    handle<U>(onCanceled: () => undefined, onValue: (value: T) => Token<U> | Done<U>): Token<U> {

    }
    cancel(): undefined {}
}

class UpdateGroup {
    // read stdin. if another update group is waiting on a read, this will wait for that one first.
    readStdin(opts: ReadStdinOpts): Token<string | null> {
        const event_token: EventToken<string | null> = {filled: false};
        send_queue.push({
            kind: "stdin_read",
            update_group: this,
            token: event_token,
        });
    }
    update(rendered: Rendered): undefined {
        // there should be a way to wait for a resonable time to update again, ie requestAnimationFrame
        send_queue.push({
            kind: "update_group_update",
            rendered,
        });
    }
    end(mode: "log" | "delete"): undefined {
        send_queue.push({
            kind: "end_update_group",
            update_group: this,
            mode,
        });
    }
}
class Group {
    beginUpdate(rendered: Rendered): UpdateGroup {
        const res = new UpdateGroup();
        send_queue.push({
            kind: "start_update_group_from_group",
            group: this,
            update_group: res,
            rendered,
        });
        return res;
    }
    log(rendered: Rendered): undefined {
        send_queue.push({
            kind: "group_log",
            rendered,
        });
    }
    writeData(data: string): undefined {
        send_queue.push({
            kind: "group_writeData",
            data,
        });
    }
}
type Rendered = string | {msg: string};
type ReadStdinOpts = {
    mode: "line",
};

function main(group: Group): Token<undefined> {
    const defer = genDefer();
    const update_group = group.beginUpdate("$> ");
    defer(() => update_group.end("log"));
    const read = (): Token<undefined> => update_group.readStdin({mode: "line"}).handle<undefined>(() => {
        return defer.execute();
    }, value => {
        if(value == null) {
            return new Done(defer.execute());
        }
        group.log("got "+value);
        group.writeData(value);
        return read();
    });
    return read();
}

async function runEventLoop() {
    while(true) {
        const queue = send_queue;
        send_queue = [];
        
        for(const item of queue) {
            if(item.kind === "start_update_group_from_group") {

            }else if(item.kind === "end_update_group") {

            }else if(item.kind === "group_log") {
                
            }else if(item.kind === "group_writeData") {

            }else if(item.kind === "update_group_update") {

            }else if(item.kind === "stdin_read") {
                
            }else if(item.kind === "timeout") {
                const timeout_id = setTimeout(item.duration_ms, () => {

                });             
            }
        }
    }
}

{
    const defer = genDefer();
    const main_group = new Group();
    main(main_group).handle(() => defer.execute(), () => {
        main_group.log("program completed");
        return new Done(defer.execute());
    });
    // TODO: cancel tok after 3000ms to demonstrate
    runEventLoop();
}