const std = @import("std");
const global = @import("../../../lib/global.zig");
const imgui = global.imgui;

pub const LspProcessManager = struct {
    gpa: std.mem.Allocator,
    process: std.process.Child,
    initialized: enum { no, progress, yes },
    stderr: std.ArrayList(u8),

    _temp_value: std.ArrayList(u8),
    _send_queue: std.ArrayList(u8),
    _id: usize = 0,

    _poller: std.io.Poller(PollEnum),

    const PollEnum = enum { stdin, stdout, stderr };

    pub fn init(gpa: std.mem.Allocator) !LspProcessManager {
        if (@import("builtin").target.os.tag == .windows) return error.DisabledOnWindows;
        // if (true) return error.LspDisabled;
        var process = std.process.Child.init(&.{"zls"}, gpa);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;
        // process.stderr_behavior = .Inherit;
        try process.spawn();
        return .{
            .gpa = gpa,
            .process = process,
            .initialized = .no,
            .stderr = std.ArrayList(u8).init(gpa),

            ._poller = std.io.poll(gpa, PollEnum, .{
                .stdin = process.stdin.?,
                .stdout = process.stdout.?,
                .stderr = process.stderr.?,
            }),
            ._temp_value = std.ArrayList(u8).init(gpa),
            ._send_queue = std.ArrayList(u8).init(gpa),
        };
    }
    pub fn deinit(self: *LspProcessManager) void {
        self.stderr.deinit();
        self._poller.deinit();
        self._temp_value.deinit();
        self._send_queue.deinit();
        _ = self.process.kill() catch @panic("kill fail");
    }

    fn sendMessage(self: *LspProcessManager, method: []const u8, params: anytype) !usize {
        std.debug.assert(self._temp_value.items.len == 0);
        defer self._temp_value.clearRetainingCapacity();

        const id = self._id;
        self._id += 1;

        const id_str = std.fmt.allocPrint(self.gpa, "{d}", .{id}) catch @panic("oom");
        defer self.gpa.free(id_str);

        std.json.stringify(.{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
            .id = id_str,
        }, .{ .whitespace = .minified }, self._temp_value.writer()) catch @panic("oom");

        const sqw = self._send_queue.writer();
        sqw.print("Content-Length: {d}\r\n", .{self._temp_value.items.len}) catch @panic("oom");
        sqw.print("\r\n", .{}) catch @panic("oom");
        self._send_queue.appendSlice(self._temp_value.items) catch @panic("oom");

        return id;
    }

    fn _recieveMessages(self: *LspProcessManager) !void {
        // const stdout_reader = self.process.stdout.?.reader();
        // stdout_reader.read
        // https://stackoverflow.com/questions/13811614/how-to-see-if-a-pipe-is-empty
        // have to poll and then read until '\r\n'

        while (try self._poller.pollTimeout(0)) {
            var cont = false;
            {
                const stream = self._poller.fifo(.stdout);
                const slice = stream.readableSlice(0);
                if (slice.len > 0) {
                    cont = true;
                    std.log.info("stdout chunk {d}: `{s}`", .{ slice.len, slice });
                }
                stream.discard(slice.len);
                // we have to parse: https://github.com/gernest/zls/blob/master/src/rpc.zig
            }
            {
                const stream = self._poller.fifo(.stderr);
                const slice = stream.readableSlice(0);
                if (slice.len > 0) {
                    self.stderr.appendSlice(slice) catch @panic("oom");
                }
                stream.discard(slice.len);
            }
            if (!cont) break;
        }
    }
    fn _sendMessages(self: *LspProcessManager) !void {
        if (self._send_queue.items.len == 0) return;
        const stdin_writer = self.process.stdin.?.writer();
        std.log.info("sending message: `{s}`", .{self._send_queue.items});
        // this can probably block :/
        try stdin_writer.writeAll(self._send_queue.items);
        self._send_queue.clearRetainingCapacity();
        std.log.info("-> done", .{});
    }

    pub fn _tick(self: *LspProcessManager) !void {
        switch (self.initialized) {
            .no => {
                self.initialized = .progress;
                // https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#initializeParams
                _ = try self.sendMessage("initialize", .{
                    .processId = @as(?i32, switch (@import("builtin").os.tag) {
                        .macos => (struct {
                            // can't call std.c.getpid()?
                            pub extern "c" fn getpid() std.c.pid_t;
                        }).getpid(),
                        .windows => @bitCast(std.os.windows.kernel32.GetCurrentProcessId()),
                        .linux => std.os.linux.getpid(),
                        else => null,
                    }),
                    .clientInfo = .{
                        .name = "blockeditor-codeeditor",
                    },
                    .capabilities = .{
                        .general = .{
                            .positionEncodings = .{"utf-8"},
                        },
                    },
                });
                return;
            },
            .progress => return,
            .yes => {},
        }
    }

    pub fn tick(self: *LspProcessManager) !void {
        try self._recieveMessages();
        try self._tick();
        try self._sendMessages();

        self.gui();
    }

    fn gui(self: *LspProcessManager) void {
        if (imgui.begin("ZLS Log", null, 0)) {
            // https://github.com/ocornut/imgui/blob/6ccc561a2ab497ad4ae6ee1dbd3b992ffada35cb/imgui_demo.cpp#L7472
            // TextUnformatted does the clipping automatically
            imgui.text(self.stderr.items);
        }
        imgui.end();
    }
};

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_alloc.deinit() == .leak) @panic("leak");
    const gpa = gpa_alloc.allocator();

    var lsp = try LspProcessManager.init(gpa);
    defer lsp.deinit();

    while (true) {
        // std.log.info("tick", .{});
        try lsp.tick();
        std.time.sleep(std.time.ns_per_ms * 100);
    }
}

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
// eew why is it like this
