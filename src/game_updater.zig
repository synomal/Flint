const std = @import("std");
const safe_fs = @import("safe_fs.zig");

/// Decompress gzip body if detected, otherwise return original.
/// Caller must free the returned slice if it differs from the input.
fn decompressBody(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    if (body.len >= 2 and body[0] == 0x1f and body[1] == 0x8b) {
        var input_reader = std.Io.Reader.fixed(body);
        var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&input_reader, .gzip, &window_buf);
        return decomp.reader.allocRemaining(allocator, .unlimited) catch return error.OutOfMemory;
    }
    return body;
}

/// Download progress info for UI
pub const DownloadProgress = struct {
    bytes_received: u64 = 0,
    total_bytes: u64 = 0,
    is_downloading: bool = false,
    is_extracting: bool = false,
    asset_name: []const u8 = "",
    done: bool = false,
    err: ?[]const u8 = null,
};

/// Update status for UI
pub const UpdateStatus = enum {
    not_checked,
    checking,
    up_to_date,
    update_available,
    downloading,
    err,
};

pub var game_update_status: UpdateStatus = .not_checked;
pub var game_download_progress: DownloadProgress = .{};
pub var available_game_sha: ?[]const u8 = null;

// Cached installed version names for UI display
const MAX_VERSIONS: usize = 16;
var installed_version_bufs: [MAX_VERSIONS][64]u8 = undefined;
var installed_version_lens: [MAX_VERSIONS]usize = [_]usize{0} ** MAX_VERSIONS;
pub var installed_version_count: usize = 0;

pub fn getInstalledVersionName(index: usize) []const u8 {
    return installed_version_bufs[index][0..installed_version_lens[index]];
}

/// Scan the versions directory and cache installed version names
pub fn refreshInstalledVersions(allocator: std.mem.Allocator) void {
    installed_version_count = 0;
    const versions_dir = safe_fs.getVersionsDir(allocator) catch return;
    defer allocator.free(versions_dir);

    var dir = std.fs.openDirAbsolute(versions_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .directory and installed_version_count < MAX_VERSIONS) {
            const name = entry.name;
            if (name.len <= 64) {
                @memcpy(installed_version_bufs[installed_version_count][0..name.len], name);
                installed_version_lens[installed_version_count] = name.len;
                installed_version_count += 1;
            }
        }
    }
}

const GAME_API_URL = "https://api.github.com/repos/smartcmd/MinecraftConsoles/releases/tags/nightly";
const GAME_FALLBACK_URL = "https://github.com/smartcmd/MinecraftConsoles/releases/download/nightly/LCEWindows64.zip";

/// Read the currently installed game version (stored as published_at timestamp)
pub fn readGameVersion(allocator: std.mem.Allocator) !?[]const u8 {
    const base = try safe_fs.getBaseDir(allocator);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}game_version", .{base});

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 256);
    return std.mem.trimRight(u8, content, "\n\r ");
}

/// Write the game version (published_at timestamp)
pub fn writeGameVersion(allocator: std.mem.Allocator, sha: []const u8) !void {
    const base = try safe_fs.getBaseDir(allocator);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}game_version", .{base});

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(sha);
}

/// Check for game updates via GitHub API
pub fn checkForGameUpdate(allocator: std.mem.Allocator) !void {
    std.log.info("Checking for game updates...", .{});
    game_update_status = .checking;

    // Read current installed version
    const current_sha = try readGameVersion(allocator);

    var bundle = std.crypto.Certificate.Bundle{};
    bundle.rescan(allocator) catch {};

    var client = std.http.Client{ .allocator = allocator, .ca_bundle = bundle };
    defer client.deinit();

    const uri = try std.Uri.parse(GAME_API_URL);
    // Use fetch API which encapsulates open/send/wait
    var req = client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "Flint/1.0" },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "Accept-Encoding", .value = "identity" },
        },
    }) catch |err| {
        std.debug.print("game fetch request err: {}\n", .{err});
        game_update_status = .err;
        return;
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        std.debug.print("game sendBodiless err: {}\n", .{err});
        game_update_status = .err;
        return;
    };

    var server_header_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&server_header_buffer) catch |err| {
        std.debug.print("game receiveHead err: {}\n", .{err});
        game_update_status = .err;
        return;
    };

    if (response.head.status != .ok) {
        std.debug.print("game status not ok: {}\n", .{response.head.status});
        game_update_status = .err;
        return;
    }

    var reader = response.reader(&.{});
    const body = reader.allocRemaining(allocator, .unlimited) catch |err| {
        std.debug.print("game readAllAlloc err: {}\n", .{err});
        game_update_status = .err;
        return;
    };
    defer allocator.free(body);

    // Decompress gzip if needed (GitHub may compress despite Accept-Encoding: identity)
    const json_body = decompressBody(allocator, body) catch {
        game_update_status = .err;
        return;
    };
    defer if (json_body.ptr != body.ptr) allocator.free(json_body);

    // Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch |err| {
        std.debug.print("game json parse err: {}\n", .{err});
        game_update_status = .err;
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        game_update_status = .err;
        return;
    }

    // Use published_at timestamp as the version identifier instead of target_commitish,
    // because the nightly tag is force-pushed and target_commitish never changes.
    const published_at = root.object.get("published_at") orelse {
        game_update_status = .err;
        return;
    };
    if (published_at != .string) {
        game_update_status = .err;
        return;
    }

    available_game_sha = try allocator.dupe(u8, published_at.string);

    // Compare
    if (current_sha) |cs| {
        if (std.mem.eql(u8, cs, published_at.string)) {
            game_update_status = .up_to_date;
        } else {
            game_update_status = .update_available;
        }
    } else {
        // No version installed
        game_update_status = .update_available;
    }
}

/// Find the download URL for the game zip asset
pub fn findGameAssetUrl(allocator: std.mem.Allocator) ![]const u8 {
    var bundle = std.crypto.Certificate.Bundle{};
    bundle.rescan(allocator) catch {};

    var client = std.http.Client{ .allocator = allocator, .ca_bundle = bundle };
    defer client.deinit();

    const uri = try std.Uri.parse(GAME_API_URL);
    // Use fetch API which encapsulates open/send/wait
    var req = client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "Flint/1.0" },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "Accept-Encoding", .value = "identity" },
        },
    }) catch {
        return try allocator.dupe(u8, GAME_FALLBACK_URL);
    };
    defer req.deinit();

    req.sendBodiless() catch {
        return try allocator.dupe(u8, GAME_FALLBACK_URL);
    };

    var server_header_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&server_header_buffer) catch {
        return try allocator.dupe(u8, GAME_FALLBACK_URL);
    };

    if (response.head.status != .ok) {
        return try allocator.dupe(u8, GAME_FALLBACK_URL);
    }

    var reader = response.reader(&.{});
    const body = reader.allocRemaining(allocator, .unlimited) catch {
        return try allocator.dupe(u8, GAME_FALLBACK_URL);
    };
    defer allocator.free(body);

    // Decompress gzip if needed
    const json_body = decompressBody(allocator, body) catch {
        return try allocator.dupe(u8, GAME_FALLBACK_URL);
    };
    defer if (json_body.ptr != body.ptr) allocator.free(json_body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{}) catch {
        return try allocator.dupe(u8, GAME_FALLBACK_URL);
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return try allocator.dupe(u8, GAME_FALLBACK_URL);

    const assets = root.object.get("assets") orelse
        return try allocator.dupe(u8, GAME_FALLBACK_URL);

    if (assets != .array) return try allocator.dupe(u8, GAME_FALLBACK_URL);

    // Look for zip containing "MinecraftConsoles"
    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const name = asset.object.get("name") orelse continue;
        if (name != .string) continue;

        if (std.mem.indexOf(u8, name.string, "MinecraftConsoles") != null and
            std.mem.endsWith(u8, name.string, ".zip"))
        {
            const url = asset.object.get("browser_download_url") orelse continue;
            if (url == .string) {
                game_download_progress.asset_name = try allocator.dupe(u8, name.string);
                return try allocator.dupe(u8, url.string);
            }
        }
    }

    // Fallback: first zip
    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const name = asset.object.get("name") orelse continue;
        if (name != .string) continue;

        if (std.mem.endsWith(u8, name.string, ".zip")) {
            const url = asset.object.get("browser_download_url") orelse continue;
            if (url == .string) {
                game_download_progress.asset_name = try allocator.dupe(u8, name.string);
                return try allocator.dupe(u8, url.string);
            }
        }
    }

    return try allocator.dupe(u8, GAME_FALLBACK_URL);
}

/// Download and install game update
pub fn downloadGame(allocator: std.mem.Allocator) !void {
    game_update_status = .downloading;
    game_download_progress = .{ .is_downloading = true };

    const sha = available_game_sha orelse return;

    // Sanitize published_at (e.g. "2024-01-15T10:30:00Z") into a safe dir name
    // by replacing colons and other unsafe chars with dashes.
    var version_slug_buf: [64]u8 = undefined;
    var slug_len: usize = 0;
    for (sha) |c| {
        if (slug_len >= version_slug_buf.len - 1) break;
        if (c == 'Z') continue;
        version_slug_buf[slug_len] = switch (c) {
            ':', 'T', ' ' => '-',
            else => c,
        };
        slug_len += 1;
    }
    const version_slug = version_slug_buf[0..slug_len];

    // Paths
    const base = try safe_fs.getBaseDir(allocator);
    const versions = try safe_fs.getVersionsDir(allocator);
    defer allocator.free(versions);

    var dl_buf: [std.fs.max_path_bytes]u8 = undefined;
    const downloading_dir = try std.fmt.bufPrint(&dl_buf, "{s}downloading/", .{versions});
    try safe_fs.ensureDir(downloading_dir);

    var zip_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zip_path = try std.fmt.bufPrint(&zip_buf, "{s}downloading/game.zip", .{versions});

    // Get download URL
    const url = try findGameAssetUrl(allocator);
    defer allocator.free(url);

    // Download the file
    var dl_bundle = std.crypto.Certificate.Bundle{};
    dl_bundle.rescan(allocator) catch {};

    var dl_client = std.http.Client{ .allocator = allocator, .ca_bundle = dl_bundle };
    defer dl_client.deinit();

    const dl_uri = try std.Uri.parse(url);
    var dl_req = dl_client.request(.GET, dl_uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "Flint/1.0" },
            .{ .name = "Accept-Encoding", .value = "identity" },
        },
    }) catch return error.HttpRequestFailed;
    defer dl_req.deinit();

    dl_req.sendBodiless() catch return error.HttpRequestFailed;

    var dl_header_buf: [8192]u8 = undefined;
    var dl_response = dl_req.receiveHead(&dl_header_buf) catch return error.HttpRequestFailed;

    // Get content length from response headers for progress tracking
    game_download_progress.total_bytes = dl_response.head.content_length orelse 0;

    // Write to file
    const out_file = try std.fs.createFileAbsolute(zip_path, .{});
    defer out_file.close();

    var dl_reader = dl_response.reader(&.{});
    var bytes_written: u64 = 0;
    const total = game_download_progress.total_bytes;
    var read_buf: [8192]u8 = undefined;
    while (total == 0 or bytes_written < total) {
        // Limit read size to remaining bytes if content-length is known
        const remaining = if (total > 0) @min(read_buf.len, @as(usize, @intCast(total - bytes_written))) else read_buf.len;
        const n = dl_reader.readSliceShort(read_buf[0..remaining]) catch break;
        if (n == 0) break;
        out_file.writeAll(read_buf[0..n]) catch break;
        bytes_written += n;
        game_download_progress.bytes_received = bytes_written;
    }

    // Extract
    game_download_progress.is_extracting = true;
    game_download_progress.bytes_received = 0;
    game_download_progress.total_bytes = 0;

    // Run unzip -l to find total uncompressed bytes
    var l_child = std.process.Child.init(&.{ "unzip", "-l", zip_path }, allocator);
    l_child.stdout_behavior = .Pipe;
    l_child.stderr_behavior = .Ignore;
    l_child.spawn() catch {};
    if (l_child.id != 0) {
        if (l_child.stdout) |out| {
            const contents = out.readToEndAlloc(allocator, 10 * 1024 * 1024) catch "";
            defer if (contents.len > 0) allocator.free(contents);
            var lines = std.mem.splitBackwardsScalar(u8, contents, '\n');
            var total_bytes: u64 = 0;
            while (lines.next()) |line| {
                const tr_line = std.mem.trim(u8, line, " \r\t");
                if (tr_line.len == 0) continue;
                var words = std.mem.tokenizeAny(u8, tr_line, " \t");
                if (words.next()) |first_word| {
                    if (std.fmt.parseInt(u64, first_word, 10)) |val| {
                        total_bytes = val;
                        break;
                    } else |_| {}
                }
            }
            if (total_bytes > 0) {
                game_download_progress.total_bytes = total_bytes;
            }
        }
        _ = l_child.wait() catch {};
    }

    std.debug.print("Download complete ({} bytes), extracting. Total uncompressed size: {}\n", .{ bytes_written, game_download_progress.total_bytes });

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_dir = std.fmt.bufPrint(&target_buf, "{s}nightly-{s}/", .{ versions, version_slug }) catch return error.OutOfMemory;
    safe_fs.ensureDir(target_dir) catch |err| {
        std.debug.print("Failed to create target dir: {}\n", .{err});
        return err;
    };

    const Extractor = struct {
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        target_dir: []const u8,
        allocator: std.mem.Allocator,

        fn getDirSize(dir_path: []const u8, alloc: std.mem.Allocator) u64 {
            var size: u64 = 0;
            var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
            defer dir.close();
            var w = dir.walk(alloc) catch return 0;
            defer w.deinit();
            while (w.next() catch null) |entry| {
                if (entry.kind == .file) {
                    if (dir.statFile(entry.path)) |st| {
                        size += st.size;
                    } else |_| {}
                }
            }
            return size;
        }

        fn pollThread(self: *@This()) void {
            while (!self.done.load(.acquire)) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                game_download_progress.bytes_received = getDirSize(self.target_dir, self.allocator);
            }
            game_download_progress.bytes_received = getDirSize(self.target_dir, self.allocator);
        }
    };

    var ext_state = Extractor{
        .target_dir = target_dir,
        .allocator = allocator,
    };

    const poll_thread = std.Thread.spawn(.{}, Extractor.pollThread, .{&ext_state}) catch null;

    // Use system unzip for extraction
    var child = std.process.Child.init(
        &.{ "unzip", "-o", zip_path, "-d", target_dir },
        allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        std.debug.print("Failed to spawn unzip: {}\n", .{err});
        if (poll_thread) |t| {
            ext_state.done.store(true, .release);
            t.join();
        }
        return err;
    };
    _ = child.wait() catch |err| {
        std.debug.print("unzip wait failed: {}\n", .{err});
        if (poll_thread) |t| {
            ext_state.done.store(true, .release);
            t.join();
        }
        return err;
    };

    if (poll_thread) |t| {
        ext_state.done.store(true, .release);
        t.join();
    }

    if (game_download_progress.total_bytes > 0) {
        game_download_progress.bytes_received = game_download_progress.total_bytes;
    }

    std.debug.print("Extraction complete\n", .{});

    // Check for single wrapper directory and strip it
    stripWrapperDir(allocator, target_dir) catch |err| {
        std.debug.print("stripWrapperDir failed (non-fatal): {}\n", .{err});
    };

    // Write game version
    writeGameVersion(allocator, sha) catch |err| {
        std.debug.print("writeGameVersion failed: {}\n", .{err});
        return err;
    };

    // Clean up downloading dir
    safe_fs.safeDelete(allocator, downloading_dir) catch {};

    // Clean old versions
    cleanOldVersions(allocator) catch |err| {
        std.debug.print("cleanOldVersions failed (non-fatal): {}\n", .{err});
    };

    game_download_progress.done = true;
    game_download_progress.is_downloading = false;
    game_download_progress.is_extracting = false;
    game_update_status = .up_to_date;
    std.debug.print("Game update installed successfully\n", .{});

    // Refresh the installed versions list
    refreshInstalledVersions(allocator);

    _ = base;
}

/// If extracted dir has a single top-level folder, move its contents up
fn stripWrapperDir(allocator: std.mem.Allocator, target_dir: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(target_dir, .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList([]const u8).empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    var single_dir: ?[]const u8 = null;
    var count: u32 = 0;
    while (try it.next()) |entry| {
        count += 1;
        if (count == 1 and entry.kind == .directory) {
            single_dir = try allocator.dupe(u8, entry.name);
        } else {
            if (single_dir) |sd| {
                allocator.free(sd);
                single_dir = null;
            }
            return; // Multiple entries or first isn't a dir
        }
    }

    if (single_dir) |wrapper_name| {
        defer allocator.free(wrapper_name);

        // Move contents from wrapper to target_dir
        var wrapper_buf: [std.fs.max_path_bytes]u8 = undefined;
        const wrapper_path = try std.fmt.bufPrint(&wrapper_buf, "{s}{s}/", .{ target_dir, wrapper_name });

        // Use system mv
        var child = std.process.Child.init(
            &.{ "sh", "-c", try std.fmt.allocPrint(allocator, "mv {s}* {s} 2>/dev/null; mv {s}.* {s} 2>/dev/null; rmdir {s}", .{ wrapper_path, target_dir, wrapper_path, target_dir, wrapper_path }) },
            allocator,
        );
        try child.spawn();
        _ = try child.wait();
    }
}

/// Keep last 2 versions, safeDelete older ones
fn cleanOldVersions(allocator: std.mem.Allocator) !void {
    const versions_dir = try safe_fs.getVersionsDir(allocator);
    defer allocator.free(versions_dir);

    var dir = std.fs.openDirAbsolute(versions_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var version_names = std.ArrayList([]const u8).empty;
    defer {
        for (version_names.items) |n| allocator.free(n);
        version_names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "nightly-")) {
            try version_names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    if (version_names.items.len <= 2) return;

    // Sort and keep last 2
    std.mem.sort([]const u8, version_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_val: []const u8) bool {
            return std.mem.lessThan(u8, a, b_val);
        }
    }.lessThan);

    // Delete all but last 2
    const to_delete = version_names.items[0 .. version_names.items.len - 2];
    for (to_delete) |name| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ versions_dir, name }) catch continue;
        safe_fs.safeDelete(allocator, full_path) catch {};
    }
}

/// Get the short version string for display (first 10 chars of published_at, e.g. "2024-01-15")
pub fn getGameVersionShort(allocator: std.mem.Allocator) !?[]const u8 {
    const sha = try readGameVersion(allocator);
    if (sha) |s| {
        if (s.len >= 10) {
            return try allocator.dupe(u8, s[0..10]);
        }
        return s;
    }
    return null;
}
