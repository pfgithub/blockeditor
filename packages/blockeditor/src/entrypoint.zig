const std = @import("std");
const blocks_mod = @import("blocks");
const bi = blocks_mod.blockinterface2;
const db = blocks_mod.blockdb;

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zstbi = @import("zstbi");

fn renderCounter(arena: std.mem.Allocator, counter_anyref: *db.BlockRef) void {
    zgui.setNextWindowPos(.{ .x = 20.0, .y = 60.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
    if (zgui.begin("My counter", .{})) {
        if (counter_anyref.clientValue()) |counter_anyblock| {
            const counter = counter_anyblock.cast(bi.CounterBlock);
            zgui.text("Count: {d} (server value: {d})", .{ counter.value.count, counter_anyref.contents().?.server_value.cast(bi.CounterBlock).value.count });
            if (zgui.button("Increment!", .{})) {
                var my_operation_al = bi.AlignedArrayList.init(arena);
                defer my_operation_al.deinit();
                const my_operation = bi.CounterBlock.Operation{
                    .add = 1,
                };
                my_operation.serialize(&my_operation_al);
                var my_undo_operation_al = bi.AlignedArrayList.init(arena);
                defer my_undo_operation_al.deinit();
                counter_anyref.applyOperation(my_operation_al.items, &my_undo_operation_al);
            }
            if (zgui.button("Zero!", .{})) {
                var my_operation_al = bi.AlignedArrayList.init(arena);
                defer my_operation_al.deinit();
                const my_operation = bi.CounterBlock.Operation{
                    .set = 0,
                };
                my_operation.serialize(&my_operation_al);
                var my_undo_operation_al = bi.AlignedArrayList.init(arena);
                defer my_undo_operation_al.deinit();
                counter_anyref.applyOperation(my_operation_al.items, &my_undo_operation_al);
            }
        } else {
            zgui.text("Counter loading...", .{});
        }
    }
    zgui.end();
}

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const gpa = gpa_alloc.allocator();

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var interface = db.BlockDB.init(gpa);
    defer interface.deinit();

    const my_counter = interface.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    defer my_counter.unref();

    {
        // Change cwd to where the executable is located.
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.posix.chdir(path) catch {};
    }

    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHintTyped(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 400, "blockeditor", null);
    defer window.destroy();
    window.setSizeLimits(10, 10, -1, -1);

    const gctx = try zgpu.GraphicsContext.create(
        gpa,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        },
        .{},
    );
    defer gctx.destroy(gpa);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    zgui.init(gpa);
    defer zgui.deinit();

    // TODO
    // _ = zgui.io.addFontFromFile(
    //     content_dir ++ "Roboto-Medium.ttf",
    //     std.math.floor(16.0 * scale_factor),
    // );

    zgui.backend.init(
        window,
        gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    defer zgui.backend.deinit();

    zgui.io.setConfigFlags(.{
        // can't |= config flags?
        .nav_enable_keyboard = true,
        .dock_enable = true,
        .dpi_enable_scale_fonts = true,
    });
    zgui.getStyle().scaleAllSizes(scale_factor);

    var frame_timer = try std.time.Timer.start();
    while (!window.shouldClose()) {
        if (@import("builtin").target.os.tag == .linux) {
            // hacky fps limitor to fix the lag on linux
            const trv = frame_timer.read();
            const min_time_before_next_frame = 16 * std.time.ns_per_ms;
            if (trv < min_time_before_next_frame) {
                std.time.sleep(min_time_before_next_frame - trv);
            }
            frame_timer.reset();
        }

        zglfw.pollEvents();

        zgui.backend.newFrame(
            gctx.swapchain_descriptor.width,
            gctx.swapchain_descriptor.height,
        );

        _ = zgui.DockSpaceOverViewport(zgui.getMainViewport(), .{});

        // Set the starting window position and size to custom values
        zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
        if (zgui.begin("My window", .{})) {
            if (zgui.button("Press me!", .{})) {
                std.debug.print("Button pressed\n", .{});
            }
        }
        zgui.end();

        renderCounter(arena, my_counter);

        const swapchain_texv = gctx.swapchain.getCurrentTextureView();
        defer swapchain_texv.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            // GUI pass
            {
                const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
                defer zgpu.endReleasePass(pass);
                zgui.backend.draw(pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});
        _ = gctx.present();

        _ = arena_alloc.reset(.retain_capacity);
    }
}
