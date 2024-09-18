const std = @import("std");
const us = @cImport({
    @cInclude("libusockets.h");
});

const SSL: c_int = 1;

/// Our socket extension
const EchoSocket = struct {
    backpressure: std.ArrayList(u8),

    fn init(gpa: std.mem.Allocator) EchoSocket {
        return .{ .backpressure = .init(gpa) };
    }
    fn deinit(self: *EchoSocket) void {
        self.backpressure.deinit();
    }
};

/// Our socket context extension
const EchoContext = struct {};

/// Loop wakeup handler
fn onWakeup(loop: ?*us.struct_us_loop_t) callconv(.C) void {
    _ = loop;
}

/// Loop pre iteration handler
fn onPre(loop: ?*us.struct_us_loop_t) callconv(.C) void {
    _ = loop;
}

/// Loop post iteration handler
fn onPost(loop: ?*us.struct_us_loop_t) callconv(.C) void {
    _ = loop;
}

/// Socket writable handler
fn onEchoSocketWritable(s: ?*us.struct_us_socket_t) callconv(.C) ?*us.struct_us_socket_t {
    const es: *EchoSocket = @ptrCast(@alignCast(us.us_socket_ext(SSL, s)));

    // Continue writing out our backpressure
    const written: c_int = us.us_socket_write(SSL, s, es.backpressure.items.ptr, @intCast(es.backpressure.items.len), 0);
    es.backpressure.replaceRange(0, @intCast(written), &.{}) catch @panic("oom");

    // Client is not boring
    us.us_socket_timeout(SSL, s, 30);

    return s;
}

/// Socket closed handler
fn onEchoSocketClose(s: ?*us.struct_us_socket_t, code: c_int, reason: ?*anyopaque) callconv(.C) ?*us.struct_us_socket_t {
    const es: *EchoSocket = @ptrCast(@alignCast(us.us_socket_ext(SSL, s)));
    defer es.deinit();

    std.log.info("Client disconnected: {d}/{x}", .{ code, @intFromPtr(reason) });

    return s;
}

/// Socket half-closed handler
fn onEchoSocketEnd(s: ?*us.struct_us_socket_t) callconv(.C) ?*us.struct_us_socket_t {
    us.us_socket_shutdown(SSL, s);
    return us.us_socket_close(SSL, s, 0, null);
}

/// Socket data handler
fn onEchoSocketData(s: ?*us.struct_us_socket_t, data: [*c]u8, length: c_int) callconv(.C) ?*us.struct_us_socket_t {
    const es: *EchoSocket = @ptrCast(@alignCast(us.us_socket_ext(SSL, s)));

    // Print the data we recieved
    std.log.info("Client sent: \"{}\"", .{std.zig.fmtEscapes(data[0..@intCast(length)])});

    // Send it back or buffer it up
    const written: c_int = us.us_socket_write(SSL, s, data, length, 0);
    if (written != length) {
        es.backpressure.appendSlice(data[0..@intCast(length)]) catch @panic("oom");
    }

    // Client is not boring
    us.us_socket_timeout(SSL, s, 30);

    return s;
}

/// Socket opened handler
fn onEchoSocketOpen(s: ?*us.struct_us_socket_t, is_client: c_int, ip: [*c]u8, ip_length: c_int) callconv(.C) ?*us.struct_us_socket_t {
    const es: *EchoSocket = @ptrCast(@alignCast(us.us_socket_ext(SSL, s)));

    // Initialize the new socket's extension
    es.* = .init(std.heap.c_allocator);

    // Start a timeout to close the socket if boring
    us.us_socket_timeout(SSL, s, 30);

    std.log.info("Client connected: {d}, \"{}\"", .{ is_client, std.zig.fmtEscapes(ip[0..@intCast(ip_length)]) });

    return s;
}

/// Socket timeout handler
fn onEchoSocketTimeout(s: ?*us.struct_us_socket_t) callconv(.C) ?*us.struct_us_socket_t {
    std.log.err("Client was idle for too long", .{});
    return us.us_socket_close(SSL, s, 0, null);
}

pub fn main() !void {
    // The event loop
    const loop: ?*us.struct_us_loop_t = us.us_create_loop(null, &onWakeup, &onPre, &onPost, 0);

    // Socket context
    var options: us.struct_us_socket_context_options_t = .{};
    options.key_file_name = "key.pem";
    options.cert_file_name = "cert.pem";
    options.passphrase = "1234";

    const echo_context: ?*us.struct_us_socket_context_t = us.us_create_socket_context(SSL, loop, @sizeOf(EchoContext), options);

    // Registering event handlers
    us.us_socket_context_on_open(SSL, echo_context, &onEchoSocketOpen);
    us.us_socket_context_on_data(SSL, echo_context, &onEchoSocketData);
    us.us_socket_context_on_writable(SSL, echo_context, &onEchoSocketWritable);
    us.us_socket_context_on_close(SSL, echo_context, &onEchoSocketClose);
    us.us_socket_context_on_timeout(SSL, echo_context, &onEchoSocketTimeout);
    us.us_socket_context_on_end(SSL, echo_context, &onEchoSocketEnd);

    // Start accepting echo sockets
    const listen_socket: *us.struct_us_listen_socket_t = us.us_socket_context_listen(SSL, echo_context, null, 3000, 0, @sizeOf(EchoSocket)) orelse {
        return error.FailedToListen;
    };
    _ = listen_socket;

    std.log.info("Listening on port 3000", .{});
    us.us_loop_run(loop);
}

test "basic add functionality" {
    _ = us;
}
