const std = @import("std");
const c = @import("../c_imports.zig").c;
const h = @import("helpers.zig");
const clr = @import("colors.zig");
const game_updater = @import("../game_updater.zig");
const updater = @import("../updater.zig");

// Module-local buffer for progress text (must live until Clay renders)
var dl_progress_buf: [96]u8 = undefined;
var dl_progress_len: usize = 0;

pub fn layoutVersionsTab() void {
    h.textElement("Installed Versions", h.FONT_SIZE_HEADER, clr.COLOR_WHITE);

    h.button("ChkUpd", "Check for Game Update", h.FONT_SIZE_NORMAL, clr.COLOR_GREEN, h.fitWidth());
    h.button("ChkLU", "Check for Launcher Update", h.FONT_SIZE_NORMAL, clr.COLOR_BLUE, h.fitWidth());

    // Launcher update available banner
    if (updater.launcher_update_status == .update_available) {
        h.openElement("LUpdBnr");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{
                .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
                .sizing = .{ .width = h.growWidth(), .height = h.fixedH(44) },
                .padding = h.pad4(12, 12, 0, 0),
                .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
                .childGap = 12,
            },
            .backgroundColor = clr.rgba(0x1A, 0x2A, 0x3A, 0xDD),
            .cornerRadius = h.uniformCorner(6),
            .border = .{ .color = clr.COLOR_BLUE, .width = h.uniformBorder(1) },
        });

        h.textElement("A new launcher version is available!", h.FONT_SIZE_NORMAL, clr.COLOR_WHITE);

        h.openElement("LUSp");
        c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = h.growWidth() } } });
        h.closeElement();

        h.button("LUpd", "Update Launcher", h.FONT_SIZE_SMALL, clr.COLOR_BLUE, h.fitWidth());
        h.closeElement(); // LUpdBnr
    }

    // Launcher downloading status
    if (updater.launcher_update_status == .downloading) {
        h.textElement("Downloading launcher update...", h.FONT_SIZE_NORMAL, clr.COLOR_MUTED);
    }

    // Game update available banner
    if (game_updater.game_update_status == .update_available) {
        h.openElement("UpdBnr");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{
                .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
                .sizing = .{ .width = h.growWidth(), .height = h.fixedH(44) },
                .padding = h.pad4(12, 12, 0, 0),
                .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
                .childGap = 12,
            },
            .backgroundColor = clr.rgba(0x2A, 0x3A, 0x1A, 0xDD),
            .cornerRadius = h.uniformCorner(6),
            .border = .{ .color = clr.COLOR_GREEN, .width = h.uniformBorder(1) },
        });

        h.textElement("A new game version is available!", h.FONT_SIZE_NORMAL, clr.COLOR_WHITE);

        h.openElement("UBSp");
        c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = h.growWidth() } } });
        h.closeElement();

        h.button("DlBtn", "Download Update", h.FONT_SIZE_SMALL, clr.COLOR_GREEN, h.fitWidth());

        h.closeElement(); // UpdBnr
    }

    // Download progress bar
    if (game_updater.game_update_status == .downloading) {
        const progress = game_updater.game_download_progress;
        const fraction: f32 = if (progress.total_bytes > 0)
            @as(f32, @floatFromInt(progress.bytes_received)) / @as(f32, @floatFromInt(progress.total_bytes))
        else
            0.0;

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
        h.textElement(dl_progress_buf[0..dl_progress_len], h.FONT_SIZE_SMALL, clr.COLOR_MUTED);

        // Progress track
        h.openElement("PrgT");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{ .sizing = .{ .width = h.growWidth(), .height = h.fixedH(22) } },
            .backgroundColor = clr.COLOR_PROGRESS_TRACK,
            .cornerRadius = h.uniformCorner(6),
        });

        const fill_pct = if (fraction > 0.01) fraction else 0.01;
        h.openElement("PrgF");
        c.Clay__ConfigureOpenElement(.{
            .layout = .{ .sizing = .{ .width = h.percentW(fill_pct), .height = h.growHeight() } },
            .backgroundColor = clr.COLOR_GREEN,
            .cornerRadius = h.uniformCorner(6),
        });
        h.closeElement();

        h.closeElement(); // PrgT
    }

    if (game_updater.game_download_progress.done) {
        h.textElement("Update installed successfully!", h.FONT_SIZE_NORMAL, clr.COLOR_REAL_GREEN);
    }

    // Version list
    h.openElement("VerL");
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
            .sizing = h.growSize(),
            .childGap = 4,
            .padding = h.pad4(0, 0, 8, 8),
        },
        .clip = .{ .vertical = true, .horizontal = false, .childOffset = c.Clay_GetScrollOffset() },
    });
    if (game_updater.installed_version_count == 0) {
        h.textElement("No versions installed", h.FONT_SIZE_NORMAL, clr.COLOR_MUTED);
    } else {
        for (0..game_updater.installed_version_count) |i| {
            h.openElementI("Ver", @intCast(i));
            c.Clay__ConfigureOpenElement(.{
                .layout = .{
                    .sizing = .{ .width = h.growWidth(), .height = h.fixedH(28) },
                    .padding = h.pad4(8, 8, 0, 0),
                    .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
                },
                .backgroundColor = clr.COLOR_CARD_BG,
                .cornerRadius = h.uniformCorner(4),
            });
            h.textElement(game_updater.getInstalledVersionName(i), h.FONT_SIZE_NORMAL, clr.COLOR_WHITE);
            h.closeElement();
        }
    }
    h.closeElement(); // VerL
}
