const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c_imports.zig").c;

const config_mod = @import("../config.zig");

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
    show_installer: bool = false, // true when exe is outside ~/.flintlauncher

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

// ── Input handlers ──────────────────────────────────────────────────────

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
    ui_state.syncFromConfig();
}

/// Write edit buffer contents back to config
pub fn commitActiveField() void {
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
