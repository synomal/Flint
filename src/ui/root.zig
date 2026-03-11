const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c_imports.zig").c;

const h = @import("helpers.zig");
const clr = @import("colors.zig");
const state = @import("state.zig");
const layout_header = @import("layout_header.zig");
const layout_play = @import("layout_play.zig");
const layout_versions = @import("layout_versions.zig");
const layout_settings = @import("layout_settings.zig");
const launcher_mod = @import("../launcher.zig");
const updater = @import("../updater.zig");

/// Root layout entry point — produces the full Clay render command array.
/// Called once per frame from main.zig.
pub fn layoutRoot() c.Clay_RenderCommandArray {
    h.text_id_counter = 0; // Reset text ID counter each frame
    c.Clay_BeginLayout();

    h.openElement("Root");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = h.growSize(),
        },
    });

    layout_header.layoutHeader(&state.ui_state);
    layoutMiddle();
    layoutBottomBar();

    h.closeElement(); // Root

    if (state.ui_state.show_installer) layoutInstallerOverlay();

    return c.Clay_EndLayout();
}

fn layoutInstallerOverlay() void {
    // Full-screen darkened backdrop (floating)
    h.openElement("InstallerBdp");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = h.growSize(),
            .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = clr.rgba(0x00, 0x00, 0x00, 0xCC),
        .floating = .{
            .attachTo = c.CLAY_ATTACH_TO_ROOT,
            .zIndex = 100,
        },
    });

    // Centered card
    h.openElement("InstallerCard");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = h.fixedW(400), .height = h.fitHeight() },
            .padding = h.pad4(32, 32, 24, 24),
            .childGap = 16,
            .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER },
        },
        .backgroundColor = clr.COLOR_PANEL_BG,
        .cornerRadius = h.uniformCorner(12),
        .border = .{ .color = clr.COLOR_BORDER, .width = h.uniformBorder(1) },
    });

    h.textElement("Install Flint", h.FONT_SIZE_HEADER, clr.COLOR_WHITE);
    h.textElement(
        "Flint is not running from its installed location.",
        h.FONT_SIZE_NORMAL,
        clr.COLOR_MUTED,
    );
    h.textElement(
        "Click Install to copy it to ~/.flintlauncher and relaunch.",
        h.FONT_SIZE_NORMAL,
        clr.COLOR_MUTED,
    );

    // Buttons row
    h.openElement("InstBtnRow");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = h.growWidth(), .height = h.fitHeight() },
            .childGap = 12,
        },
    });

    h.button("InstallBtn", "Install", h.FONT_SIZE_NORMAL, clr.COLOR_GREEN, h.growWidth());
    h.button("InstDismiss", "Run anyway", h.FONT_SIZE_NORMAL, clr.COLOR_GRAY, h.growWidth());

    h.closeElement(); // InstBtnRow
    h.closeElement(); // InstallerCard
    h.closeElement(); // InstallerBdp
}

fn layoutMiddle() void {
    h.openElement("Mid");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = h.growSize(),
        },
    });

    layoutSidebar();
    layoutContent();

    h.closeElement(); // Mid
}

fn layoutSidebar() void {
    h.openElement("Sidebar");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = h.fixedW(160), .height = h.growHeight() },
        },
        .backgroundColor = clr.COLOR_SIDEBAR_BG,
    });

    layoutTab("Play", .play);
    layoutTab("Versions", .versions);
    layoutTab("Settings", .settings);

    h.closeElement(); // Sidebar
}

fn layoutTab(label: []const u8, tab: state.Tab) void {
    const is_active = state.ui_state.active_tab == tab;

    h.openElement(label);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = h.growWidth(), .height = h.fixedH(36) },
            .padding = h.pad4(16, 12, 0, 0),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = if (is_active) clr.COLOR_TAB_ACTIVE else clr.COLOR_TRANSPARENT,
        .border = if (is_active) .{
            .color = clr.COLOR_GREEN,
            .width = .{ .left = 3, .right = 0, .top = 0, .bottom = 0, .betweenChildren = 0 },
        } else std.mem.zeroes(c.Clay_BorderElementConfig),
    });

    h.textElement(label, h.FONT_SIZE_NORMAL, if (is_active) clr.COLOR_WHITE else clr.COLOR_MUTED);
    h.closeElement();
}

fn layoutContent() void {
    h.openElement("Content");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = h.growSize(),
            .padding = h.pad4(16, 16, 16, 16),
            .childGap = 12,
        },
        .backgroundColor = clr.COLOR_PANEL_BG,
    });

    switch (state.ui_state.active_tab) {
        .play => layout_play.layoutPlayTab(&state.ui_state),
        .versions => layout_versions.layoutVersionsTab(),
        .settings => layout_settings.layoutSettingsTab(&state.ui_state),
    }

    h.closeElement(); // Content
}

fn layoutBottomBar() void {
    h.openElement("BBar");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = h.growWidth(), .height = h.fixedH(80) },
            .padding = h.pad4(12, 12, 12, 12),
            .childGap = 8,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = clr.COLOR_BOTTOM_BG,
        .border = .{ .color = clr.COLOR_BORDER, .width = .{ .left = 0, .right = 0, .top = 1, .bottom = 0, .betweenChildren = 0 } },
    });

    // Logo icon button
    h.openElement("FldBtn");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = h.fixedW(36), .height = h.fixedH(36) },
            .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });
    h.imageElement("Logo", state.ui_state.logo_texture, 36, 36);
    h.closeElement();

    // Input fields
    layout_settings.layoutInputField("Profile", "Profile", 120, .preset_name, &state.ui_state);
    layout_settings.layoutInputField("Username", "Username", 140, .username, &state.ui_state);
    layout_settings.layoutInputField("IP", "IP", 140, .ip, &state.ui_state);
    layout_settings.layoutInputField("Port", "Port", 80, .port, &state.ui_state);

    // Spacers
    h.openElement("BSp1");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = h.growWidth() } } });
    h.closeElement();
    h.openElement("BSp2");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = h.growWidth() } } });
    h.closeElement();

    // Launch buttons
    const launch_bg = switch (launcher_mod.game_status) {
        .not_running => clr.COLOR_GREEN,
        .running => clr.COLOR_GRAY,
        .initializing_wine => clr.COLOR_YELLOW,
    };

    h.openElement("LaunchContainer");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = h.fitWidth(), .height = h.growHeight() },
            .childGap = 2,
        },
    });

    h.button("Singleplayer", "Start Singleplayer", h.FONT_SIZE_NORMAL, launch_bg, h.growWidth());
    h.button("Multiplayer", "Start Multiplayer", h.FONT_SIZE_NORMAL, launch_bg, h.growWidth());

    h.closeElement(); // LaunchContainer
    h.closeElement(); // BBar
}
