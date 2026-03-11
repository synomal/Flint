const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c_imports.zig").c;
const h = @import("helpers.zig");
const clr = @import("colors.zig");
const state = @import("state.zig");
const launcher_mod = @import("../launcher.zig");
const updater = @import("../updater.zig");
const renderer_mod = @import("../renderer.zig");

pub fn layoutSettingsTab(ui_state: anytype) void {
    h.textElement("Saves Folder", h.FONT_SIZE_SMALL, clr.COLOR_MUTED);

    h.openElement("SvRow");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = h.growWidth() },
            .childGap = 8,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });

    layoutInputField("", "SavesPath", 400, .saves_path, ui_state);
    h.button("ChBtn", "Change", h.FONT_SIZE_SMALL, clr.COLOR_GREEN, h.fitWidth());

    h.closeElement(); // SvRow

    h.openElement("Sp1");
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .height = h.fixedH(16) } } });
    h.closeElement();

    // Wine section (Linux only)
    if (comptime builtin.os.tag == .linux) {
        h.textElement("Wine", h.FONT_SIZE_SMALL, clr.COLOR_MUTED);

        h.openElement("WineR");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{
                .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
                .sizing = .{ .width = h.growWidth() },
                .childGap = 12,
                .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            },
        });

        if (launcher_mod.wine_version) |wv| {
            h.textElement(wv, h.FONT_SIZE_NORMAL, clr.COLOR_WHITE);
        } else {
            h.textElement("Wine not found", h.FONT_SIZE_NORMAL, clr.COLOR_RED);
        }

        h.button("RstW", "Reset Wine Prefix", h.FONT_SIZE_SMALL, clr.COLOR_GREEN, h.fitWidth());

        h.closeElement(); // WineR

        h.openElement("Sp2");
        c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .height = h.fixedH(16) } } });
        h.closeElement();
    }

    // Launcher section
    h.textElement("Launcher", h.FONT_SIZE_SMALL, clr.COLOR_MUTED);

    h.openElement("LaunchR");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = h.growWidth() },
            .childGap = 12,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });

    h.textElement(updater.getVersion(), h.FONT_SIZE_NORMAL, clr.COLOR_WHITE);
    // Redundant button removed as requested. Check Versions tab for updates.

    h.closeElement(); // LaunchR
}

/// Shared input field widget used by settings and bottom bar
pub fn layoutInputField(label: []const u8, comp_id: []const u8, width: f32, field: state.ActiveField, ui_state: anytype) void {
    h.openElement(comp_id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = .{ .width = h.fixedW(width) },
            .childGap = 2,
        },
    });

    if (label.len > 0) h.textElement(label, h.FONT_SIZE_SMALL, clr.COLOR_MUTED);

    const is_active = ui_state.active_field == field;
    const border_color = if (is_active) clr.COLOR_GREEN else clr.COLOR_INPUT_BORDER;

    const base_id = h.clayStr(comp_id);
    const inp_id = c.Clay__HashStringWithOffset(base_id, 1, 0);

    c.Clay__OpenElementWithId(inp_id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = h.growWidth(), .height = h.fixedH(28) },
            .padding = h.pad4(6, 6, 0, 0),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = clr.COLOR_INPUT_BG,
        .border = .{ .color = border_color, .width = h.uniformBorder(if (is_active) 2 else 1) },
    });

    const field_idx = @intFromEnum(field);
    const x_offset = -ui_state.scroll_offsets[field_idx];

    const clip_id = c.Clay__HashStringWithOffset(base_id, 2, 0);
    c.Clay__OpenElementWithId(clip_id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{ .sizing = .{ .width = h.fixedW(width - 12), .height = h.fixedH(20) } },
        .clip = .{ .horizontal = true, .vertical = false, .childOffset = .{ .x = x_offset, .y = 0 } },
    });

    const text_to_render: []const u8 = if (is_active) switch (field) {
        .username => ui_state.username_buf[0..ui_state.username_len],
        .ip => ui_state.ip_buf[0..ui_state.ip_len],
        .port => ui_state.port_buf[0..ui_state.port_len],
        .saves_path => ui_state.saves_buf[0..ui_state.saves_len],
        .preset_name => ui_state.preset_name_buf[0..ui_state.preset_name_len],
        .none => "",
    } else blk: {
        const p = ui_state.config.active_preset;
        break :blk switch (field) {
            .username => ui_state.config.presets[p].username,
            .ip => ui_state.config.presets[p].ip,
            .port => ui_state.config.presets[p].port,
            .saves_path => ui_state.config.saves_path,
            .preset_name => ui_state.config.presets[p].name,
            .none => "",
        };
    };

    // Update horizontal scroll to keep cursor visible
    if (is_active) {
        const cursor_x = renderer_mod.measureTextWidth(ui_state.font, text_to_render[0..@min(ui_state.cursor_pos, text_to_render.len)], h.FONT_SIZE_NORMAL);
        const box_width: f32 = width - 12;
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
            .sizing = .{ .width = h.fitWidth() },
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
    });

    if (before.len > 0) h.textElement(before, h.FONT_SIZE_NORMAL, clr.COLOR_WHITE);

    // Blinking cursor
    if (is_active) {
        const show_cursor = (c.SDL_GetTicks() % 1000 < 500);
        const cursor_id = c.Clay__HashStringWithOffset(base_id, 4, 0);
        c.Clay__OpenElementWithId(cursor_id);
        c.Clay__ConfigureOpenElement(.{
            .layout = .{ .sizing = .{ .width = h.fixedW(2), .height = h.fixedH(16) } },
            .backgroundColor = if (show_cursor) clr.COLOR_WHITE else std.mem.zeroes(c.Clay_Color),
        });
        h.closeElement();
    }

    if (after.len > 0) h.textElement(after, h.FONT_SIZE_NORMAL, clr.COLOR_WHITE);

    if (text_to_render.len == 0 and !is_active) {
        h.textElement("_", h.FONT_SIZE_NORMAL, clr.COLOR_MUTED);
    }

    h.closeElement(); // TextRow
    h.closeElement(); // Clip
    h.closeElement(); // Inp_...
    h.closeElement(); // label container
}
