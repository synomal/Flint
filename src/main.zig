const std = @import("std");
const builtin = @import("builtin");
const c = @import("c_imports.zig").c;

const renderer_mod = @import("renderer.zig");
const ui = @import("ui.zig");
const config_mod = @import("config.zig");
const safe_fs = @import("safe_fs.zig");
const launcher_mod = @import("launcher.zig");
const game_updater = @import("game_updater.zig");
const updater_mod = @import("updater.zig");

// ── Embedded assets ───────────────────────────────────────────────────
const bg_data = @embedFile("assets/background.jpg");
const font_data = @embedFile("assets/MinecraftStandard.otf");

fn clayErrorHandler(err: c.Clay_ErrorData) callconv(.c) void {
    const msg = err.errorText;
    if (msg.chars != null and msg.length > 0) {
        std.log.err("Clay: {s}", .{msg.chars[0..@intCast(msg.length)]});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ── Startup cleanup ───────────────────────────────────────────────
    updater_mod.cleanupOldLauncher();
    try safe_fs.ensureBaseDirs(allocator);

    // Delete abandoned downloading/ dir
    const versions_dir = try safe_fs.getVersionsDir(allocator);
    defer allocator.free(versions_dir);
    {
        var dl_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dl_path = try std.fmt.bufPrint(&dl_buf, "{s}downloading/", .{versions_dir});
        safe_fs.safeDelete(allocator, dl_path) catch {};
    }

    // ── Load config ───────────────────────────────────────────────────
    ui.ui_state.config = try config_mod.loadConfig(allocator);
    try safe_fs.assertSavesNotInVersions(allocator, ui.ui_state.config.saves_path);

    // ── Game version display ──────────────────────────────────────────
    if (game_updater.getGameVersionShort(allocator) catch null) |gv| {
        const written = std.fmt.bufPrint(&ui.ui_state.game_version_display, "nightly-{s}", .{gv}) catch "";
        ui.ui_state.game_version_len = written.len;
    }

    // Scan installed versions
    game_updater.refreshInstalledVersions(allocator);

    // Auto-check for game update in background
    const update_thread = std.Thread.spawn(.{}, struct {
        fn run() void {
            game_updater.checkForGameUpdate(std.heap.page_allocator) catch {};
        }
    }.run, .{}) catch null;
    if (update_thread) |t| t.detach();

    // ── SDL3 init ─────────────────────────────────────────────────────
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{c.SDL_GetError()});
        return;
    }
    defer c.SDL_Quit();

    var window: ?*c.SDL_Window = null;
    var sdl_renderer: ?*c.SDL_Renderer = null;
    window = c.SDL_CreateWindow("Flint", 800, 600, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (window == null) {
        std.log.err("Window: {s}", .{c.SDL_GetError()});
        return;
    }
    sdl_renderer = c.SDL_CreateRenderer(window.?, null);
    if (sdl_renderer == null) {
        std.log.err("Renderer: {s}", .{c.SDL_GetError()});
        return;
    }
    defer {
        if (sdl_renderer) |r| c.SDL_DestroyRenderer(r);
        if (window) |w| c.SDL_DestroyWindow(w);
    }
    _ = c.SDL_SetWindowMinimumSize(window.?, 854, 480);
    _ = c.SDL_StartTextInput(window.?);

    // ── Renderer init (asset loading) ─────────────────────────────────
    var render_state = renderer_mod.init(sdl_renderer.?, bg_data, font_data);
    defer renderer_mod.deinit(&render_state);

    // ── Clay init ─────────────────────────────────────────────────────
    const clay_size = c.Clay_MinMemorySize();
    const clay_mem = try allocator.alloc(u8, clay_size);
    defer allocator.free(clay_mem);

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window.?, &w, &h);
    render_state.window_width = @floatFromInt(w);
    render_state.window_height = @floatFromInt(h);

    _ = c.Clay_Initialize(
        .{ .memory = clay_mem.ptr, .capacity = clay_size },
        .{ .width = render_state.window_width, .height = render_state.window_height },
        .{ .errorHandlerFunction = clayErrorHandler, .userData = null },
    );
    // Pass font pointer through user_data so renderer.measureText can use it
    c.Clay_SetMeasureTextFunction(renderer_mod.measureText, render_state.font);

    // ── Wine check (Linux) ────────────────────────────────────────────
    if (comptime builtin.os.tag == .linux) {
        launcher_mod.checkWine(allocator) catch {};
    }

    // ── Main loop ─────────────────────────────────────────────────────
    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_RESIZED => {
                    var new_w: c_int = 0;
                    var new_h: c_int = 0;
                    _ = c.SDL_GetWindowSizeInPixels(window.?, &new_w, &new_h);
                    render_state.window_width = @floatFromInt(new_w);
                    render_state.window_height = @floatFromInt(new_h);
                    c.Clay_SetLayoutDimensions(.{
                        .width = render_state.window_width,
                        .height = render_state.window_height,
                    });
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    var log_w: c_int = 0;
                    var pix_w: c_int = 0;
                    _ = c.SDL_GetWindowSize(window.?, &log_w, null);
                    _ = c.SDL_GetWindowSizeInPixels(window.?, &pix_w, null);
                    const scale = if (log_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(log_w)) else 1.0;

                    c.Clay_SetPointerState(
                        .{ .x = event.motion.x * scale, .y = event.motion.y * scale },
                        event.motion.state & c.SDL_BUTTON_LMASK != 0,
                    );
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    var log_w: c_int = 0;
                    var pix_w: c_int = 0;
                    _ = c.SDL_GetWindowSize(window.?, &log_w, null);
                    _ = c.SDL_GetWindowSizeInPixels(window.?, &pix_w, null);
                    const scale = if (log_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(log_w)) else 1.0;

                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        c.Clay_SetPointerState(.{ .x = event.button.x * scale, .y = event.button.y * scale }, true);
                        ui.handleClick();
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    var log_w: c_int = 0;
                    var pix_w: c_int = 0;
                    _ = c.SDL_GetWindowSize(window.?, &log_w, null);
                    _ = c.SDL_GetWindowSizeInPixels(window.?, &pix_w, null);
                    const scale = if (log_w > 0) @as(f32, @floatFromInt(pix_w)) / @as(f32, @floatFromInt(log_w)) else 1.0;

                    c.Clay_SetPointerState(.{ .x = event.button.x * scale, .y = event.button.y * scale }, false);
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    c.Clay_UpdateScrollContainers(true, .{ .x = event.wheel.x * 10, .y = event.wheel.y * 10 }, 0.016);
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    if (event.text.text != null) {
                        const text_slice = std.mem.span(event.text.text);
                        ui.handleTextInput(text_slice);
                    }
                },
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_BACKSPACE) {
                        ui.handleBackspace();
                    } else if (event.key.key == c.SDLK_RETURN or event.key.key == c.SDLK_RETURN2) {
                        ui.handleReturn();
                    }
                },
                else => {},
            }
        }

        // Poll game process
        launcher_mod.pollGameProcess();

        // Layout
        const cmds = ui.layoutRoot();

        // Render
        _ = c.SDL_SetRenderDrawColor(sdl_renderer.?, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(sdl_renderer.?);
        renderer_mod.renderBackground(&render_state);
        renderer_mod.renderClayCommands(&render_state, cmds);
        _ = c.SDL_RenderPresent(sdl_renderer.?);

        c.SDL_Delay(16);
    }

    // Save config on exit
    config_mod.saveConfig(allocator, &ui.ui_state.config) catch {};
}
