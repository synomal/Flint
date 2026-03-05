const std = @import("std");
const builtin = @import("builtin");

/// Safe filesystem operations with path validation.
/// All recursive deletes in the codebase MUST go through safeDelete.
pub const SafeFsError = error{
    UnsafePath,
    SavesPathInsideVersionsDir,
};

var base_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var base_dir_len: usize = 0;
var base_dir_initialized: bool = false;

/// Returns the resolved base directory ~/.lcelauncher/
pub fn getBaseDir(allocator: std.mem.Allocator) ![]const u8 {
    if (base_dir_initialized) {
        return base_dir_buf[0..base_dir_len];
    }

    const home = if (comptime builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
            std.process.getEnvVarOwned(allocator, "HOMEPATH") catch // Try HOMEPATH if USERPROFILE is missing
            return error.UnsafePath
    else
        std.process.getEnvVarOwned(allocator, "HOME") catch return error.UnsafePath;
    defer allocator.free(home);

    const sep = std.fs.path.sep_str;
    const path = try std.fmt.bufPrint(&base_dir_buf, "{s}{s}.flintlauncher{s}", .{ home, sep, sep });
    base_dir_len = path.len;
    base_dir_initialized = true;
    return path;
}

/// Returns the versions directory path ~/.lcelauncher/versions/
pub fn getVersionsDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = try getBaseDir(allocator);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{s}versions/", .{base});
    const duped = try allocator.dupe(u8, result);
    return duped;
}

/// Returns the saves directory path ~/.lcelauncher/saves/
pub fn getSavesDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = try getBaseDir(allocator);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{s}saves/", .{base});
    const duped = try allocator.dupe(u8, result);
    return duped;
}

/// Returns the wineprefix directory path ~/.lcelauncher/wineprefix/
pub fn getWinePrefixDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = try getBaseDir(allocator);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{s}wineprefix/", .{base});
    const duped = try allocator.dupe(u8, result);
    return duped;
}

/// Safe delete: validates path starts with ~/.lcelauncher/versions/ before any delete.
/// Returns error.UnsafePath if validation fails.
/// MUST NEVER be called on saves/ or wineprefix/.
pub fn safeDelete(allocator: std.mem.Allocator, path: []const u8) !void {
    const base = try getBaseDir(allocator);

    // Build the versions prefix
    var versions_buf: [std.fs.max_path_bytes]u8 = undefined;
    const versions_prefix = try std.fmt.bufPrint(&versions_buf, "{s}versions/", .{base});

    // Must start with versions path
    if (!std.mem.startsWith(u8, path, versions_prefix)) {
        return SafeFsError.UnsafePath;
    }

    // Must NEVER be the saves directory
    var saves_buf: [std.fs.max_path_bytes]u8 = undefined;
    const saves_prefix = try std.fmt.bufPrint(&saves_buf, "{s}saves", .{base});
    if (std.mem.startsWith(u8, path, saves_prefix)) {
        return SafeFsError.UnsafePath;
    }

    // Must NEVER be the wineprefix directory
    var wine_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wine_prefix = try std.fmt.bufPrint(&wine_buf, "{s}wineprefix", .{base});
    if (std.mem.startsWith(u8, path, wine_prefix)) {
        return SafeFsError.UnsafePath;
    }

    // Perform the actual delete
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    dir.close();

    try std.fs.deleteTreeAbsolute(path);
}

/// Assert that saves_path is NOT inside versions_path
pub fn assertSavesNotInVersions(allocator: std.mem.Allocator, saves_path: []const u8) !void {
    const versions = try getVersionsDir(allocator);
    defer allocator.free(versions);

    if (std.mem.startsWith(u8, saves_path, versions)) {
        return SafeFsError.SavesPathInsideVersionsDir;
    }
}

/// Ensure a directory exists, creating it recursively if needed.
pub fn ensureDir(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try creating parent directories
            if (std.fs.path.dirname(path)) |parent| {
                try ensureDir(parent);
                std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                    error.PathAlreadyExists => {},
                    else => return err2,
                };
            } else {
                return err;
            }
        },
    };
}

/// Ensure the base launcher directories exist
pub fn ensureBaseDirs(allocator: std.mem.Allocator) !void {
    const base = try getBaseDir(allocator);
    try ensureDir(base);

    const saves = try getSavesDir(allocator);
    defer allocator.free(saves);
    try ensureDir(saves);

    const versions = try getVersionsDir(allocator);
    defer allocator.free(versions);
    try ensureDir(versions);

    if (comptime builtin.os.tag == .linux) {
        const wine = try getWinePrefixDir(allocator);
        defer allocator.free(wine);
        // Don't create wineprefix eagerly — created by wineboot --init
    }
}
