const std = @import("std");
const builtin = @import("builtin");
const safe_fs = @import("safe_fs.zig");
const logger = @import("logger.zig");

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
    const win64_path = try std.fmt.bufPrint(&win64_buf, "{s}{s}Windows64", .{ version_dir, std.fs.path.sep_str });
    logger.info("Ensuring Windows64 dir: {s}", .{win64_path});
    safe_fs.ensureDir(win64_path) catch {};

    var gamehdd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const gamehdd_path = try std.fmt.bufPrint(&gamehdd_buf, "{s}{s}Windows64{s}GameHDD", .{ version_dir, std.fs.path.sep_str, std.fs.path.sep_str });

    logger.info("Checking for GameHDD at: {s}", .{gamehdd_path});
    std.fs.accessAbsolute(gamehdd_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            logger.info("GameHDD not found, creating link to: {s}", .{saves_path});
            // Does not exist — create symlink/junction
            try createLink(allocator, gamehdd_path, saves_path);
            return;
        },
        else => {
            logger.err("Error accessing GameHDD: {}", .{err});
            return err;
        },
    };

    // Check if it's a symlink
    var link_target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_target = std.fs.readLinkAbsolute(gamehdd_path, &link_target_buf) catch |err| switch (err) {
        error.NotLink => {
            // It's a real directory — move contents to saves_path, then replace with link
            try moveContentsToSaves(allocator, gamehdd_path, saves_path);
            try std.fs.deleteTreeAbsolute(gamehdd_path);
            try createLink(allocator, gamehdd_path, saves_path);
            return;
        },
        else => {
            // error.Unexpected happens on Windows directory junctions, or it might be another link read err
            logger.warn("Could not read link (usually normal for Windows junctions): {}", .{err});
            try std.fs.deleteTreeAbsolute(gamehdd_path);
            try createLink(allocator, gamehdd_path, saves_path);
            return;
        },
    };

    // It is a symlink — check if correct target
    // On Windows, the link target might have a \??\ prefix.
    if (std.mem.eql(u8, link_target, saves_path) or std.mem.endsWith(u8, link_target, saves_path)) {
        // Correct target, do nothing
        return;
    }

    // Wrong target — delete and re-create
    // Use deleteTreeAbsolute in case it is a directory junction instead of a file
    try std.fs.deleteTreeAbsolute(gamehdd_path);
    try createLink(allocator, gamehdd_path, saves_path);
}

fn createLink(allocator: std.mem.Allocator, link_path: []const u8, target: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        // Windows: use directory junction via mklink /j
        // mklink expects backslashes for paths
        const link_win = try allocator.dupe(u8, link_path);
        defer allocator.free(link_win);
        for (link_win) |*c_ptr| if (c_ptr.* == '/') {
            c_ptr.* = '\\';
        };

        const target_win = try allocator.dupe(u8, target);
        defer allocator.free(target_win);
        for (target_win) |*c_ptr| if (c_ptr.* == '/') {
            c_ptr.* = '\\';
        };

        logger.info("Windows: mklink /j \"{s}\" \"{s}\"", .{ link_win, target_win });

        // cmd /c mklink /j <link> <target>
        const argv = &[_][]const u8{ "cmd", "/c", "mklink", "/j", link_win, target_win };
        var child = std.process.Child.init(argv, allocator);
        child.create_no_window = true;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        var success = false;

        if (child.spawnAndWait()) |term| {
            switch (term) {
                .Exited => |code| if (code == 0) {
                    success = true;
                },
                else => {},
            }
        } else |_| {}

        if (!success) {
            logger.warn("Windows mklink failed, attempting to remove existing directory and retry...", .{});

            // Try to force remove it using cmd /c rmdir /q /s
            const rm_argv = &[_][]const u8{ "cmd", "/c", "rmdir", "/q", "/s", link_win };
            var rm_child = std.process.Child.init(rm_argv, allocator);
            rm_child.create_no_window = true;
            rm_child.stdout_behavior = .Ignore;
            rm_child.stderr_behavior = .Ignore;
            _ = rm_child.spawnAndWait() catch {};

            // Retry mklink
            var retry_child = std.process.Child.init(argv, allocator);
            retry_child.create_no_window = true;
            retry_child.stdout_behavior = .Ignore;
            retry_child.stderr_behavior = .Ignore;

            if (retry_child.spawnAndWait()) |retry_term| {
                switch (retry_term) {
                    .Exited => |code| if (code == 0) {
                        success = true;
                    },
                    else => {},
                }
            } else |_| {}
        }

        if (!success) {
            logger.err("Failed to create directory junction for GameHDD", .{});
            return error.SystemResources;
        }
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
        // Skip Index files (they are game assets, not saves)
        if (std.mem.startsWith(u8, entry.name, "Index")) continue;

        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_path = try std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src_dir, entry.name });
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst_path = try std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ saves_path, entry.name });

        // Check if dest already exists
        std.fs.accessAbsolute(dst_path, .{}) catch {
            // Doesn't exist — rename/move
            std.fs.renameAbsolute(src_path, dst_path) catch {
                // Cross-device move — would need copy, skip for now
                logger.warn("Could not move {s} to saves (cross-device?)", .{entry.name});
            };
            continue;
        };
        // Already exists in saves, skip (don't overwrite user saves)
        _ = allocator;
    }
}

/// Spawn the game process with preset connection info
/// Exe args: Minecraft.Client.exe -name <username> [-ip <ip> -port <port>]
pub fn spawnGame(allocator: std.mem.Allocator, version_dir: []const u8, saves_path: []const u8, preset: anytype, multiplayer: bool) !void {
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

    if (multiplayer) {
        if (preset.ip.len > 0) {
            try argv.append(allocator, "-ip");
            try argv.append(allocator, preset.ip);
            logger.info("Arg: -ip {s}", .{preset.ip});
        }
        if (preset.port.len > 0) {
            try argv.append(allocator, "-port");
            try argv.append(allocator, preset.port);
            logger.info("Arg: -port {s}", .{preset.port});
        }
    }

    // Minecraft.Client.exe is in the version root
    const exe_path = try std.fs.path.join(allocator, &.{ version_dir, "Minecraft.Client.exe" });
    defer allocator.free(exe_path);
    argv.items[0] = exe_path;

    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*m| m.deinit();

    if (comptime builtin.os.tag == .linux) {
        // Native Linux: Use Wine
        const wineprefix = try safe_fs.getWinePrefixDir(allocator);
        defer allocator.free(wineprefix);

        env_map = try std.process.getEnvMap(allocator);
        try env_map.?.put("WINEPREFIX", wineprefix);
        try env_map.?.put("WINEDEBUG", "-all"); // Suppress wine spam

        // Prepend wine command
        try argv.insert(allocator, 0, "wine");
    }

    logger.print("[INFO] Final argv: ", .{});
    for (argv.items) |arg| {
        logger.print("'{s}' ", .{arg});
    }
    logger.print("\n", .{});
    logger.info("CWD: {s}", .{version_dir});

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = version_dir;

    if (comptime builtin.os.tag == .windows) {
        child.create_no_window = true;
    } else if (comptime builtin.os.tag == .linux) {
        if (env_map) |*m| child.env_map = m;
    }

    try child.spawn();
    game_child = child;

    game_status = .running;
}

/// Convenience wrapper for the UI
pub fn launch(allocator: std.mem.Allocator, config: @import("config.zig").Config, multiplayer: bool) !void {
    if (game_status == .running) return;

    if (try findLatestVersion(allocator)) |version_dir| {
        defer allocator.free(version_dir);
        try spawnGame(allocator, version_dir, config.saves_path, config.presets[config.active_preset], multiplayer);
    } else {
        logger.err("No game version found to launch.", .{});
    }
}

/// Check if game process is still running (called each frame)
pub fn pollGameProcess() void {
    if (game_child) |*child| {
        if (comptime builtin.os.tag == .windows) {
            // Non-blocking check on Windows
            // In Zig 0.15.2, child.id is the process HANDLE on Windows.
            const result = std.os.windows.kernel32.WaitForSingleObject(child.id, 0);
            if (result == std.os.windows.WAIT_OBJECT_0) {
                // Determine exit code and cleanup using standard library's wait()
                // wait() handle closure and reaping correctly.
                _ = child.wait() catch |err| {
                    logger.err("Error waiting for game process: {}", .{err});
                };

                game_status = .not_running;
                game_child = null;
            }
        } else {
            // Non-blocking wait on POSIX (Linux/Wine)
            const wait_res = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (wait_res.pid != 0) {
                // Process has exited or errored (pid == -1).
                // We've already reaped it, so just update state.
                const s = wait_res.status;
                if (std.posix.W.IFEXITED(s)) {
                    child.term = .{ .Exited = std.posix.W.EXITSTATUS(s) };
                } else if (std.posix.W.IFSIGNALED(s)) {
                    child.term = .{ .Signal = std.posix.W.TERMSIG(s) };
                } else if (std.posix.W.IFSTOPPED(s)) {
                    child.term = .{ .Stopped = std.posix.W.STOPSIG(s) };
                } else {
                    child.term = .{ .Unknown = s };
                }
                game_status = .not_running;
                game_child = null;
            }
        }
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
    defer if (stdout.len > 0) allocator.free(stdout);
    const result = child.wait() catch {
        wine_status = .not_found;
        return;
    };

    if (result.Exited == 0 and stdout.len > 0) {
        // Trim and store an independent copy so wine_version owns its memory
        const trimmed = std.mem.trimRight(u8, stdout, "\n\r ");
        wine_version = try allocator.dupe(u8, trimmed);
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
    defer allocator.free(wineprefix);

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
    defer allocator.free(wineprefix);

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
