const std = @import("std");
const c = @import("../c_imports.zig").c;
const h = @import("helpers.zig");
const clr = @import("colors.zig");
const game_updater = @import("../game_updater.zig");
const updater = @import("../updater.zig");

pub fn layoutHeader(ui_state: anytype) void {
    h.openElement("Header");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = h.growWidth(), .height = h.fixedH(36) },
            .padding = h.pad4(12, 12, 0, 0),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            .childGap = 16,
        },
        .backgroundColor = clr.COLOR_HEADER_BG,
    });

    h.imageElement("TextLogo", ui_state.text_logo_texture, 115, 28);

    // Left spacer
    h.openElement("HSp1");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = h.growWidth(), .height = h.fixedH(0) } } });
    h.closeElement();

    // Game version
    if (ui_state.game_version_len > 0) {
        h.textElement(ui_state.game_version_display[0..ui_state.game_version_len], h.FONT_SIZE_SMALL, clr.COLOR_MUTED);
    } else {
        h.textElement("Not installed", h.FONT_SIZE_SMALL, clr.COLOR_MUTED);
    }

    // Right spacer
    h.openElement("HSp2");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = h.growWidth(), .height = h.fixedH(0) } } });
    h.closeElement();

    // Status pills
    layoutPill("GPill", gameStatusText(), gameStatusColor());
    layoutPill("LPill", launcherStatusText(), launcherStatusColor());

    h.closeElement(); // Header
}

fn layoutPill(name: []const u8, text: []const u8, color: c.Clay_Color) void {
    h.button(name, text, h.FONT_SIZE_SMALL, color, h.fitWidth());
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
        .up_to_date => clr.COLOR_GREEN,
        .update_available => clr.COLOR_YELLOW,
        .downloading => clr.COLOR_BLUE,
        .checking, .not_checked => clr.COLOR_GRAY,
        .err => clr.COLOR_RED,
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
        .up_to_date => clr.COLOR_GREEN,
        .update_available => clr.COLOR_YELLOW,
        .downloading => clr.COLOR_BLUE,
        .checking, .not_checked => clr.COLOR_GRAY,
        .err => clr.COLOR_RED,
    };
}
