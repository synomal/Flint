const std = @import("std");
const builtin = @import("builtin");
const safe_fs = @import("safe_fs.zig");

/// Wine status for UI display
pub const WineStatus = enum {
    not_checked,
    available,
    not_found,
    initializing_prefix,
};

/// Game process status
pub const GameStatus = enum {
    not_running,
    running,
    initializing_wine,
};

pub var wine_version: ?[]const u8 = null;
pub var wine_status: WineStatus = .not_checked;
pub var game_status: GameStatus = .not_running;
pub var game_child: ?std.process.Child = null;

/// Ensure the GameHDD symlink/junction points to saves_path.
/// Runs before every launch.
pub fn ensureSavesLink(allocator: std.mem.Allocator, version_dir: []const u8, saves_path: []const u8) !void {
    // Ensure Windows64 directory exists at the root of the install
    var win64_buf: [std.fs.max_path_bytes]u8 = undefined;
    const win64_path = try std.fmt.bufPrint(&win64_buf, "{s}/Windows64", .{version_dir});
    safe_fs.ensureDir(win64_path) catch {};

    var gamehdd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const gamehdd_path = try std.fmt.bufPrint(&gamehdd_buf, "{s}/Windows64/GameHDD", .{version_dir});

    // Check what exists at GameHDD
    const stat = std.fs.cwd().statFile(gamehdd_path) catch |err| switch (err) {
        error.FileNotFound => {
            // Does not exist — create symlink/junction
            try createLink(gamehdd_path, saves_path);
            return;
        },
        else => return err,
    };
    _ = stat;

    // Check if it's a symlink
    const link_target = std.fs.readLinkAbsolute(gamehdd_path, &gamehdd_buf) catch |err| switch (err) {
        error.NotLink => {
            // It's a real directory — move contents to saves_path, then replace with link
            try moveContentsToSaves(allocator, gamehdd_path, saves_path);
            try std.fs.deleteTreeAbsolute(gamehdd_path);
            try createLink(gamehdd_path, saves_path);
            return;
        },
        else => return err,
    };

    // It is a symlink — check if correct target
    if (std.mem.eql(u8, link_target, saves_path)) {
        // Correct target, do nothing
        return;
    }

    // Wrong target — delete and re-create
    try std.fs.deleteFileAbsolute(gamehdd_path);
    try createLink(gamehdd_path, saves_path);
}

fn createLink(link_path: []const u8, target: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        // Windows: use directory junction via NTFS reparse point
        // For now, use symlink as placeholder — full junction impl requires Win32 API
        try std.fs.symLinkAbsolute(target, link_path, .{ .is_directory = true });
    } else {
        // Linux: standard symlink
        try std.fs.symLinkAbsolute(target, link_path, .{});
    }
}

fn moveContentsToSaves(allocator: std.mem.Allocator, src_dir: []const u8, saves_path: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(src_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_path = try std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src_dir, entry.name });
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst_path = try std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ saves_path, entry.name });

        // Check if dest already exists
        std.fs.accessAbsolute(dst_path, .{}) catch {
            // Doesn't exist — rename/move
            std.fs.renameAbsolute(src_path, dst_path) catch {
                // Cross-device move — would need copy, skip for now
                std.log.warn("Could not move {s} to saves (cross-device?)", .{entry.name});
            };
            continue;
        };
        // Already exists in saves, skip (don't overwrite user saves)
        _ = allocator;
    }
}

/// Spawn the game process with preset connection info
/// Exe args: Minecraft.Client.exe -name <username> -ip <ip> -port <port>
pub fn spawnGame(allocator: std.mem.Allocator, version_dir: []const u8, saves_path: []const u8, preset: anytype) !void {
    // Ensure saves link
    try ensureSavesLink(allocator, version_dir, saves_path);

    // Build argv dynamically based on preset fields
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "Minecraft.Client.exe");

    // Default username if empty
    if (preset.username.len > 0) {
        try argv.append(allocator, "-name");
        try argv.append(allocator, preset.username);
    } else {
        try argv.append(allocator, "-name");
        try argv.append(allocator, "Player");
    }

    if (preset.ip.len > 0) {
        try argv.append(allocator, "-ip");
        try argv.append(allocator, preset.ip);
    }
    if (preset.port.len > 0) {
        try argv.append(allocator, "-port");
        try argv.append(allocator, preset.port);
    }

    if (comptime builtin.os.tag == .linux) {
        // Native Linux: Use Wine
        const wineprefix = try safe_fs.getWinePrefixDir(allocator);
        defer allocator.free(wineprefix);

        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();
        try env_map.put("WINEPREFIX", wineprefix);
        try env_map.put("WINEDEBUG", "-all"); // Suppress wine spam

        // Prepend wine command
        try argv.insert(allocator, 0, "wine");

        std.debug.print("Spawning game with args: ", .{});
        for (argv.items) |arg| {
            std.debug.print("'{s}' ", .{arg});
        }
        std.debug.print("\n", .{});

        var child = std.process.Child.init(argv.items, allocator);
        child.cwd = version_dir;
        child.env_map = &env_map;
        try child.spawn();
        game_child = child;
    } else {
        // Windows: Native execution
        var child = std.process.Child.init(argv.items, allocator);
        child.cwd = version_dir;
        try child.spawn();
        game_child = child;
    }

    game_status = .running;
}

/// Convenience wrapper for the UI
pub fn launch(allocator: std.mem.Allocator, config: @import("config.zig").Config) !void {
    if (game_status == .running) return;

    if (try findLatestVersion(allocator)) |version_dir| {
        defer allocator.free(version_dir);
        try spawnGame(allocator, version_dir, config.saves_path, config.presets[config.active_preset]);
    } else {
        std.debug.print("No game version found to launch.\n", .{});
    }
}

/// Check if game process is still running (called each frame)
pub fn pollGameProcess() void {
    if (game_child) |*child| {
        const result = child.wait() catch {
            game_status = .not_running;
            game_child = null;
            return;
        };
        _ = result;
        game_status = .not_running;
        game_child = null;
    }
}

/// Check if Wine is installed (Linux only)
pub fn checkWine(allocator: std.mem.Allocator) !void {
    if (comptime builtin.os.tag != .linux) return;

    var child = std.process.Child.init(
        &.{ "wine", "--version" },
        allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024) catch "";
    const result = child.wait() catch {
        wine_status = .not_found;
        return;
    };

    if (result.Exited == 0 and stdout.len > 0) {
        // Trim trailing newline
        wine_version = std.mem.trimRight(u8, stdout, "\n\r ");
        wine_status = .available;
    } else {
        wine_status = .not_found;
    }
}

/// Initialize Wine prefix (Linux only, first run)
pub fn initWinePrefix(allocator: std.mem.Allocator) !void {
    if (comptime builtin.os.tag != .linux) return;

    game_status = .initializing_wine;
    wine_status = .initializing_prefix;

    const wineprefix = try safe_fs.getWinePrefixDir(allocator);

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("WINEPREFIX", wineprefix);

    var child = std.process.Child.init(
        &.{ "wineboot", "--init" },
        allocator,
    );
    child.env_map = &env_map;
    try child.spawn();

    _ = child.wait() catch {};

    wine_status = .available;
    game_status = .not_running;
}

/// Reset Wine prefix: delete and re-init
pub fn resetWinePrefix(allocator: std.mem.Allocator) !void {
    if (comptime builtin.os.tag != .linux) return;

    const wineprefix = try safe_fs.getWinePrefixDir(allocator);

    // Delete wineprefix directory directly (NOT through safeDelete — this is the only
    // code path allowed to delete wineprefix)
    std.fs.deleteTreeAbsolute(wineprefix) catch {};

    // Re-init
    try initWinePrefix(allocator);
}

/// Open a folder in the system file manager
pub fn openFolder(allocator: std.mem.Allocator, path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        var child = std.process.Child.init(
            &.{ "explorer.exe", path },
            allocator,
        );
        try child.spawn();
    } else {
        var child = std.process.Child.init(
            &.{ "xdg-open", path },
            allocator,
        );
        try child.spawn();
    }
}

/// Find the latest installed version directory
pub fn findLatestVersion(allocator: std.mem.Allocator) !?[]const u8 {
    const versions_dir = try safe_fs.getVersionsDir(allocator);
    defer allocator.free(versions_dir);

    var dir = std.fs.openDirAbsolute(versions_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var latest: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "nightly-")) {
            if (latest) |l| allocator.free(l);
            latest = try allocator.dupe(u8, entry.name);
        }
    }

    if (latest) |name| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = try std.fmt.bufPrint(&buf, "{s}{s}", .{ versions_dir, name });
        allocator.free(name);
        return try allocator.dupe(u8, full);
    }

    return null;
}
