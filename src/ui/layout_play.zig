const std = @import("std");
const c = @import("../c_imports.zig").c;
const h = @import("helpers.zig");
const clr = @import("colors.zig");
const config_mod = @import("../config.zig");
const logger = @import("../logger.zig");
const launcher_mod = @import("../launcher.zig");

pub fn layoutPlayTab(ui_state: anytype) void {
    h.textElement("Profiles", h.FONT_SIZE_HEADER, clr.COLOR_WHITE);

    h.openElement("PrsCont");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = h.growSize(),
            .childGap = 4,
            .padding = h.pad4(0, 0, 8, 8),
        },
        .clip = .{ .vertical = true, .horizontal = false, .childOffset = c.Clay_GetScrollOffset() },
    });

    for (0..ui_state.config.presets.len) |i| {
        layoutPresetRow(@intCast(i), ui_state);
    }

    h.button("AddPrsBtn", "Add Profile", h.FONT_SIZE_NORMAL, clr.COLOR_GREEN, h.fitWidth());

    h.closeElement(); // PrsCont
}

fn layoutPresetRow(index: u32, ui_state: anytype) void {
    const is_active = ui_state.config.active_preset == index;
    const can_delete = is_active and ui_state.config.presets.len > 1;
    const preset = ui_state.config.presets[index];

    h.openElementI("Row", index);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
            .sizing = .{ .width = h.growWidth(), .height = h.fixedH(36) },
            .padding = h.pad4(12, 0, 0, 0),
            .childGap = 12,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = if (is_active) clr.COLOR_CARD_ACTIVE else clr.COLOR_CARD_BG,
        .cornerRadius = h.uniformCorner(4),
        .border = if (is_active) .{
            .color = clr.COLOR_GREEN,
            .width = .{ .left = 3, .right = 0, .top = 0, .bottom = 0, .betweenChildren = 0 },
        } else std.mem.zeroes(c.Clay_BorderElementConfig),
    });

    h.textElement(preset.name, h.FONT_SIZE_NORMAL, clr.COLOR_WHITE);

    if (preset.ip.len > 0) {
        h.textElement(preset.ip, h.FONT_SIZE_SMALL, clr.COLOR_MUTED);
    } else {
        h.textElement("Localhost", h.FONT_SIZE_SMALL, clr.COLOR_MUTED);
    }

    // Spacer
    h.openElementI("RSp", index);
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = h.growWidth() } } });
    h.closeElement();

    if (can_delete) {
        h.openElementI("DelBtn", index);
        c.Clay__ConfigureOpenElement(.{
            .layout = .{
                .sizing = .{ .width = h.fitWidth(), .height = h.fitHeight() },
                .padding = .{ .left = 16, .right = 16, .top = 6, .bottom = 6 },
                .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_CENTER },
            },
            .backgroundColor = clr.COLOR_RED,
            .cornerRadius = h.uniformCorner(4),
        });
        c.Clay__OpenTextElement(h.clayStr("Delete"), c.Clay__StoreTextElementConfig(.{
            .fontSize = h.FONT_SIZE_SMALL,
            .textColor = clr.COLOR_WHITE,
            .fontId = h.FONT_ID,
        }));
        h.closeElement();
    }

    h.closeElement(); // Row
}
