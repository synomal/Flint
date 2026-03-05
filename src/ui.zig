const std = @import("std");
const builtin = @import("builtin");
const c = @import("c_imports.zig").c;

const config_mod = @import("config.zig");
const game_updater = @import("game_updater.zig");
const updater = @import("updater.zig");
const launcher_mod = @import("launcher.zig");
const renderer_mod = @import("renderer.zig");

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
    allocator: std.mem.Allocator = undefined,

    // Branding textures (set from main.zig)
    logo_texture: ?*c.SDL_Texture = null,
    text_logo_texture: ?*c.SDL_Texture = null,
    font: ?*c.TTF_Font = null,

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

    cursor_pos: usize = 0,
    scroll_offsets: [6]f32 = [_]f32{0} ** 6,

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

        // Set cursor to end of the active field
        self.cursor_pos = switch (self.active_field) {
            .username => self.username_len,
            .ip => self.ip_len,
            .port => self.port_len,
            .saves_path => self.saves_len,
            .preset_name => self.preset_name_len,
            .none => 0,
        };
    }
};

pub var ui_state = UiState{};

/// Handle a text input character from SDL
pub fn handleTextInput(text: []const u8) void {
    switch (ui_state.active_field) {
        .username => insertAtCursor(&ui_state.username_buf, &ui_state.username_len, text, 16),
        .ip => insertAtCursor(&ui_state.ip_buf, &ui_state.ip_len, text, 15),
        .port => insertAtCursor(&ui_state.port_buf, &ui_state.port_len, text, 5),
        .saves_path => insertAtCursor(&ui_state.saves_buf, &ui_state.saves_len, text, 255),
        .preset_name => insertAtCursor(&ui_state.preset_name_buf, &ui_state.preset_name_len, text, 64),
        .none => {},
    }
}

/// Handle backspace key
pub fn handleBackspace() void {
    if (ui_state.cursor_pos == 0) return;

    const len = getActiveLen() orelse return;
    const buf = getActiveBuf() orelse return;

    if (len.* > 0) {
        const move_len = len.* - ui_state.cursor_pos;
        if (move_len > 0) {
            std.mem.copyForwards(u8, buf[ui_state.cursor_pos - 1 .. len.* - 1], buf[ui_state.cursor_pos..len.*]);
        }
        len.* -= 1;
        ui_state.cursor_pos -= 1;
    }
}

/// Handle delete key
pub fn handleDelete() void {
    const len = getActiveLen() orelse return;
    const buf = getActiveBuf() orelse return;

    if (ui_state.cursor_pos < len.*) {
        const move_len = len.* - ui_state.cursor_pos - 1;
        if (move_len > 0) {
            std.mem.copyForwards(u8, buf[ui_state.cursor_pos .. len.* - 1], buf[ui_state.cursor_pos + 1 .. len.*]);
        }
        len.* -= 1;
    }
}

pub fn handleLeftArrow() void {
    if (ui_state.cursor_pos > 0) ui_state.cursor_pos -= 1;
}

pub fn handleRightArrow() void {
    const len = getActiveLen() orelse return;
    if (ui_state.cursor_pos < len.*) ui_state.cursor_pos += 1;
}

fn getActiveLen() ?*usize {
    return switch (ui_state.active_field) {
        .username => &ui_state.username_len,
        .ip => &ui_state.ip_len,
        .port => &ui_state.port_len,
        .saves_path => &ui_state.saves_len,
        .preset_name => &ui_state.preset_name_len,
        .none => null,
    };
}

fn getActiveBuf() ?[]u8 {
    return switch (ui_state.active_field) {
        .username => &ui_state.username_buf,
        .ip => &ui_state.ip_buf,
        .port => &ui_state.port_buf,
        .saves_path => &ui_state.saves_buf,
        .preset_name => &ui_state.preset_name_buf,
        .none => null,
    };
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

fn insertAtCursor(buf: []u8, len: *usize, text: []const u8, max_len: usize) void {
    for (text) |ch| {
        if (len.* < @min(buf.len, max_len)) {
            const move_len = len.* - ui_state.cursor_pos;
            if (move_len > 0) {
                std.mem.copyBackwards(u8, buf[ui_state.cursor_pos + 1 .. len.* + 1], buf[ui_state.cursor_pos..len.*]);
            }
            buf[ui_state.cursor_pos] = ch;
            len.* += 1;
            ui_state.cursor_pos += 1;
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
const FONT_SIZE_SMALL: u16 = 10;
const FONT_SIZE_NORMAL: u16 = 12;
const FONT_SIZE_HEADER: u16 = 16;

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
    c.Clay__OpenElementWithId(c.Clay__HashStringWithOffset(clayStr(s), text_id_counter, 0));
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = fitWidth(), .height = fitHeight() } } });

    c.Clay__OpenTextElement(clayStr(s), c.Clay__StoreTextElementConfig(.{
        .fontId = FONT_ID,
        .fontSize = font_size,
        .textColor = color,
    }));

    closeElement(); // Close textElement container
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
    imageElement("TextLogo", ui_state.text_logo_texture, 115, 28);

    // Spacer
    openElement("HSp1");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = growWidth(), .height = fixedH(0) } } });
    closeElement();

    // Game version
    if (ui_state.game_version_len > 0) {
        textElement(ui_state.game_version_display[0..ui_state.game_version_len], FONT_SIZE_SMALL, COLOR_MUTED);
    } else {
        textElement("Not installed", FONT_SIZE_SMALL, COLOR_MUTED);
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
    button(name, text, FONT_SIZE_SMALL, color, fitWidth());
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

    layoutTab("Play", .play);
    layoutTab("Versions", .versions);
    layoutTab("Settings", .settings);

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

    textElement(label, FONT_SIZE_NORMAL, if (is_active) COLOR_WHITE else COLOR_MUTED);
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
    textElement("Profiles", FONT_SIZE_HEADER, COLOR_WHITE);

    // Scrollable container for presets
    openElement("PrsCont");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = growSize(),
            .childGap = 4,
            .padding = pad4(0, 0, 8, 8),
        },
        .clip = .{ .vertical = true, .horizontal = false, .childOffset = c.Clay_GetScrollOffset() },
    });

    for (0..ui_state.config.presets.len) |i| {
        layoutPresetRow(@intCast(i));
    }

    // Add Preset Button - standard text button
    button("AddPrsBtn", "Add Profile", FONT_SIZE_NORMAL, COLOR_GREEN, fitWidth());

    closeElement(); // PrsCont
}

fn layoutPresetRow(index: u32) void {
    const is_active = ui_state.config.active_preset == index;
    const can_delete = is_active and ui_state.config.presets.len > 1;
    const preset = ui_state.config.presets[index];

    openElementI("Row", index);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = growWidth(), .height = fixedH(36) },
            .padding = pad4(12, 0, 0, 0),
            .childGap = 12,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = if (is_active) COLOR_CARD_ACTIVE else COLOR_CARD_BG,
        .cornerRadius = uniformCorner(4),
        .border = if (is_active) .{
            .color = COLOR_GREEN,
            .width = .{ .left = 3, .right = 0, .top = 0, .bottom = 0, .betweenChildren = 0 },
        } else std.mem.zeroes(c.Clay_BorderElementConfig),
    });

    textElement(preset.name, FONT_SIZE_NORMAL, COLOR_WHITE);

    if (preset.ip.len > 0) {
        textElement(preset.ip, FONT_SIZE_SMALL, COLOR_MUTED);
    } else {
        textElement("Localhost", FONT_SIZE_SMALL, COLOR_MUTED);
    }

    // Spacer
    openElementI("RSp", index);
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = growWidth() } } });
    closeElement();

    if (can_delete) {
        openElementI("DelBtn", index);
        c.Clay__ConfigureOpenElement(.{
            .layout = .{
                .sizing = .{ .width = fitWidth(), .height = fitHeight() },
                .padding = .{ .left = 16, .right = 16, .top = 6, .bottom = 6 },
                .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_CENTER },
            },
            .backgroundColor = COLOR_RED,
            .cornerRadius = uniformCorner(4),
        });
        c.Clay__OpenTextElement(clayStr("Delete"), c.Clay__StoreTextElementConfig(.{
            .fontSize = FONT_SIZE_SMALL,
            .textColor = COLOR_WHITE,
            .fontId = FONT_ID,
        }));
        closeElement();
    }

    closeElement(); // Row
}

// ── Versions Tab ───────────────────────────────────────────────────────

fn layoutVersionsTab() void {
    textElement("Installed Versions", FONT_SIZE_HEADER, COLOR_WHITE);

    // Check for Updates button
    button("ChkUpd", "Check for Updates", FONT_SIZE_NORMAL, COLOR_GREEN, fitWidth());

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

        textElement("A new game version is available!", FONT_SIZE_NORMAL, COLOR_WHITE);

        // Spacer
        openElement("UBSp");
        c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = growWidth() } } });
        closeElement();

        // Download button
        button("DlBtn", "Download Update", FONT_SIZE_SMALL, COLOR_GREEN, fitWidth());

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
        const action = if (progress.is_extracting) "Extracting..." else "Downloading...";
        const mb_received = @as(f64, @floatFromInt(progress.bytes_received)) / (1024.0 * 1024.0);
        if (progress.total_bytes > 0) {
            const mb_total = @as(f64, @floatFromInt(progress.total_bytes)) / (1024.0 * 1024.0);
            const pct = fraction * 100.0;
            const result = std.fmt.bufPrint(&dl_progress_buf, "{s} {d:.1} / {d:.1} MB ({d:.0}%)", .{ action, mb_received, mb_total, pct }) catch action;
            dl_progress_len = result.len;
        } else {
            const result = std.fmt.bufPrint(&dl_progress_buf, "{s} {d:.1} MB", .{ action, mb_received }) catch action;
            dl_progress_len = result.len;
        }
        textElement(dl_progress_buf[0..dl_progress_len], FONT_SIZE_SMALL, COLOR_MUTED);

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
        textElement("Update installed successfully!", FONT_SIZE_NORMAL, COLOR_GREEN);
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
        textElement("No versions installed", FONT_SIZE_NORMAL, COLOR_MUTED);
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
            textElement(game_updater.getInstalledVersionName(i), FONT_SIZE_NORMAL, COLOR_WHITE);
            closeElement();
        }
    }
    closeElement();
}

// ── Settings Tab ───────────────────────────────────────────────────────

fn layoutSettingsTab() void {
    textElement("Saves Folder", FONT_SIZE_SMALL, COLOR_MUTED);

    // Saves path row
    openElement("SvRow");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = growWidth() },
            .childGap = 8,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });

    // Path display
    layoutInputField("", "SavesPath", 400, .saves_path);

    // Change button
    button("ChBtn", "Change", FONT_SIZE_SMALL, COLOR_GREEN, fitWidth());

    closeElement(); // SvRow

    // Spacer
    openElement("Sp1");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .height = fixedH(16) } } });
    closeElement();

    // Wine section (Linux only)
    if (comptime builtin.os.tag == .linux) {
        textElement("Wine", FONT_SIZE_SMALL, COLOR_MUTED);

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
            textElement(wv, FONT_SIZE_NORMAL, COLOR_WHITE);
        } else {
            textElement("Wine not found", FONT_SIZE_NORMAL, COLOR_RED);
        }

        // Reset Wine button
        button("RstW", "Reset Wine Prefix", FONT_SIZE_SMALL, COLOR_GREEN, fitWidth());

        closeElement(); // WineR

        openElement("Sp2");
        c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .height = fixedH(16) } } });
        closeElement();
    }

    // Launcher section
    textElement("Launcher", FONT_SIZE_SMALL, COLOR_MUTED);

    openElement("LaunchR");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = growWidth() },
            .childGap = 12,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });

    textElement(updater.getShortCommit(), FONT_SIZE_NORMAL, COLOR_WHITE);

    // Check for updates button (launcher)
    button("ChkLU", "Check for Update", FONT_SIZE_SMALL, COLOR_GREEN, fitWidth());

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
    layoutInputField("Profile", "Profile", 120, .preset_name);
    layoutInputField("Username", "Username", 140, .username);
    layoutInputField("IP", "IP", 140, .ip);
    layoutInputField("Port", "Port", 80, .port);

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
    button("Singleplayer", "Start Singleplayer", FONT_SIZE_NORMAL, launch_bg, growWidth());

    // Multiplayer Button
    button("Multiplayer", "Start Multiplayer", FONT_SIZE_NORMAL, launch_bg, growWidth());

    closeElement(); // LaunchContainer

    closeElement(); // BBar
}

fn layoutInputField(label: []const u8, comp_id: []const u8, width: f32, field: ActiveField) void {
    openElement(comp_id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = fixedW(width) },
            .childGap = 2,
        },
    });

    if (label.len > 0) textElement(label, FONT_SIZE_SMALL, COLOR_MUTED);

    const is_active = ui_state.active_field == field;
    const border_color = if (is_active) COLOR_GREEN else COLOR_INPUT_BORDER;

    const base_id = clayStr(comp_id);
    const inp_id = c.Clay__HashStringWithOffset(base_id, 1, 0);

    c.Clay__OpenElementWithId(inp_id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = growWidth(), .height = fixedH(28) },
            .padding = pad4(6, 6, 0, 0),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = COLOR_INPUT_BG,
        .border = .{ .color = border_color, .width = uniformBorder(if (is_active) 2 else 1) },
    });

    const x_offset = -ui_state.scroll_offsets[@intFromEnum(field)];

    // Clipping container
    const clip_id = c.Clay__HashStringWithOffset(base_id, 2, 0);
    c.Clay__OpenElementWithId(clip_id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{ .sizing = .{ .width = fixedW(width - 12), .height = fixedH(20) } },
        .clip = .{ .horizontal = true, .vertical = false, .childOffset = .{ .x = x_offset, .y = 0 } },
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

    const field_idx = @intFromEnum(field);
    if (is_active) {
        const cursor_x = renderer_mod.measureTextWidth(ui_state.font, text_to_render[0..@min(ui_state.cursor_pos, text_to_render.len)], FONT_SIZE_NORMAL);

        // Simple scrolling: keep cursor in view
        const box_width: f32 = width - 12; // approximate visible area
        if (cursor_x - ui_state.scroll_offsets[field_idx] > box_width - 20) {
            ui_state.scroll_offsets[field_idx] = cursor_x - (box_width - 20);
        } else if (cursor_x < ui_state.scroll_offsets[field_idx]) {
            ui_state.scroll_offsets[field_idx] = cursor_x;
        }
    } else {
        ui_state.scroll_offsets[field_idx] = 0;
    }

    const before = text_to_render[0..@min(ui_state.cursor_pos, text_to_render.len)];
    const after = text_to_render[@min(ui_state.cursor_pos, text_to_render.len)..];

    const text_row_id = c.Clay__HashStringWithOffset(base_id, 3, 0);
    c.Clay__OpenElementWithId(text_row_id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = fitWidth() },
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });

    if (before.len > 0) {
        textElement(before, FONT_SIZE_NORMAL, COLOR_WHITE);
    }

    // Cursor (or spacer if blinking off)
    if (is_active) {
        const show_cursor = (c.SDL_GetTicks() % 1000 < 500);
        const cursor_id = c.Clay__HashStringWithOffset(base_id, 4, 0);
        c.Clay__OpenElementWithId(cursor_id);
        c.Clay__ConfigureOpenElement(.{
            .layout = .{
                .sizing = .{ .width = fixedW(2), .height = fixedH(16) },
            },
            .backgroundColor = if (show_cursor) COLOR_WHITE else std.mem.zeroes(c.Clay_Color),
        });
        closeElement();
    }

    if (after.len > 0) {
        textElement(after, FONT_SIZE_NORMAL, COLOR_WHITE);
    }

    if (text_to_render.len == 0 and !is_active) {
        textElement("_", FONT_SIZE_NORMAL, COLOR_MUTED);
    }

    closeElement(); // TextRow
    closeElement(); // Clip
    closeElement(); // Inp_...
    closeElement(); // label
}

// ── Click Handling ─────────────────────────────────────────────────────

pub fn handleClick() void {
    // Check sidebar tab clicks
    if (c.Clay_PointerOver(clayId("Play"))) {
        ui_state.active_tab = .play;
    } else if (c.Clay_PointerOver(clayId("Versions"))) {
        ui_state.active_tab = .versions;
    } else if (c.Clay_PointerOver(clayId("Settings"))) {
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
    } else if (c.Clay_PointerOver(clayId("AddPrsBtn"))) {
        commitActiveField();
        ui_state.active_field = .none;
        addPreset() catch |err| {
            std.debug.print("Failed to add preset: {}\n", .{err});
        };
    } else {
        // Check dynamic rows
        var row_clicked = false;
        for (0..ui_state.config.presets.len) |i| {
            if (c.Clay_PointerOver(clayIdI("DelBtn", @intCast(i)))) {
                commitActiveField();
                ui_state.active_field = .none;
                deletePreset(@intCast(i)) catch |err| {
                    std.debug.print("Failed to delete preset: {}\n", .{err});
                };
                row_clicked = true;
                break;
            }
            if (c.Clay_PointerOver(clayIdI("Row", @intCast(i)))) {
                commitActiveField();
                ui_state.active_field = .none;
                ui_state.config.active_preset = @intCast(i);
                ui_state.syncFromConfig();
                row_clicked = true;
                break;
            }
        }

        if (!row_clicked) {
            if (c.Clay_PointerOver(clayId("ChkUpd"))) {
                // Prevent check while actively downloading
                if (game_updater.game_update_status != .downloading) {
                    game_updater.checkForGameUpdate(std.heap.page_allocator) catch |err| {
                        std.debug.print("Failed to check game update: {}\n", .{err});
                    };
                }
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
            } else if (c.Clay_PointerOver(c.Clay__HashStringWithOffset(clayStr("Username"), 1, 0))) {
                commitActiveField();
                ui_state.active_field = .username;
                ui_state.syncFromConfig();
                ui_state.cursor_pos = ui_state.username_len;
            } else if (c.Clay_PointerOver(c.Clay__HashStringWithOffset(clayStr("IP"), 1, 0))) {
                commitActiveField();
                ui_state.active_field = .ip;
                ui_state.syncFromConfig();
                ui_state.cursor_pos = ui_state.ip_len;
            } else if (c.Clay_PointerOver(c.Clay__HashStringWithOffset(clayStr("Port"), 1, 0))) {
                commitActiveField();
                ui_state.active_field = .port;
                ui_state.syncFromConfig();
                ui_state.cursor_pos = ui_state.port_len;
            } else if (c.Clay_PointerOver(c.Clay__HashStringWithOffset(clayStr("SavesPath"), 1, 0))) {
                commitActiveField();
                ui_state.active_field = .saves_path;
                ui_state.syncFromConfig();
                ui_state.cursor_pos = ui_state.saves_len;
            } else if (c.Clay_PointerOver(c.Clay__HashStringWithOffset(clayStr("Profile"), 1, 0))) {
                commitActiveField();
                ui_state.active_field = .preset_name;
                ui_state.syncFromConfig();
                ui_state.cursor_pos = ui_state.preset_name_len;
            } else {
                // Clicked somewhere else, unfocus
                commitActiveField();
                ui_state.active_field = .none;
            }
        }
    }

    if (comptime builtin.os.tag == .linux) {
        if (c.Clay_PointerOver(clayId("RstW"))) {
            launcher_mod.resetWinePrefix(std.heap.page_allocator) catch |err| {
                std.debug.print("Failed to reset wine prefix: {}\n", .{err});
            };
        }
    }
}

fn addPreset() !void {
    const old_presets = ui_state.config.presets;
    const new_presets = try ui_state.allocator.alloc(config_mod.Preset, old_presets.len + 1);

    for (old_presets, 0..) |p, i| {
        new_presets[i] = p;
    }

    // New default preset
    var name_buf: [32]u8 = undefined;
    const p_name = try std.fmt.bufPrint(&name_buf, "New Profile {d}", .{new_presets.len});
    new_presets[old_presets.len] = .{
        .name = try ui_state.allocator.dupe(u8, p_name),
        .port = "25565",
    };

    ui_state.config.presets = new_presets;
    ui_state.config.active_preset = @intCast(old_presets.len);
    ui_state.syncFromConfig();
}

fn deletePreset(index: u32) !void {
    const old_presets = ui_state.config.presets;
    if (old_presets.len <= 1) return;

    const new_presets = try ui_state.allocator.alloc(config_mod.Preset, old_presets.len - 1);

    var new_i: usize = 0;
    for (old_presets, 0..) |p, i| {
        if (i == index) continue;
        new_presets[new_i] = p;
        new_i += 1;
    }

    ui_state.config.presets = new_presets;

    // Adjust active_preset
    if (ui_state.config.active_preset >= new_presets.len) {
        ui_state.config.active_preset = @intCast(new_presets.len - 1);
    }

    ui_state.syncFromConfig();
}
