const std = @import("std");

fn kernel(self: *Shared) void {
    self.kcall_mutex.lock();
    // defer self.kcall_mutex.unlock(); // don't unlock kcall_mutex at the end
    while (true) {
        while (self.kcall_data == null) self.kcall_condition.wait(&self.kcall_mutex);

        // got syscall; process
        switch (self.kcall_data.?.tag) {
            .race => {
                // todo: wake up thread once any of the tasks are done
            },
            .exit => break,
        }
        std.log.info("got syscall: {s}", .{@tagName(self.kcall_data.?.tag)});

        {
            self.kcall_response_mutex.lock();
            self.kcall_response_mutex.unlock();
            self.kcall_responded = true;
            self.kcall_data = null;
        }
        self.kcall_response_condition.signal();
    }
    // exit
    // don't unlock kcall mutex, return from fn.
}

const Kcall = extern struct {
    // kcall is for tasks which must always be executed synchronously
    // (should cancel be one of these?)
    tag: enum(usize) { race, exit },
    value: extern union {
        race: extern struct {
            // len 0 = drain tasks
            tasks: [*]const *Task,
            tasks_len_and_result_index: usize,
        },
        exit: extern struct {
            code: u8,
        },
    },
};
const Task = extern struct {
    status: std.atomic.Value(enum(usize) { new, waiting, canceled, done }) = .init(.new),
    tag: enum(usize) { cancel, print },
    value: extern union {
        cancel: extern struct {
            tasks: [*]const *Task,
            tasks_len: usize,
        },
        print: extern struct {
            msg: [*]const u8,
            msg_len: usize,
        },
    },
};
const QUEUE_LEN = 128;

const Shared = struct {
    kcall_mutex: std.Thread.Mutex = .{},
    kcall_condition: std.Thread.Condition = .{},
    kcall_data: ?*const Kcall = null,
    kcall_response_mutex: std.Thread.Mutex = .{},
    kcall_response_condition: std.Thread.Condition = .{},
    kcall_responded: bool = false,

    queue: [QUEUE_LEN]?*Task = @splat(null),
    queue_end: std.atomic.Value(usize) = .init(0),
    queue_start: std.atomic.Value(usize) = .init(0),

    pub fn kcall(self: *Shared, data: *const Kcall) void {
        self.kcall_response_mutex.lock();
        defer self.kcall_response_mutex.unlock();
        {
            self.kcall_mutex.lock();
            defer self.kcall_mutex.unlock();
            std.debug.assert(self.kcall_data == null);
            self.kcall_data = data;
            std.debug.assert(!self.kcall_responded);
        }
        self.kcall_condition.signal();
        while (!self.kcall_responded) self.kcall_response_condition.wait(&self.kcall_response_mutex);
        self.kcall_responded = false;
    }
    /// if race is called with no tasks, the queue is fully drained and the result is is '0'
    pub fn race(self: *Shared, tasks: []const *Task) usize {
        // assert none of the tasks are canceled
        if (tasks.len > 0) for (tasks) |task| std.debug.assert(task.status.load(.seq_cst) != .canceled);
        // check if any tasks are already done
        if (tasks.len > 0) for (tasks, 0..) |task, i| if (task.status.load(.seq_cst) == .done) return i;

        var kcall_data: Kcall = .{ .tag = .race, .value = .{ .race = .{
            .tasks = tasks.ptr,
            .tasks_len_and_result_index = tasks.len,
        } } };
        self.kcall(&kcall_data);
        return kcall_data.value.race.tasks_len_and_result_index;
    }
    pub fn drainQueue(self: *Shared) void {
        _ = self.race(&.{});
    }
    pub fn exit(shared: *Shared, code: u8) noreturn {
        var kcall_data: Kcall = .{ .tag = .exit, .value = .{ .exit = .{ .code = code } } };
        shared.kcall(&kcall_data);
        unreachable;
    }

    pub fn queueTasks(self: *Shared, tasks: []const *Task) void {
        if (tasks.len != 1) @panic("TODO queueTasks");
        const task = tasks[0];
        // if the queue is full, drain the queue
        if ((self.queue_end.load(.seq_cst) + 1) % QUEUE_LEN == self.queue_start.load(.seq_cst)) {
            // queue is full (if we inserted another item, the queue would incorrectly appear empty)
            self.drainQueue();
            std.debug.assert(self.queue_end.load(.seq_cst) == self.queue_start.load(.seq_cst)); // queue is drained & only one thread may write to the queue
        }
        const queue_end = self.queue_end.load(.seq_cst); // only we can modify this value so it's fine
        std.debug.assert((queue_end + 1) % QUEUE_LEN != self.queue_start.load(.seq_cst)); // queue has space for one item
        self.queue[queue_end] = task;
        self.queue_end.store((queue_end + 1) % QUEUE_LEN, .seq_cst);
        // done
    }
    pub fn cancelTasks(self: *Shared, tasks: []const *Task) void {
        // TODO:
        // - need to release any associated resources
        //   - kernel side will do this, even for a 'done' task
        // - need to assert none of them are canceled
        // - may need to free the tasks? unclear
        var task: Task = .{
            .tag = .cancel,
            .value = .{ .cancel = .{ .tasks = tasks.ptr, .tasks_len = tasks.len } },
        };
        self.queueTasks(&.{&task});
        self.race(&.{&task});
    }
};

fn app(shared: *Shared) void {
    defer shared.exit(0);
    std.log.info("before kcall", .{});
    _ = shared.race(&.{});
    std.log.info("after kcall", .{});

    // typically this would be heap-allocated
    var print_task = Task{ .tag = .print, .value = .{ .print = .{
        .msg = "Hello, World!\n",
        .msg_len = "Hello, World!\n".len,
    } } };
    shared.queueTasks(&.{&print_task});
    _ = shared.race(&.{&print_task});
}

pub fn main() !void {
    var shared: Shared = .{};
    const kthread = try std.Thread.spawn(.{}, kernel, .{&shared});
    const appthread = try std.Thread.spawn(.{}, app, .{&shared});

    kthread.join();
    appthread.detach();
}
