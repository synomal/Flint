const std = @import("std");
const c = @import("c_imports.zig").c;

/// Holds all SDL rendering resources
pub const RenderState = struct {
    renderer: *c.SDL_Renderer,
    font: ?*c.TTF_Font = null,
    text_engine: ?*c.TTF_TextEngine = null,
    bg_texture: ?*c.SDL_Texture = null,
    logo_texture: ?*c.SDL_Texture = null,
    text_logo_texture: ?*c.SDL_Texture = null,
    window_width: f32 = 854,
    window_height: f32 = 480,
};

/// Initialize renderer: decode embedded background JPG, load embedded font
pub fn init(
    sdl_renderer: *c.SDL_Renderer,
    bg_data: []const u8,
    font_data: []const u8,
    logo_data: []const u8,
    text_logo_data: []const u8,
) RenderState {
    var state = RenderState{ .renderer = sdl_renderer };

    // ── Background image from embedded bytes ──
    state.bg_texture = loadTextureFromMemory(sdl_renderer, bg_data);
    if (state.bg_texture == null) {
        std.log.err("Failed to load background texture", .{});
    }

    // ── Logo and Text Logo ──
    state.logo_texture = loadTextureFromMemory(sdl_renderer, logo_data);
    state.text_logo_texture = loadTextureFromMemory(sdl_renderer, text_logo_data);

    // ── SDL3_ttf ──
    _ = c.TTF_Init();
    state.text_engine = c.TTF_CreateRendererTextEngine(sdl_renderer);

    // Write embedded font to tmp file (SDL3_ttf needs IOStream)
    const tmp_path = "/tmp/lcelauncher_font.otf";
    if (std.fs.createFileAbsolute(tmp_path, .{})) |f| {
        f.writeAll(font_data) catch {};
        f.close();
        const rw = c.SDL_IOFromFile(tmp_path, "rb");
        if (rw != null) {
            state.font = c.TTF_OpenFontIO(rw, true, 16);
            if (state.font == null) {
                std.log.err("TTF_OpenFontIO failed: {s}", .{c.SDL_GetError()});
            } else {
                _ = c.TTF_SetFontHinting(state.font, c.TTF_HINTING_NONE);
                std.log.info("Loaded TTF. Family: {s}, face: {s}", .{
                    c.TTF_GetFontFamilyName(state.font),
                    c.TTF_GetFontStyleName(state.font),
                });
            }
        }
    } else |_| {}

    return state;
}

pub fn deinit(state: *RenderState) void {
    if (state.font) |f| c.TTF_CloseFont(f);
    if (state.text_engine) |te| c.TTF_DestroyRendererTextEngine(te);
    if (state.bg_texture) |t| c.SDL_DestroyTexture(t);
    if (state.logo_texture) |t| c.SDL_DestroyTexture(t);
    if (state.text_logo_texture) |t| c.SDL_DestroyTexture(t);
    c.TTF_Quit();
}

fn loadTextureFromMemory(renderer: *c.SDL_Renderer, data: []const u8) ?*c.SDL_Texture {
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const pixels = c.stbi_load_from_memory(
        data.ptr,
        @intCast(data.len),
        &w,
        &h,
        &ch,
        4,
    );
    if (pixels == null) {
        std.log.err("stbi_load failed: {s}", .{c.stbi_failure_reason()});
        return null;
    }
    defer c.stbi_image_free(pixels);

    const surf = c.SDL_CreateSurfaceFrom(w, h, c.SDL_PIXELFORMAT_RGBA32, @ptrCast(pixels), w * 4);
    if (surf == null) {
        std.log.err("Failed to create surface: {s}", .{c.SDL_GetError()});
        return null;
    }
    defer c.SDL_DestroySurface(surf);

    return c.SDL_CreateTextureFromSurface(renderer, surf);
}

/// Clay text-measurement callback (C calling-convention)
/// user_data is the TTF_Font pointer passed via Clay_SetMeasureTextFunction
pub fn measureText(
    text_slice: c.Clay_StringSlice,
    text_config: [*c]c.Clay_TextElementConfig,
    user_data: ?*anyopaque,
) callconv(.c) c.Clay_Dimensions {
    const font: ?*c.TTF_Font = @ptrCast(@alignCast(user_data));

    if (font) |f| {
        _ = c.TTF_SetFontSize(f, @floatFromInt(text_config.*.fontSize));
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetStringSize(f, text_slice.chars, @intCast(text_slice.length), &w, &h);
        return .{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
    }

    // Fallback: estimate 8px per character
    return .{
        .width = @as(f32, @floatFromInt(text_slice.length)) * 8.0,
        .height = 16.0,
    };
}

/// Render the full-window scaled background + darkening overlay
pub fn renderBackground(state: *RenderState) void {
    if (state.bg_texture) |tex| {
        const dest = c.SDL_FRect{ .x = 0, .y = 0, .w = state.window_width, .h = state.window_height };
        _ = c.SDL_RenderTexture(state.renderer, tex, null, &dest);
    }

    // Darkening overlay RGBA(0,0,0,180)
    _ = c.SDL_SetRenderDrawBlendMode(state.renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(state.renderer, 0x1E, 0x0F, 0x3C, 180);
    const overlay = c.SDL_FRect{ .x = 0, .y = 0, .w = state.window_width, .h = state.window_height };
    _ = c.SDL_RenderFillRect(state.renderer, &overlay);
}

/// Process all Clay render commands and draw via SDL3
pub fn renderClayCommands(state: *RenderState, commands: c.Clay_RenderCommandArray) void {
    var i: i32 = 0;
    while (i < commands.length) : (i += 1) {
        const cmd = c.Clay_RenderCommandArray_Get(@constCast(&commands), i);
        if (cmd == null) continue;

        const bb = cmd.*.boundingBox;
        const rect = c.SDL_FRect{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };

        switch (cmd.*.commandType) {
            c.CLAY_RENDER_COMMAND_TYPE_RECTANGLE => {
                const cfg = &cmd.*.renderData.rectangle;
                _ = c.SDL_SetRenderDrawBlendMode(state.renderer, c.SDL_BLENDMODE_BLEND);
                _ = c.SDL_SetRenderDrawColor(state.renderer, @intFromFloat(cfg.backgroundColor.r), @intFromFloat(cfg.backgroundColor.g), @intFromFloat(cfg.backgroundColor.b), @intFromFloat(cfg.backgroundColor.a));
                _ = c.SDL_RenderFillRect(state.renderer, &rect);
            },
            c.CLAY_RENDER_COMMAND_TYPE_TEXT => {
                const cfg = &cmd.*.renderData.text;
                if (state.font) |font| {
                    if (state.text_engine) |te| {
                        _ = c.TTF_SetFontSize(font, @floatFromInt(cfg.fontSize));

                        // Drop shadow (+1,+1 black)
                        const shadow = c.TTF_CreateText(te, font, cfg.stringContents.chars, @intCast(cfg.stringContents.length));
                        if (shadow != null) {
                            _ = c.TTF_SetTextColor(shadow, 0, 0, 0, @intFromFloat(cfg.textColor.a * 0.5));
                            _ = c.TTF_DrawRendererText(shadow, @round(rect.x) + 1.0, @round(rect.y) + 1.0);
                            c.TTF_DestroyText(shadow);
                        }

                        // Main text
                        const text = c.TTF_CreateText(te, font, cfg.stringContents.chars, @intCast(cfg.stringContents.length));
                        if (text != null) {
                            _ = c.TTF_SetTextColor(text, @intFromFloat(cfg.textColor.r), @intFromFloat(cfg.textColor.g), @intFromFloat(cfg.textColor.b), @intFromFloat(cfg.textColor.a));
                            _ = c.TTF_DrawRendererText(text, @round(rect.x), @round(rect.y));
                            c.TTF_DestroyText(text);
                        }
                    }
                }
            },
            c.CLAY_RENDER_COMMAND_TYPE_BORDER => {
                const cfg = &cmd.*.renderData.border;
                _ = c.SDL_SetRenderDrawBlendMode(state.renderer, c.SDL_BLENDMODE_BLEND);
                _ = c.SDL_SetRenderDrawColor(state.renderer, @intFromFloat(cfg.color.r), @intFromFloat(cfg.color.g), @intFromFloat(cfg.color.b), @intFromFloat(cfg.color.a));

                if (cfg.width.top > 0) {
                    const line = c.SDL_FRect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @floatFromInt(cfg.width.top) };
                    _ = c.SDL_RenderFillRect(state.renderer, &line);
                }
                if (cfg.width.bottom > 0) {
                    const bh: f32 = @floatFromInt(cfg.width.bottom);
                    const line = c.SDL_FRect{ .x = rect.x, .y = rect.y + rect.h - bh, .w = rect.w, .h = bh };
                    _ = c.SDL_RenderFillRect(state.renderer, &line);
                }
                if (cfg.width.left > 0) {
                    const line = c.SDL_FRect{ .x = rect.x, .y = rect.y, .w = @floatFromInt(cfg.width.left), .h = rect.h };
                    _ = c.SDL_RenderFillRect(state.renderer, &line);
                }
                if (cfg.width.right > 0) {
                    const rw: f32 = @floatFromInt(cfg.width.right);
                    const line = c.SDL_FRect{ .x = rect.x + rect.w - rw, .y = rect.y, .w = rw, .h = rect.h };
                    _ = c.SDL_RenderFillRect(state.renderer, &line);
                }
            },
            c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START => {
                const clip = c.SDL_Rect{
                    .x = @intFromFloat(bb.x),
                    .y = @intFromFloat(bb.y),
                    .w = @intFromFloat(bb.width),
                    .h = @intFromFloat(bb.height),
                };
                _ = c.SDL_SetRenderClipRect(state.renderer, &clip);
            },
            c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END => {
                _ = c.SDL_SetRenderClipRect(state.renderer, null);
            },
            c.CLAY_RENDER_COMMAND_TYPE_IMAGE => {
                const tex: ?*c.SDL_Texture = @ptrCast(@alignCast(cmd.*.renderData.image.imageData));
                if (tex) |t| {
                    const dest = c.SDL_FRect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
                    _ = c.SDL_RenderTexture(state.renderer, t, null, &dest);
                }
            },
            else => {},
        }
    }
}
