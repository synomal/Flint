const std = @import("std");
const builtin = @import("builtin");
const safe_fs = @import("safe_fs.zig");

/// Launcher self-update status
pub const LauncherUpdateStatus = enum {
    not_checked,
    checking,
    up_to_date,
    update_available,
    downloading,
    err,
};

pub var launcher_update_status: LauncherUpdateStatus = .not_checked;

// Embedded at compile time from commit.txt written by build.zig
pub const current_commit = std.mem.trimRight(u8, @embedFile("commit.txt"), "\n\r ");

const LAUNCHER_API_URL = "https://api.github.com/repos/YOUR_REPO/releases/tags/nightly";

/// Get the short commit SHA for display
pub fn getShortCommit() []const u8 {
    if (current_commit.len >= 7) return current_commit[0..7];
    return current_commit;
}

/// Check for launcher updates via GitHub nightly release
pub fn checkForLauncherUpdate(allocator: std.mem.Allocator) !void {
    launcher_update_status = .checking;

    var bundle = std.crypto.Certificate.Bundle{};
    bundle.rescan(allocator) catch {};

    var client = std.http.Client{ .allocator = allocator, .ca_bundle = bundle };
    defer client.deinit();

    const uri = try std.Uri.parse(LAUNCHER_API_URL);
    var req = client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "Flint/1.0" },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "Accept-Encoding", .value = "identity" },
        },
    }) catch |err| {
        std.debug.print("updater request err: {}\n", .{err});
        launcher_update_status = .err;
        return;
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        std.debug.print("updater sendBodiless err: {}\n", .{err});
        launcher_update_status = .err;
        return;
    };

    var server_header_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&server_header_buffer) catch |err| {
        std.debug.print("updater receiveHead err: {}\n", .{err});
        launcher_update_status = .err;
        return;
    };

    if (response.head.status != .ok) {
        std.debug.print("updater status not ok: {}\n", .{response.head.status});
        launcher_update_status = .err;
        return;
    }

    var reader = response.reader(&.{});
    const body = reader.allocRemaining(allocator, .unlimited) catch {
        launcher_update_status = .err;
        return;
    };
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        launcher_update_status = .err;
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        launcher_update_status = .err;
        return;
    }

    const commitish = root.object.get("target_commitish") orelse {
        launcher_update_status = .err;
        return;
    };
    if (commitish != .string) {
        launcher_update_status = .err;
        return;
    }

    if (std.mem.eql(u8, current_commit, commitish.string)) {
        launcher_update_status = .up_to_date;
    } else {
        launcher_update_status = .update_available;
    }
}

/// Delete leftover launcher.old on startup
pub fn cleanupOldLauncher() void {
    const self_path = std.fs.selfExePathAlloc(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(self_path);

    const dir = std.fs.path.dirname(self_path) orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_path = std.fmt.bufPrint(&buf, "{s}/launcher.old", .{dir}) catch return;

    // Retry delete up to 3 times with 100ms sleep
    for (0..3) |_| {
        std.fs.deleteFileAbsolute(old_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            },
        };
        return;
    }
}

/// Download and apply launcher update
pub fn downloadAndApplyUpdate(allocator: std.mem.Allocator) !void {
    launcher_update_status = .downloading;

    // Find the right asset for current platform
    var bundle = std.crypto.Certificate.Bundle{};
    bundle.rescan(allocator) catch {};

    var client = std.http.Client{ .allocator = allocator, .ca_bundle = bundle };
    defer client.deinit();

    const uri = try std.Uri.parse(LAUNCHER_API_URL);
    var req = client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "Flint/1.0" },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "Accept-Encoding", .value = "identity" },
        },
    }) catch {
        launcher_update_status = .err;
        return;
    };
    defer req.deinit();

    req.sendBodiless() catch {
        launcher_update_status = .err;
        return;
    };

    var server_header_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&server_header_buffer) catch {
        launcher_update_status = .err;
        return;
    };

    if (response.head.status != .ok) {
        launcher_update_status = .err;
        return;
    }

    var reader = response.reader(&.{});
    const body = reader.allocRemaining(allocator, .unlimited) catch {
        launcher_update_status = .err;
        return;
    };
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        launcher_update_status = .err;
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        launcher_update_status = .err;
        return;
    }

    const assets = root.object.get("assets") orelse {
        launcher_update_status = .err;
        return;
    };
    if (assets != .array) {
        launcher_update_status = .err;
        return;
    }

    // Find platform binary
    const platform_str = if (comptime builtin.os.tag == .windows) "windows" else "linux";
    var download_url: ?[]const u8 = null;

    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const name = asset.object.get("name") orelse continue;
        if (name != .string) continue;

        if (std.mem.indexOf(u8, name.string, platform_str) != null) {
            const url = asset.object.get("browser_download_url") orelse continue;
            if (url == .string) {
                download_url = try allocator.dupe(u8, url.string);
                break;
            }
        }
    }

    const url = download_url orelse {
        launcher_update_status = .err;
        return;
    };
    defer allocator.free(url);

    // Download to launcher.new
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse return;

    var new_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_path = try std.fmt.bufPrint(&new_buf, "{s}/launcher.new", .{self_dir});
    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&old_buf, "{s}/launcher.old", .{self_dir});

    // Download
    const dl_uri = try std.Uri.parse(url);
    var dl_req = client.request(.GET, dl_uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "Flint/1.0" },
            .{ .name = "Accept-Encoding", .value = "identity" },
        },
    }) catch {
        launcher_update_status = .err;
        return;
    };
    defer dl_req.deinit();

    dl_req.sendBodiless() catch {
        launcher_update_status = .err;
        return;
    };

    var dl_header_buf: [8192]u8 = undefined;
    _ = dl_req.receiveHead(&dl_header_buf) catch {
        launcher_update_status = .err;
        return;
    };

    const out_file = try std.fs.createFileAbsolute(new_path, .{});
    defer out_file.close();

    var dl_reader = dl_req.reader(&.{});
    var buf2: [8192]u8 = undefined;
    while (true) {
        const n = dl_reader.read(&buf2) catch break;
        if (n == 0) break;
        try out_file.writeAll(buf2[0..n]);
    }

    // Make executable (Linux)
    if (comptime builtin.os.tag == .linux) {
        const new_file = try std.fs.openFileAbsolute(new_path, .{});
        defer new_file.close();
        try new_file.chmod(0o755);
    }

    // Rename current -> old
    std.fs.renameAbsolute(self_path, old_path) catch {};

    // Rename new -> current
    try std.fs.renameAbsolute(new_path, self_path);

    // Spawn new launcher
    var child = std.process.Child.init(
        &.{self_path},
        allocator,
    );
    try child.spawn();

    // Exit current process
    std.process.exit(0);
}
