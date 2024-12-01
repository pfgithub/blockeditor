// https://github.com/kristoff-it/zine/blob/main/src/exes/server/main.zig

// MIT License
//
// Copyright (c) 2024 Loris Cro
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const fs = std.fs;
const mime = @import("mime");
const Allocator = std.mem.Allocator;
const not_found_html = @embedFile("404.html");
const assert = std.debug.assert;

const log = std.log.scoped(.server);
pub const std_options: std.Options = .{
    .log_level = .err,
};

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

const Server = struct {
    public_dir: std.fs.Dir,

    fn deinit(s: *Server) void {
        s.public_dir.close();
        s.* = undefined;
    }

    fn handleRequest(s: *Server, req: *std.http.Server.Request) !bool {
        var arena_impl = std.heap.ArenaAllocator.init(general_purpose_allocator.allocator());
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();

        // var request_buffer: [8 * 1024]u8 = undefined;
        // const n = try res.readAll(&request_buffer);
        // const request_body = request_buffer[0..n];

        var path_with_query = req.head.target;

        if (std.mem.indexOf(u8, path_with_query, "..")) |_| {
            std.debug.print("'..' not allowed in URLs\n", .{});
            @panic("TODO: check if '..' is fine");
        }

        if (std.mem.indexOfScalar(u8, path_with_query, '%')) |_| {
            const buffer = try arena.dupe(u8, path_with_query);
            path_with_query = std.Uri.percentDecodeInPlace(buffer);
        }

        var path = path_with_query[0 .. std.mem.indexOfScalar(u8, path_with_query, '?') orelse path_with_query.len];
        const path_ends_with_slash = std.mem.endsWith(u8, path, "/");

        if (path_ends_with_slash) {
            path = try std.fmt.allocPrint(arena, "{s}{s}", .{
                path,
                "index.html",
            });
        }

        const ext = fs.path.extension(path);
        const mime_type = mime.extension_map.get(ext) orelse
            .@"application/octet-stream";

        const file = s.public_dir.openFile(path[1..], .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (path_ends_with_slash) {
                    try req.respond(not_found_html, .{
                        .status = .not_found,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "text/html" },
                            .{ .name = "connection", .value = "close" },
                        },
                    });
                    log.debug("not found\n", .{});
                    return false;
                } else {
                    try appendSlashRedirect(arena, req, path_with_query);
                    return false;
                }
            },
            else => {
                const message = try std.fmt.allocPrint(
                    arena,
                    "error accessing the resource: {s}",
                    .{
                        @errorName(err),
                    },
                );
                try req.respond(message, .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/html" },
                        .{ .name = "connection", .value = "close" },
                    },
                });
                log.debug("error: {s}\n", .{@errorName(err)});
                return false;
            },
        };
        defer file.close();

        const contents = file.readToEndAlloc(arena, std.math.maxInt(usize)) catch |err| switch (err) {
            error.IsDir => {
                try appendSlashRedirect(arena, req, path_with_query);
                return false;
            },
            else => return err,
        };

        try req.respond(contents, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(mime_type) },
                .{ .name = "connection", .value = "close" },
            },
        });
        log.debug("sent file\n", .{});
        return false;
    }
};

fn appendSlashRedirect(
    arena: std.mem.Allocator,
    req: *std.http.Server.Request,
    path_with_query: []const u8,
) !void {
    // convert `foo/bar?query=1` to `foo/bar/?query=1`
    const query_start = std.mem.indexOfScalar(u8, path_with_query, '?') orelse path_with_query.len;
    const location = try std.fmt.allocPrint(
        arena,
        "{s}/{s}",
        .{ path_with_query[0..query_start], path_with_query[query_start..] },
    );

    try req.respond(not_found_html, .{
        .status = .see_other,
        .extra_headers = &.{
            .{ .name = "location", .value = location },
            .{ .name = "content-type", .value = "text/html" },
            .{ .name = "connection", .value = "close" },
        },
    });
    log.debug("append final slash redirect\n", .{});
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

pub fn main() !void {
    const gpa = general_purpose_allocator.allocator();
    const args = try std.process.argsAlloc(gpa);
    log.debug("server args: {s}", .{args});

    if (args.len < 3) return error.BadArgs;

    const root_dir_path = args[1];
    const listen_port = std.fmt.parseInt(u16, args[2], 10) catch {
        @panic("unable to parse port argument!");
    };

    // ensure the path exists. without this, an empty website that
    // doesn't generate a zig-out/ will cause the server to error out
    try fs.cwd().makePath(root_dir_path);

    var root_dir: fs.Dir = fs.cwd().openDir(root_dir_path, .{ .iterate = true }) catch |e|
        fatal("unable to open directory '{s}': {s}", .{ root_dir_path, @errorName(e) });
    defer root_dir.close();

    var server: Server = .{
        .public_dir = root_dir,
    };
    defer server.deinit();

    try serve(&server, listen_port);
}

fn serve(s: *Server, listen_port: u16) !void {
    const address = try std.net.Address.parseIp("127.0.0.1", listen_port);
    var tcp_server = try address.listen(.{
        .reuse_port = true,
        .reuse_address = true,
    });
    defer tcp_server.deinit();

    const server_port = tcp_server.listen_address.in.getPort();
    std.debug.print("\x1b[2K\rListening at http://127.0.0.1:{d}/\n", .{server_port});

    var buffer: [1024]u8 = undefined;
    accept: while (true) {
        const conn = try tcp_server.accept();

        var http_server = std.http.Server.init(conn, &buffer);
        var became_websocket = false;

        defer {
            if (!became_websocket) {
                conn.stream.close();
            } else {
                log.debug("request became websocket\n", .{});
            }
        }

        while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch |err| {
                if (err != error.HttpConnectionClosing) {
                    log.debug("connection error: {s}\n", .{@errorName(err)});
                }
                became_websocket = true;
                continue :accept;
            };

            log.debug("request: {s}", .{request.head.target});
            became_websocket = s.handleRequest(&request) catch |err| {
                log.debug("failed request: {s}", .{@errorName(err)});
                continue :accept;
            };
            if (became_websocket) continue :accept;
        }
    }
}

/// like fs.path.dirname but ensures a final `/`
fn dirNameWithSlash(path: []const u8) []const u8 {
    const d = fs.path.dirname(path).?;
    if (d.len > 1) {
        return path[0 .. d.len + 1];
    } else {
        return "/";
    }
}
