const std = @import("std");

pub fn main() !void {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}).init;
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 4) return error.BadArgs;
    const source_name = args[1];
    const expected_hash = args[2];
    const output_name = args[3];

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // validate
    {
        var file = try std.fs.cwd().openFile(source_name, .{});
        defer file.close();
        var buf: [4096]u8 = undefined;
        while (true) {
            const len = try file.readAll(&buf);
            hasher.update(buf[0..len]);
            if (buf.len != len) break;
        }

        const base64_len = comptime std.base64.url_safe_no_pad.Encoder.calcSize(std.crypto.hash.sha2.Sha256.digest_length);
        var base64_buf: [base64_len]u8 = undefined;
        const base64_res = std.base64.url_safe_no_pad.Encoder.encode(&base64_buf, &hasher.finalResult());

        if (!std.mem.eql(u8, expected_hash, base64_res)) {
            std.log.err("Expected hash=`{s}`, got hash=`{s}`", .{ expected_hash, base64_res });
            return error.BadHash;
        }
    }

    // copy
    try std.fs.cwd().copyFile(source_name, std.fs.cwd(), output_name, .{});
}
