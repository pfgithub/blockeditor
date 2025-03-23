type SendEvent = {
    kind: "start_update_group_from_group",
    group: Group,
    update_group: UpdateGroup,
    rendered: Rendered,
} | {
    kind: "update_group_update",
    update_group: UpdateGroup,
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
type ReceiveEvent = {
    kind: "timeout",
    token: EventToken<undefined>,
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
        return new Token();
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
        return new Token();
    }
    update(rendered: Rendered): undefined {
        // there should be a way to wait for a resonable time to update again, ie requestAnimationFrame
        send_queue.push({
            kind: "update_group_update",
            update_group: this,
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
        group.writeData(value + "\n");
        return read();
    });
    return read();
}

class EventLoop {
    waiting_on_stdin: EventToken<any>[] = [];
    waiting_logs: Rendered[] = [];
    waiting_stdout: string[] = [];
    update_groups = new Map<UpdateGroup, Rendered>();
    recv_queue: ReceiveEvent[] = [];
    ready: (() => void) | null = null;

    _pushEvent(ev: ReceiveEvent): void {
        this.recv_queue.push(ev);
        if(this.ready) {
            const ready_cb = this.ready;
            this.ready = null;
            ready_cb();
        }
    }

    updateOutput() {
        // would be nice to use clreol as a fallback for people missing STARTBUF/ENDBUF
        const CLREOL = "\x1b[K"; // erase to end of line
        const CLREOS = "\x1b[J"; // erase to end of screen
        const STARTSYNC = "\x1b[?2026h"; // begin frame
        const ENDSYNC = "\x1b[?2026l"; // begin frame
        const CURSORUP = (n: number) => `\x1b[${n}A`;
        const HOME = "\r";
        let result: string = STARTSYNC + CLREOS;
        // the cursor is positioned before any update groups

        // 1. print waiting logs
        for(const log of this.waiting_logs) {
            result += log + "\n";
        }
        this.waiting_logs = [];
        process.stderr.write(result); result = "";

        // 2. write stdout
        process.stdout.write(this.waiting_stdout.join("\n"));

        // 3. print update groups
        let i = 0;
        for(const rendered of this.update_groups.values()) {
            if(i !== 0) result += "\n";
            result += rendered;
            i += 1;
        }

        // 4. try to return cursor
        // (this doesn't actually work and can't ever work portably because terminals suck)
        result += HOME + CURSORUP(i - 2);

        // 5. write
        result += ENDSYNC;
        process.stderr.write(result);
    }

    async waitEvents(queue: SendEvent[]): Promise<ReceiveEvent[]> {
        for(const item of queue) {
            if(item.kind === "start_update_group_from_group") {
                if(this.update_groups.has(item.update_group)) throw new Error("E");
                this.update_groups.set(item.update_group, item.rendered);
            }else if(item.kind === "end_update_group") {
                const val = this.update_groups.get(item.update_group);
                if(val == null) throw new Error("E");
                if(item.mode === "log") {
                    this.waiting_logs.push(val);
                }
                this.update_groups.delete(item.update_group);
            }else if(item.kind === "group_log") {
                this.waiting_logs.push(item.rendered);
            }else if(item.kind === "group_writeData") {
                this.waiting_stdout.push(item.data);
            }else if(item.kind === "update_group_update") {
                if(!this.update_groups.has(item.update_group)) throw new Error("E");
                this.update_groups.set(item.update_group, item.rendered);
            }else if(item.kind === "stdin_read") {
                this.waiting_on_stdin.push(item.token);
            }else if(item.kind === "timeout") {
                const timeout_id = setTimeout(() => {
                    this._pushEvent({
                        kind: "timeout",
                        token: item.token,
                    });
                }, item.duration_ms);
            }else throw new Error("E");
        }
        this.updateOutput();
        if(this.waiting_on_stdin.length > 0) {
            // TODO: read stdin
        }else{
            // TODO: process.stdin.pause();
        }

        await new Promise(r => {
            if(this.ready != null) throw new Error("E");
            this.ready = r;
        })
        return this.recv_queue;
    }
}


{
    const defer = genDefer();
    const main_group = new Group();
    const tok = main(main_group).handle(() => defer.execute(), () => {
        main_group.log("program completed");
        return new Done(defer.execute());
    });
    // TODO: have it cancel after 3000ms to see if cancelling works
    const ev = new EventLoop();
    while(true) {
        const q = send_queue;
        send_queue = null as any;
        const recv = await ev.waitEvents(q);
        send_queue = [];

        for(const ev of recv) {
            // execute the callbacks
            console.log("got ev", ev);
        }
    }
}