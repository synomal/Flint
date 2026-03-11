const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c_imports.zig").c;
const h = @import("helpers.zig");
const state = @import("state.zig");
const config_mod = @import("../config.zig");
const game_updater = @import("../game_updater.zig");
const launcher_mod = @import("../launcher.zig");
const updater = @import("../updater.zig");
const logger = @import("../logger.zig");

pub fn handleClick() void {
    // Sidebar tab clicks
    if (c.Clay_PointerOver(h.clayId("Play"))) {
        state.ui_state.active_tab = .play;
        game_updater.game_download_progress.done = false;
    } else if (c.Clay_PointerOver(h.clayId("Versions"))) {
        state.ui_state.active_tab = .versions;
        game_updater.game_download_progress.done = false;
    } else if (c.Clay_PointerOver(h.clayId("Settings"))) {
        state.ui_state.active_tab = .settings;
        game_updater.game_download_progress.done = false;
    }

    // Launch buttons
    if (c.Clay_PointerOver(h.clayId("Singleplayer"))) {
        if (launcher_mod.game_status != .not_running) return;
        state.commitActiveField();
        state.ui_state.active_field = .none;
        launcher_mod.launch(std.heap.page_allocator, state.ui_state.config, false) catch |err| {
            logger.err("Failed to launch singleplayer: {}", .{err});
        };
    } else if (c.Clay_PointerOver(h.clayId("Multiplayer"))) {
        if (launcher_mod.game_status != .not_running) return;
        state.commitActiveField();
        state.ui_state.active_field = .none;
        launcher_mod.launch(std.heap.page_allocator, state.ui_state.config, true) catch |err| {
            logger.err("Failed to launch multiplayer: {}", .{err});
        };
    } else if (c.Clay_PointerOver(h.clayId("AddPrsBtn"))) {
        state.commitActiveField();
        state.ui_state.active_field = .none;
        addPreset() catch |err| {
            logger.err("Failed to add preset: {}", .{err});
        };
    } else {
        handleDynamicClicks();
    }

    if (comptime builtin.os.tag == .linux) {
        if (c.Clay_PointerOver(h.clayId("RstW"))) {
            launcher_mod.resetWinePrefix(std.heap.page_allocator) catch |err| {
                logger.err("Failed to reset wine prefix: {}", .{err});
            };
        }
    }

    // Launcher update check
    if (c.Clay_PointerOver(h.clayId("ChkLU"))) {
        if (updater.launcher_update_status != .checking) {
            _ = std.Thread.spawn(.{}, struct {
                fn run() void {
                    updater.checkForLauncherUpdate(std.heap.page_allocator) catch |err| {
                        logger.err("launcher update check thread err: {}", .{err});
                    };
                }
            }.run, .{}) catch |err| {
                logger.err("failed to spawn launcher check thread: {}", .{err});
            };
        }
    }

    // Launcher update install
    if (c.Clay_PointerOver(h.clayId("LUpd"))) {
        if (updater.launcher_update_status == .update_available) {
            _ = std.Thread.spawn(.{}, struct {
                fn run() void {
                    updater.downloadAndApplyUpdate(std.heap.page_allocator) catch |err| {
                        logger.err("launcher update thread err: {}", .{err});
                        updater.launcher_update_status = .err;
                    };
                }
            }.run, .{}) catch |err| {
                logger.err("failed to spawn launcher update thread: {}", .{err});
            };
        }
    }

    // First-run installer
    if (c.Clay_PointerOver(h.clayId("InstallBtn"))) {
        _ = std.Thread.spawn(.{}, struct {
            fn run() void {
                updater.installSelf(std.heap.page_allocator) catch |err| {
                    logger.err("installSelf err: {}", .{err});
                };
            }
        }.run, .{}) catch |err| {
            logger.err("failed to spawn install thread: {}", .{err});
        };
    }

    if (c.Clay_PointerOver(h.clayId("InstDismiss"))) {
        state.ui_state.show_installer = false;
    }
}

fn handleDynamicClicks() void {
    // Preset row/delete clicks
    var row_clicked = false;
    for (0..state.ui_state.config.presets.len) |i| {
        if (c.Clay_PointerOver(h.clayIdI("DelBtn", @intCast(i)))) {
            state.commitActiveField();
            state.ui_state.active_field = .none;
            deletePreset(@intCast(i)) catch |err| {
                logger.err("Failed to delete preset: {}", .{err});
            };
            row_clicked = true;
            break;
        }
        if (c.Clay_PointerOver(h.clayIdI("Row", @intCast(i)))) {
            state.commitActiveField();
            state.ui_state.active_field = .none;
            state.ui_state.config.active_preset = @intCast(i);
            state.ui_state.syncFromConfig();
            row_clicked = true;
            break;
        }
    }
    if (row_clicked) return;

    // Versions tab buttons
    if (c.Clay_PointerOver(h.clayId("ChkUpd"))) {
        if (game_updater.game_update_status != .downloading) {
            game_updater.checkForGameUpdate(std.heap.page_allocator) catch |err| {
                logger.err("Failed to check game update: {}", .{err});
            };
        }
    } else if (c.Clay_PointerOver(h.clayId("DlBtn"))) {
        if (game_updater.game_update_status != .downloading) {
            const thread = std.Thread.spawn(.{}, struct {
                fn run() void {
                    game_updater.downloadGame(std.heap.page_allocator) catch |err| {
                        logger.err("Failed to download game: {}", .{err});
                        game_updater.game_update_status = .err;
                    };
                }
            }.run, .{}) catch |err| {
                logger.err("Failed to spawn download thread: {}", .{err});
                return;
            };
            thread.detach();
        }
    } else if (c.Clay_PointerOver(h.clayId("ChkLU"))) {
        updater.checkForLauncherUpdate(std.heap.page_allocator) catch |err| {
            logger.err("Failed to check launcher update: {}", .{err});
        };
    } else if (c.Clay_PointerOver(h.clayId("ChBtn"))) {
        logger.info("TODO: Implement file picker for saves path", .{});
    } else {
        handleInputFieldClicks();
    }
}

fn handleInputFieldClicks() void {
    // Focus handling for each input field
    const fields = .{
        .{ "Username", state.ActiveField.username },
        .{ "IP", state.ActiveField.ip },
        .{ "Port", state.ActiveField.port },
        .{ "SavesPath", state.ActiveField.saves_path },
        .{ "Profile", state.ActiveField.preset_name },
    };

    inline for (fields) |pair| {
        const comp_id = pair[0];
        const field = pair[1];
        if (c.Clay_PointerOver(c.Clay__HashStringWithOffset(h.clayStr(comp_id), 1, 0))) {
            state.commitActiveField();
            state.ui_state.active_field = field;
            state.ui_state.syncFromConfig();
            state.ui_state.cursor_pos = switch (field) {
                .username => state.ui_state.username_len,
                .ip => state.ui_state.ip_len,
                .port => state.ui_state.port_len,
                .saves_path => state.ui_state.saves_len,
                .preset_name => state.ui_state.preset_name_len,
                .none => 0,
            };
            return;
        }
    }

    // Clicked somewhere else — unfocus
    state.commitActiveField();
    state.ui_state.active_field = .none;
}

fn addPreset() !void {
    const old_presets = state.ui_state.config.presets;
    const new_presets = try state.ui_state.allocator.alloc(config_mod.Preset, old_presets.len + 1);

    for (old_presets, 0..) |p, i| new_presets[i] = p;

    var name_buf: [32]u8 = undefined;
    const p_name = try std.fmt.bufPrint(&name_buf, "New Profile {d}", .{new_presets.len});
    new_presets[old_presets.len] = .{
        .name = try state.ui_state.allocator.dupe(u8, p_name),
        .port = "25565",
    };

    state.ui_state.config.presets = new_presets;
    state.ui_state.config.active_preset = @intCast(old_presets.len);
    state.ui_state.syncFromConfig();
}

fn deletePreset(index: u32) !void {
    const old_presets = state.ui_state.config.presets;
    if (old_presets.len <= 1) return;

    const new_presets = try state.ui_state.allocator.alloc(config_mod.Preset, old_presets.len - 1);

    var new_i: usize = 0;
    for (old_presets, 0..) |p, i| {
        if (i == index) continue;
        new_presets[new_i] = p;
        new_i += 1;
    }

    state.ui_state.config.presets = new_presets;

    if (state.ui_state.config.active_preset >= new_presets.len) {
        state.ui_state.config.active_preset = @intCast(new_presets.len - 1);
    }

    state.ui_state.syncFromConfig();
}
