const std = @import("std");
const builtin = @import("builtin");
const c = @import("c_imports.zig").c;

const config_mod = @import("config.zig");
const game_updater = @import("game_updater.zig");
const updater = @import("updater.zig");
const launcher_mod = @import("launcher.zig");

/// Active sidebar tab
pub const Tab = enum(u8) {
    play = 0,
    versions = 1,
    settings = 2,
};

/// Which input field is focused
pub const ActiveField = enum {
    none,
    username,
    ip,
    port,
    saves_path,
    preset_name,
};

/// UI mutable state
pub const UiState = struct {
    active_tab: Tab = .play,
    config: config_mod.Config = .{},
    game_version_display: [64]u8 = [_]u8{0} ** 64,
    game_version_len: usize = 0,
    active_field: ActiveField = .none,

    // Branding textures (set from main.zig)
    logo_texture: ?*c.SDL_Texture = null,
    text_logo_texture: ?*c.SDL_Texture = null,

    // Edit buffers for input fields (persist until Clay renders)
    username_buf: [64]u8 = [_]u8{0} ** 64,
    username_len: usize = 0,
    ip_buf: [64]u8 = [_]u8{0} ** 64,
    ip_len: usize = 0,
    port_buf: [16]u8 = [_]u8{0} ** 16,
    port_len: usize = 0,
    saves_buf: [256]u8 = [_]u8{0} ** 256,
    saves_len: usize = 0,
    preset_name_buf: [64]u8 = [_]u8{0} ** 64,
    preset_name_len: usize = 0,

    /// Copy config values into edit buffers
    pub fn syncFromConfig(self: *UiState) void {
        const preset = self.config.presets[self.config.active_preset];

        self.username_len = @min(preset.username.len, self.username_buf.len);
        if (self.username_len > 0 and preset.username.ptr != self.username_buf[0..].ptr) {
            @memcpy(self.username_buf[0..self.username_len], preset.username[0..self.username_len]);
        }

        self.ip_len = @min(preset.ip.len, self.ip_buf.len);
        if (self.ip_len > 0 and preset.ip.ptr != self.ip_buf[0..].ptr) {
            @memcpy(self.ip_buf[0..self.ip_len], preset.ip[0..self.ip_len]);
        }

        self.port_len = @min(preset.port.len, self.port_buf.len);
        if (self.port_len > 0 and preset.port.ptr != self.port_buf[0..].ptr) {
            @memcpy(self.port_buf[0..self.port_len], preset.port[0..self.port_len]);
        }

        self.saves_len = @min(self.config.saves_path.len, self.saves_buf.len);
        if (self.saves_len > 0 and self.config.saves_path.ptr != self.saves_buf[0..].ptr) {
            @memcpy(self.saves_buf[0..self.saves_len], self.config.saves_path[0..self.saves_len]);
        }

        self.preset_name_len = @min(preset.name.len, self.preset_name_buf.len);
        if (self.preset_name_len > 0 and preset.name.ptr != self.preset_name_buf[0..].ptr) {
            @memcpy(self.preset_name_buf[0..self.preset_name_len], preset.name[0..self.preset_name_len]);
        }
    }
};

pub var ui_state = UiState{};

/// Handle a text input character from SDL
pub fn handleTextInput(text: []const u8) void {
    switch (ui_state.active_field) {
        .username => appendToBuffer(&ui_state.username_buf, &ui_state.username_len, text),
        .ip => appendToBuffer(&ui_state.ip_buf, &ui_state.ip_len, text),
        .port => appendToBuffer(&ui_state.port_buf, &ui_state.port_len, text),
        .saves_path => appendToBuffer(&ui_state.saves_buf, &ui_state.saves_len, text),
        .preset_name => appendToBuffer(&ui_state.preset_name_buf, &ui_state.preset_name_len, text),
        .none => {},
    }
}

/// Handle backspace key
pub fn handleBackspace() void {
    switch (ui_state.active_field) {
        .username => {
            if (ui_state.username_len > 0) ui_state.username_len -= 1;
        },
        .ip => {
            if (ui_state.ip_len > 0) ui_state.ip_len -= 1;
        },
        .port => {
            if (ui_state.port_len > 0) ui_state.port_len -= 1;
        },
        .saves_path => {
            if (ui_state.saves_len > 0) ui_state.saves_len -= 1;
        },
        .preset_name => {
            if (ui_state.preset_name_len > 0) ui_state.preset_name_len -= 1;
        },
        .none => {},
    }
}

/// Handle Enter/Return key — commit and unfocus
pub fn handleReturn() void {
    commitActiveField();
    ui_state.active_field = .none;
}

/// Handle Tab key — cycle focus between Username -> IP -> Port -> Username
pub fn handleTab() void {
    commitActiveField();
    ui_state.active_field = switch (ui_state.active_field) {
        .username => .ip,
        .ip => .port,
        .port => .preset_name,
        .preset_name => .username,
        else => .username,
    };
    // Sync to ensurebuffers are ready for the new field
    ui_state.syncFromConfig();
}

fn appendToBuffer(buf: anytype, len: *usize, text: []const u8) void {
    for (text) |ch| {
        if (len.* < buf.len) {
            buf[len.*] = ch;
            len.* += 1;
        }
    }
}

/// Write edit buffer contents back to config
fn commitActiveField() void {
    const p = ui_state.config.active_preset;
    switch (ui_state.active_field) {
        .username => ui_state.config.presets[p].username = ui_state.username_buf[0..ui_state.username_len],
        .ip => ui_state.config.presets[p].ip = ui_state.ip_buf[0..ui_state.ip_len],
        .port => ui_state.config.presets[p].port = ui_state.port_buf[0..ui_state.port_len],
        .saves_path => ui_state.config.saves_path = ui_state.saves_buf[0..ui_state.saves_len],
        .preset_name => ui_state.config.presets[p].name = ui_state.preset_name_buf[0..ui_state.preset_name_len],
        .none => {},
    }
}

// ── Color helpers ──────────────────────────────────────────────────────

fn rgba(r: f32, g: f32, b: f32, a: f32) c.Clay_Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

// Color constants matching the Minecraft Launcher spec
const COLOR_HEADER_BG = rgba(0x1A, 0x11, 0x2A, 0xBB);
const COLOR_SIDEBAR_BG = rgba(0x35, 0x2A, 0x45, 0xAA);
const COLOR_PANEL_BG = rgba(0x2A, 0x1E, 0x3A, 0x99);
const COLOR_BOTTOM_BG = rgba(0x1A, 0x11, 0x2A, 0xBB);
const COLOR_WHITE = rgba(0xFF, 0xFF, 0xFF, 0xFF);
const COLOR_MUTED = rgba(0xAA, 0xAA, 0xAA, 0xFF);
const COLOR_GREEN = rgba(0x5D, 0x23, 0xA4, 0xFF);
const COLOR_TAB_ACTIVE = rgba(0x2A, 0x1E, 0x3A, 0xFF);
const COLOR_TRANSPARENT = rgba(0, 0, 0, 0);
const COLOR_BORDER = rgba(0x45, 0x35, 0x55, 0xFF);
const COLOR_INPUT_BG = rgba(0x15, 0x0A, 0x25, 0xCC);
const COLOR_INPUT_BORDER = rgba(0x6A, 0x4B, 0x9A, 0xFF);
const COLOR_CARD_BG = rgba(0x30, 0x25, 0x40, 0x88);
const COLOR_CARD_ACTIVE = rgba(0x40, 0x35, 0x55, 0xAA);
const COLOR_YELLOW = rgba(0xDA, 0xAA, 0x20, 0xFF);
const COLOR_BLUE = rgba(0x3A, 0x7A, 0xDA, 0xFF);
const COLOR_GRAY = rgba(0x66, 0x66, 0x66, 0xFF);
const COLOR_RED = rgba(0xDA, 0x3A, 0x3A, 0xFF);
const COLOR_PROGRESS_TRACK = rgba(0x1A, 0x1A, 0x1A, 0xFF);

const FONT_ID: u16 = 0;

// File-scope buffer for dynamic text that must persist until Clay renders
var dl_progress_buf: [96]u8 = undefined;
var dl_progress_len: usize = 0;

// ── Helpers for Clay raw API ───────────────────────────────────────────

fn clayStr(s: []const u8) c.Clay_String {
    return .{ .length = @intCast(s.len), .chars = s.ptr };
}

fn clayId(name: []const u8) c.Clay_ElementId {
    return c.Clay__HashString(clayStr(name), 0);
}

fn clayIdI(name: []const u8, index: u32) c.Clay_ElementId {
    return c.Clay__HashStringWithOffset(clayStr(name), index, 0);
}

fn openElement(name: []const u8) void {
    c.Clay__OpenElementWithId(clayId(name));
}

fn openElementI(name: []const u8, index: u32) void {
    c.Clay__OpenElementWithId(clayIdI(name, index));
}

fn closeElement() void {
    c.Clay__CloseElement();
}

var text_id_counter: u32 = 0;

fn textElement(s: []const u8, font_size: u16, color: c.Clay_Color) void {
    text_id_counter +%= 1;
    // We open a transparent block just to contain the text, with a unique ID based on pointer+counter
    c.Clay__OpenElementWithId(c.Clay__HashStringWithOffset(clayStr(s), text_id_counter, 0));
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = fixedW(0), .height = fixedH(0) } } });

    c.Clay__OpenTextElement(clayStr(s), c.Clay__StoreTextElementConfig(.{
        .fontId = FONT_ID,
        .fontSize = font_size,
        .textColor = color,
    }));

    c.Clay__CloseElement(); // Close textElement container
}

fn imageElement(name: []const u8, texture: ?*c.SDL_Texture, width: f32, height: f32) void {
    if (texture) |tex| {
        openElement(name);
        c.Clay__ConfigureOpenElement(.{
            .layout = .{ .sizing = .{ .width = fixedW(width), .height = fixedH(height) } },
            .image = .{ .imageData = tex },
        });
        closeElement();
    }
}

fn button(id: []const u8, text: []const u8, fontSize: u16, bgColor: c.Clay_Color, widthSizing: c.Clay_SizingAxis) void {
    openElement(id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = widthSizing, .height = fitHeight() },
            .padding = .{ .left = 16, .right = 16, .top = 6, .bottom = 6 },
            .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = bgColor,
        .cornerRadius = uniformCorner(4),
    });
    c.Clay__OpenTextElement(clayStr(text), c.Clay__StoreTextElementConfig(.{
        .fontSize = fontSize,
        .textColor = COLOR_WHITE,
        .fontId = FONT_ID,
    }));
    closeElement();
}

fn growSize() c.Clay_Sizing {
    return .{
        .width = .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW },
        .height = .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW },
    };
}

fn growWidth() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW };
}

fn growHeight() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW };
}

fn fitWidth() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_FIT };
}

fn fitHeight() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_FIT };
}

fn fixedW(w: f32) c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = w, .max = w } }, .type = c.CLAY__SIZING_TYPE_FIXED };
}

fn fixedH(h: f32) c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = h, .max = h } }, .type = c.CLAY__SIZING_TYPE_FIXED };
}

fn percentW(pct: f32) c.Clay_SizingAxis {
    return .{ .size = .{ .percent = pct }, .type = c.CLAY__SIZING_TYPE_PERCENT };
}

fn uniformCorner(r: f32) c.Clay_CornerRadius {
    return .{ .topLeft = r, .topRight = r, .bottomLeft = r, .bottomRight = r };
}

fn uniformBorder(width: u16) c.Clay_BorderWidth {
    return .{ .left = width, .right = width, .top = width, .bottom = width, .betweenChildren = 0 };
}

fn pad4(l: u16, r: u16, t: u16, b: u16) c.Clay_Padding {
    return .{ .left = l, .right = r, .top = t, .bottom = b };
}

// ── Layout Root ────────────────────────────────────────────────────────

pub fn layoutRoot() c.Clay_RenderCommandArray {
    text_id_counter = 0; // Reset text ID counter every frame
    c.Clay_BeginLayout();

    // Root container
    openElement("Root");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = growSize(),
        },
    });

    layoutHeader();
    layoutMiddle();
    layoutBottomBar();

    closeElement(); // Root

    return c.Clay_EndLayout();
}

// ── Header Bar ─────────────────────────────────────────────────────────

fn layoutHeader() void {
    openElement("Header");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = growWidth(), .height = fixedH(36) },
            .padding = pad4(12, 12, 0, 0),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            .childGap = 16,
        },
        .backgroundColor = COLOR_HEADER_BG,
    });

    // Title
    imageElement("TextLogo", ui_state.text_logo_texture, 82, 20);

    // Spacer
    openElement("HSp1");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = growWidth(), .height = fixedH(0) } } });
    closeElement();

    // Game version
    if (ui_state.game_version_len > 0) {
        textElement(ui_state.game_version_display[0..ui_state.game_version_len], 10, COLOR_MUTED);
    } else {
        textElement("Not installed", 10, COLOR_MUTED);
    }

    // Spacer
    openElement("HSp2");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = growWidth(), .height = fixedH(0) } } });
    closeElement();

    // Status pills
    layoutPill("GPill", gameStatusText(), gameStatusColor());
    layoutPill("LPill", launcherStatusText(), launcherStatusColor());

    closeElement(); // Header
}

fn layoutPill(name: []const u8, text: []const u8, color: c.Clay_Color) void {
    button(name, text, 10, color, fitWidth());
}

fn gameStatusText() []const u8 {
    return switch (game_updater.game_update_status) {
        .up_to_date => "Game up to date",
        .update_available => "Game update available",
        .downloading => "Downloading...",
        .checking => "Checking...",
        .not_checked => "Not checked",
        .err => "Offline",
    };
}

fn gameStatusColor() c.Clay_Color {
    return switch (game_updater.game_update_status) {
        .up_to_date => COLOR_GREEN,
        .update_available => COLOR_YELLOW,
        .downloading => COLOR_BLUE,
        .checking, .not_checked => COLOR_GRAY,
        .err => COLOR_RED,
    };
}

fn launcherStatusText() []const u8 {
    return switch (updater.launcher_update_status) {
        .up_to_date => "Launcher up to date",
        .update_available => "Launcher update available",
        .downloading => "Downloading...",
        .checking => "Checking...",
        .not_checked => "Not checked",
        .err => "Offline",
    };
}

fn launcherStatusColor() c.Clay_Color {
    return switch (updater.launcher_update_status) {
        .up_to_date => COLOR_GREEN,
        .update_available => COLOR_YELLOW,
        .downloading => COLOR_BLUE,
        .checking, .not_checked => COLOR_GRAY,
        .err => COLOR_RED,
    };
}

// ── Middle Section ─────────────────────────────────────────────────────

fn layoutMiddle() void {
    openElement("Mid");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = growSize(),
        },
    });

    layoutSidebar();
    layoutContent();

    closeElement(); // Mid
}

// ── Sidebar ────────────────────────────────────────────────────────────

fn layoutSidebar() void {
    openElement("Sidebar");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = fixedW(160), .height = growHeight() },
        },
        .backgroundColor = COLOR_SIDEBAR_BG,
    });

    layoutTab("PLAY", .play);
    layoutTab("VERSIONS", .versions);
    layoutTab("SETTINGS", .settings);

    closeElement(); // Sidebar
}

fn layoutTab(label: []const u8, tab: Tab) void {
    const is_active = ui_state.active_tab == tab;

    openElement(label);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = growWidth(), .height = fixedH(36) },
            .padding = pad4(16, 12, 0, 0),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = if (is_active) COLOR_TAB_ACTIVE else COLOR_TRANSPARENT,
        .border = if (is_active) .{
            .color = COLOR_GREEN,
            .width = .{ .left = 3, .right = 0, .top = 0, .bottom = 0, .betweenChildren = 0 },
        } else std.mem.zeroes(c.Clay_BorderElementConfig),
    });

    textElement(label, 12, if (is_active) COLOR_WHITE else COLOR_MUTED);
    closeElement();
}

// ── Content Panel ──────────────────────────────────────────────────────

fn layoutContent() void {
    openElement("Content");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = growSize(),
            .padding = pad4(16, 16, 16, 16),
            .childGap = 12,
        },
        .backgroundColor = COLOR_PANEL_BG,
    });

    switch (ui_state.active_tab) {
        .play => layoutPlayTab(),
        .versions => layoutVersionsTab(),
        .settings => layoutSettingsTab(),
    }

    closeElement(); // Content
}

// ── Play Tab ───────────────────────────────────────────────────────────

fn layoutPlayTab() void {
    textElement("Server Presets", 16, COLOR_WHITE);

    // Row 1
    openElement("PR1");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = growWidth(), .height = growHeight() },
            .childGap = 12,
        },
    });
    layoutPresetCard(0);
    layoutPresetCard(1);
    closeElement();

    // Row 2
    openElement("PR2");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = growWidth(), .height = growHeight() },
            .childGap = 12,
        },
    });
    layoutPresetCard(2);
    layoutPresetCard(3);
    closeElement();
}

fn layoutPresetCard(index: u32) void {
    const is_active = ui_state.config.active_preset == index;
    const preset = ui_state.config.presets[index];

    openElementI("Card", index);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = growWidth(), .height = growHeight() },
            .padding = pad4(12, 12, 12, 12),
            .childGap = 6,
        },
        .backgroundColor = if (is_active) COLOR_CARD_ACTIVE else COLOR_CARD_BG,
        .cornerRadius = uniformCorner(4),
        .border = .{
            .color = if (is_active) COLOR_GREEN else COLOR_BORDER,
            .width = uniformBorder(if (is_active) 2 else 1),
        },
    });

    textElement(preset.name, 12, COLOR_WHITE);
    if (preset.ip.len > 0) {
        textElement(preset.ip, 10, COLOR_MUTED);
    } else {
        textElement("No server configured", 10, COLOR_MUTED);
    }

    closeElement();
}

// ── Versions Tab ───────────────────────────────────────────────────────

fn layoutVersionsTab() void {
    textElement("Installed Versions", 16, COLOR_WHITE);

    // Check for Updates button
    button("ChkUpd", "Check for Updates", 12, COLOR_GREEN, fitWidth());

    // Update available banner
    if (game_updater.game_update_status == .update_available) {
        openElement("UpdBnr");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{
                .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
                .sizing = .{ .width = growWidth(), .height = fixedH(44) },
                .padding = pad4(12, 12, 0, 0),
                .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
                .childGap = 12,
            },
            .backgroundColor = rgba(0x2A, 0x3A, 0x1A, 0xDD),
            .cornerRadius = uniformCorner(6),
            .border = .{ .color = COLOR_GREEN, .width = uniformBorder(1) },
        });

        textElement("A new game version is available!", 12, COLOR_WHITE);

        // Spacer
        openElement("UBSp");
        c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = growWidth() } } });
        closeElement();

        // Download button
        button("DlBtn", "Download Update", 11, COLOR_GREEN, fitWidth());

        closeElement(); // UpdBnr
    }

    // Download progress bar
    if (game_updater.game_update_status == .downloading) {
        const progress = game_updater.game_download_progress;
        const fraction: f32 = if (progress.total_bytes > 0)
            @as(f32, @floatFromInt(progress.bytes_received)) / @as(f32, @floatFromInt(progress.total_bytes))
        else blk: {
            // Indeterminate: animate a subtle pulse
            break :blk 0.0;
        };

        // Status text
        if (progress.is_extracting) {
            textElement("Extracting...", 10, COLOR_MUTED);
        } else {
            const mb_received = @as(f64, @floatFromInt(progress.bytes_received)) / (1024.0 * 1024.0);
            if (progress.total_bytes > 0) {
                const mb_total = @as(f64, @floatFromInt(progress.total_bytes)) / (1024.0 * 1024.0);
                const pct = fraction * 100.0;
                const result = std.fmt.bufPrint(&dl_progress_buf, "Downloading... {d:.1} / {d:.1} MB ({d:.0}%)", .{ mb_received, mb_total, pct }) catch "Downloading...";
                dl_progress_len = result.len;
            } else {
                const result = std.fmt.bufPrint(&dl_progress_buf, "Downloading... {d:.1} MB", .{mb_received}) catch "Downloading...";
                dl_progress_len = result.len;
            }
            textElement(dl_progress_buf[0..dl_progress_len], 10, COLOR_MUTED);
        }

        // Track
        openElement("PrgT");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{ .sizing = .{ .width = growWidth(), .height = fixedH(22) } },
            .backgroundColor = COLOR_PROGRESS_TRACK,
            .cornerRadius = uniformCorner(6),
        });

        // Fill
        const fill_pct = if (fraction > 0.01) fraction else 0.01;
        openElement("PrgF");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{ .sizing = .{ .width = percentW(fill_pct), .height = growHeight() } },
            .backgroundColor = COLOR_GREEN,
            .cornerRadius = uniformCorner(6),
        });
        closeElement();

        closeElement(); // PrgT
    }

    // Done message
    if (game_updater.game_download_progress.done) {
        textElement("Update installed successfully!", 12, COLOR_GREEN);
    }

    // Version list
    openElement("VerL");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = growSize(),
            .childGap = 4,
            .padding = pad4(0, 0, 8, 8),
        },
        .clip = .{ .vertical = true, .horizontal = false, .childOffset = c.Clay_GetScrollOffset() },
    });
    if (game_updater.installed_version_count == 0) {
        textElement("No versions installed", 12, COLOR_MUTED);
    } else {
        for (0..game_updater.installed_version_count) |i| {
            openElementI("Ver", @intCast(i));
            c.Clay__ConfigureOpenElement(.{
                .layout = .{
                    .sizing = .{ .width = growWidth(), .height = fixedH(28) },
                    .padding = pad4(8, 8, 0, 0),
                    .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
                },
                .backgroundColor = COLOR_CARD_BG,
                .cornerRadius = uniformCorner(4),
            });
            textElement(game_updater.getInstalledVersionName(i), 12, COLOR_WHITE);
            closeElement();
        }
    }
    closeElement();
}

// ── Settings Tab ───────────────────────────────────────────────────────

fn layoutSettingsTab() void {
    textElement("SAVES FOLDER", 10, COLOR_MUTED);

    // Saves path row
    openElement("SvRow");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = growWidth() },
            .childGap = 8,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });

    const is_active = ui_state.active_field == .saves_path;
    // Path display
    openElement("InputBase");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = growWidth(), .height = fixedH(32) },
            .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = COLOR_INPUT_BG,
        .cornerRadius = uniformCorner(4),
        .border = .{ .color = if (is_active) COLOR_GREEN else COLOR_INPUT_BORDER, .width = uniformBorder(1) },
    });

    var text_to_render: []const u8 = "";
    if (is_active) {
        text_to_render = ui_state.saves_buf[0..ui_state.saves_len];
    } else {
        text_to_render = ui_state.config.saves_path;
    }

    if (text_to_render.len > 0) {
        textElement(text_to_render, 12, COLOR_WHITE);
    } else if (is_active) {
        textElement("_", 12, COLOR_WHITE);
    }
    closeElement();

    // Change button
    button("ChBtn", "Change", 10, COLOR_GREEN, fitWidth());

    closeElement(); // SvRow

    // Spacer
    openElement("Sp1");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .height = fixedH(16) } } });
    closeElement();

    // Wine section (Linux only)
    if (comptime builtin.os.tag == .linux) {
        textElement("WINE", 10, COLOR_MUTED);

        openElement("WineR");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{
                .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
                .sizing = .{ .width = growWidth() },
                .childGap = 12,
                .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            },
        });

        if (launcher_mod.wine_version) |wv| {
            textElement(wv, 12, COLOR_WHITE);
        } else {
            textElement("Wine not found", 12, COLOR_RED);
        }

        // Reset Wine button
        button("RstW", "Reset Wine Prefix", 10, COLOR_GREEN, fitWidth());

        closeElement(); // WineR

        openElement("Sp2");
        c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .height = fixedH(16) } } });
        closeElement();
    }

    // Launcher section
    textElement("LAUNCHER", 10, COLOR_MUTED);

    openElement("LaunchR");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = growWidth() },
            .childGap = 12,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });

    textElement(updater.getShortCommit(), 12, COLOR_WHITE);

    // Check for updates button (launcher)
    button("ChkLU", "Check for Update", 10, COLOR_GREEN, fitWidth());

    closeElement(); // LaunchR
}

// ── Bottom Bar ─────────────────────────────────────────────────────────

fn layoutBottomBar() void {
    openElement("BBar");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = growWidth(), .height = fixedH(80) },
            .padding = pad4(12, 12, 12, 12),
            .childGap = 8,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = COLOR_BOTTOM_BG,
        .border = .{ .color = COLOR_BORDER, .width = .{ .left = 0, .right = 0, .top = 1, .bottom = 0, .betweenChildren = 0 } },
    });

    // Folder button
    openElement("FldBtn");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = fixedW(36), .height = fixedH(36) },
            .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });
    imageElement("Logo", ui_state.logo_texture, 36, 36);
    closeElement();

    // Input fields
    layoutInputField("Profile", 120, .preset_name);
    layoutInputField("Username", 140, .username);
    layoutInputField("IP", 140, .ip);
    layoutInputField("Port", 80, .port);

    // Spacer
    openElement("BSp1");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = growWidth() } } });
    closeElement();

    // Spacer
    openElement("BSp2");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = growWidth() } } });
    closeElement();

    // LAUNCH buttons (Stacked)
    const launch_bg = switch (launcher_mod.game_status) {
        .not_running => COLOR_GREEN,
        .running => COLOR_GRAY,
        .initializing_wine => COLOR_YELLOW,
    };

    openElement("LaunchContainer");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = fitWidth(), .height = growHeight() },
            .childGap = 2,
        },
    });

    // Singleplayer Button
    button("Singleplayer", "START SINGLEPLAYER", 12, launch_bg, growWidth());

    // Multiplayer Button
    button("Multiplayer", "START MULTIPLAYER", 12, launch_bg, growWidth());

    closeElement(); // LaunchContainer

    closeElement(); // BBar
}

fn layoutInputField(label: []const u8, width: f32, field: ActiveField) void {
    openElement(label);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = fixedW(width) },
            .childGap = 2,
        },
    });

    textElement(label, 10, COLOR_MUTED);

    const is_active = ui_state.active_field == field;
    const border_color = if (is_active) COLOR_GREEN else COLOR_INPUT_BORDER;

    var inp_id_buf: [64]u8 = undefined;
    const inp_id = std.fmt.bufPrint(&inp_id_buf, "Inp_{s}", .{label}) catch "Inp_";

    c.Clay__OpenElementWithId(clayId(inp_id));
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = growWidth(), .height = fixedH(28) },
            .padding = pad4(6, 6, 0, 0),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = COLOR_INPUT_BG,
        .border = .{ .color = border_color, .width = uniformBorder(1) },
    });

    // Render text
    var text_to_render: []const u8 = "";
    if (is_active) {
        text_to_render = switch (field) {
            .username => ui_state.username_buf[0..ui_state.username_len],
            .ip => ui_state.ip_buf[0..ui_state.ip_len],
            .port => ui_state.port_buf[0..ui_state.port_len],
            .saves_path => ui_state.saves_buf[0..ui_state.saves_len],
            .preset_name => ui_state.preset_name_buf[0..ui_state.preset_name_len],
            .none => "",
        };
    } else {
        const p = ui_state.config.active_preset;
        text_to_render = switch (field) {
            .username => ui_state.config.presets[p].username,
            .ip => ui_state.config.presets[p].ip,
            .port => ui_state.config.presets[p].port,
            .saves_path => ui_state.config.saves_path,
            .preset_name => ui_state.config.presets[p].name,
            .none => "",
        };
    }

    // Check if it's empty, possibly display a cursor if active
    if (text_to_render.len > 0) {
        textElement(text_to_render, 12, COLOR_WHITE);
    } else if (is_active) {
        textElement("_", 12, COLOR_WHITE);
    }

    closeElement(); // Inp

    closeElement();
}

// ── Click Handling ─────────────────────────────────────────────────────

pub fn handleClick() void {
    // Check sidebar tab clicks
    if (c.Clay_PointerOver(clayId("PLAY"))) {
        ui_state.active_tab = .play;
    } else if (c.Clay_PointerOver(clayId("VERSIONS"))) {
        ui_state.active_tab = .versions;
    } else if (c.Clay_PointerOver(clayId("SETTINGS"))) {
        ui_state.active_tab = .settings;
    }

    // Check preset card clicks
    for (0..4) |i| {
        if (c.Clay_PointerOver(clayIdI("Card", @intCast(i)))) {
            ui_state.config.active_preset = @intCast(i);
        }
    }

    if (c.Clay_PointerOver(clayId("Singleplayer"))) {
        commitActiveField();
        ui_state.active_field = .none;
        launcher_mod.launch(std.heap.page_allocator, ui_state.config, false) catch |err| {
            std.debug.print("Failed to launch singleplayer: {}\n", .{err});
        };
    } else if (c.Clay_PointerOver(clayId("Multiplayer"))) {
        commitActiveField();
        ui_state.active_field = .none;
        launcher_mod.launch(std.heap.page_allocator, ui_state.config, true) catch |err| {
            std.debug.print("Failed to launch multiplayer: {}\n", .{err});
        };
    } else if (c.Clay_PointerOver(clayId("ChkUpd"))) {
        game_updater.checkForGameUpdate(std.heap.page_allocator) catch |err| {
            std.debug.print("Failed to check game update: {}\n", .{err});
        };
    } else if (c.Clay_PointerOver(clayId("DlBtn"))) {
        // Don't start another download if already downloading
        if (game_updater.game_update_status != .downloading) {
            const thread = std.Thread.spawn(.{}, struct {
                fn run() void {
                    game_updater.downloadGame(std.heap.page_allocator) catch |err| {
                        std.debug.print("Failed to download game: {}\n", .{err});
                        game_updater.game_update_status = .err;
                    };
                }
            }.run, .{}) catch |err| {
                std.debug.print("Failed to spawn download thread: {}\n", .{err});
                return;
            };
            thread.detach();
        }
    } else if (c.Clay_PointerOver(clayId("ChkLU"))) {
        updater.checkForLauncherUpdate(std.heap.page_allocator) catch |err| {
            std.debug.print("Failed to check launcher update: {}\n", .{err});
        };
    } else if (c.Clay_PointerOver(clayId("ChBtn"))) {
        std.debug.print("TODO: Implement file picker for saves path\n", .{});
    } else if (c.Clay_PointerOver(clayId("Inp_Username"))) {
        commitActiveField();
        ui_state.config.active_preset = ui_state.config.active_preset; // force save logic placeholder just in case
        ui_state.active_field = .username;
        ui_state.syncFromConfig();
    } else if (c.Clay_PointerOver(clayId("Inp_IP"))) {
        commitActiveField();
        ui_state.active_field = .ip;
        ui_state.syncFromConfig();
    } else if (c.Clay_PointerOver(clayId("Inp_Port"))) {
        commitActiveField();
        ui_state.active_field = .port;
        ui_state.syncFromConfig();
    } else if (c.Clay_PointerOver(clayId("Inp_SavesPath"))) {
        commitActiveField();
        ui_state.active_field = .saves_path;
        ui_state.syncFromConfig();
    } else if (c.Clay_PointerOver(clayId("Inp_Profile"))) {
        commitActiveField();
        ui_state.active_field = .preset_name;
        ui_state.syncFromConfig();
    } else {
        // Clicked somewhere else, unfocus
        commitActiveField();
        ui_state.active_field = .none;
    }

    if (comptime builtin.os.tag == .linux) {
        if (c.Clay_PointerOver(clayId("RstW"))) {
            launcher_mod.resetWinePrefix(std.heap.page_allocator) catch |err| {
                std.debug.print("Failed to reset wine prefix: {}\n", .{err});
            };
        }
    }
}
