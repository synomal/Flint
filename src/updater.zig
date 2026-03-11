const std = @import("std");
const builtin = @import("builtin");
const safe_fs = @import("safe_fs.zig");
const logger = @import("logger.zig");
const http_client = @import("http_client.zig");

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

// Embedded at compile time from src/version.txt.
// Locally contains "v0.0.0-dev". CI writes the real semver tag before `zig build`.
pub const current_version = std.mem.trimRight(u8, @embedFile("version.txt"), "\n\r ");

const LAUNCHER_API_URL = "https://api.github.com/repos/synomal/Flint/releases/latest";

// Exact asset filenames published by CI
const ASSET_NAME = if (builtin.os.tag == .windows)
    "flint-windows-x86_64.zip"
else
    "flint-linux-x86_64.tar.gz";

/// Get the version string for display (e.g. "v0.2.3" or "v0.0.0-dev")
pub fn getVersion() []const u8 {
    return current_version;
}

/// Returns true if the running executable is already inside ~/.flintlauncher/
pub fn isInstalledLocation(allocator: std.mem.Allocator) bool {
    const self_path = std.fs.selfExePathAlloc(allocator) catch return true; // assume ok on error
    defer allocator.free(self_path);

    const base = safe_fs.getBaseDir(allocator) catch return true;
    // base ends with separator, so any self_path that starts with it is inside
    return std.mem.startsWith(u8, self_path, base);
}

/// Copy the running exe into ~/.flintlauncher/flint[.exe], re-launch it, then exit.
pub fn installSelf(allocator: std.mem.Allocator) !void {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);

    const base = try safe_fs.getBaseDir(allocator);
    try safe_fs.ensureDir(base);

    const exe_name = if (comptime builtin.os.tag == .windows) "flint.exe" else "flint";
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrint(&dest_buf, "{s}{s}", .{ base, exe_name });

    // Copy
    try std.fs.copyFileAbsolute(self_path, dest_path, .{});

    // Make executable on Linux
    if (comptime builtin.os.tag == .linux) {
        const f = try std.fs.openFileAbsolute(dest_path, .{});
        defer f.close();
        try f.chmod(0o755);
    }

    logger.info("installSelf: installed to {s}, relaunching", .{dest_path});
    try relaunch(allocator, dest_path);
}

// ── Private helpers ────────────────────────────────────────────────────────

/// Find the download URL for the platform asset by exact filename match.
/// Caller must free the returned slice.
fn findAssetUrl(allocator: std.mem.Allocator, assets_val: std.json.Value) ![]const u8 {
    if (assets_val != .array) return error.InvalidResponse;

    for (assets_val.array.items) |asset| {
        if (asset != .object) continue;
        const name_val = asset.object.get("name") orelse continue;
        if (name_val != .string) continue;

        if (std.mem.eql(u8, name_val.string, ASSET_NAME)) {
            const url_val = asset.object.get("browser_download_url") orelse continue;
            if (url_val == .string) {
                return allocator.dupe(u8, url_val.string);
            }
        }
    }

    logger.err("launcher: asset '{s}' not found in release", .{ASSET_NAME});
    return error.AssetNotFound;
}

/// Extract the first file from a zip archive in memory and write it to `out_file`.
/// Only handles deflate-compressed (method 8) or stored (method 0) entries.
fn extractZipBinary(archive: []const u8, out_file: std.fs.File) !void {
    // Zip local file header signature: PK\x03\x04
    if (archive.len < 30 or !std.mem.startsWith(u8, archive, "PK\x03\x04"))
        return error.NotAZip;

    const method = std.mem.readInt(u16, archive[8..10], .little);
    const compressed_size = std.mem.readInt(u32, archive[18..22], .little);
    const fname_len = std.mem.readInt(u16, archive[26..28], .little);
    const extra_len = std.mem.readInt(u16, archive[28..30], .little);

    const data_offset = 30 + fname_len + extra_len;
    if (data_offset + compressed_size > archive.len) return error.TruncatedZip;
    const data = archive[data_offset .. data_offset + compressed_size];

    if (method == 0) {
        // Stored — no compression
        try out_file.writeAll(data);
    } else if (method == 8) {
        // Deflate
        var in_reader = std.Io.Reader.fixed(data);
        var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&in_reader, .raw, &window_buf);
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = try decomp.reader.readSliceShort(&buf);
            if (n == 0) break;
            try out_file.writeAll(buf[0..n]);
        }
    } else {
        return error.UnsupportedZipMethod;
    }
}

/// Extract the first non-directory file from a .tar.gz archive and write it to `out_file`.
fn extractTarGzBinary(allocator: std.mem.Allocator, archive: []const u8, out_file: std.fs.File) !void {
    // Decompress gzip first
    var in_reader = std.Io.Reader.fixed(archive);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&in_reader, .gzip, &window_buf);
    const tar_data = try decomp.reader.allocRemaining(allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(tar_data);

    // Walk tar records (512-byte blocks)
    var pos: usize = 0;
    while (pos + 512 <= tar_data.len) {
        const hdr = tar_data[pos .. pos + 512];
        pos += 512;

        // End-of-archive: two zero blocks
        if (std.mem.allEqual(u8, hdr, 0)) break;

        // File size from octal string at offset 124, length 12
        const size_str = std.mem.trimRight(u8, hdr[124..136], "\x00 ");
        const file_size = std.fmt.parseInt(u64, size_str, 8) catch continue;

        const type_flag = hdr[156];
        const is_regular = (type_flag == '0' or type_flag == 0);

        const blocks = (file_size + 511) / 512;

        if (is_regular and file_size > 0) {
            if (pos + file_size > tar_data.len) return error.TruncatedTar;
            try out_file.writeAll(tar_data[pos .. pos + file_size]);
            return; // Done — first regular file is the binary
        }

        pos += blocks * 512;
    }

    return error.NoFileInTar;
}

// ── Public API ─────────────────────────────────────────────────────────────

/// Check for launcher updates via GitHub latest release.
pub fn checkForLauncherUpdate(allocator: std.mem.Allocator) !void {
    logger.info("Checking for launcher updates...", .{});
    launcher_update_status = .checking;

    const body = http_client.fetchBody(allocator, LAUNCHER_API_URL) catch {
        launcher_update_status = .err;
        return;
    };
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |e| {
        logger.err("launcher JSON parse err: {}", .{e});
        launcher_update_status = .err;
        return;
    };
    defer parsed.deinit();

    const tag_val = parsed.value.object.get("tag_name") orelse {
        logger.err("launcher API response missing tag_name", .{});
        launcher_update_status = .err;
        return;
    };
    if (tag_val != .string) {
        launcher_update_status = .err;
        return;
    }

    logger.info("launcher: current={s} latest={s}", .{ current_version, tag_val.string });

    launcher_update_status = if (std.mem.eql(u8, current_version, tag_val.string))
        .up_to_date
    else
        .update_available;
}

/// Delete leftover launcher.old on startup
pub fn cleanupOldLauncher() void {
    const self_path = std.fs.selfExePathAlloc(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(self_path);

    const dir = std.fs.path.dirname(self_path) orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_path = std.fmt.bufPrint(&buf, "{s}/launcher.old", .{dir}) catch return;

    for (0..3) |_| {
        std.fs.deleteFileAbsolute(old_path) catch |e| switch (e) {
            error.FileNotFound => return,
            else => {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            },
        };
        return;
    }
}

/// Download and apply launcher update.
/// Downloads the platform archive, extracts the binary, atomically swaps it in.
pub fn downloadAndApplyUpdate(allocator: std.mem.Allocator) !void {
    launcher_update_status = .downloading;

    // Fetch release JSON to find the asset URL
    const body = http_client.fetchBody(allocator, LAUNCHER_API_URL) catch {
        launcher_update_status = .err;
        return;
    };
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        launcher_update_status = .err;
        return error.InvalidResponse;
    }

    const assets_val = root.object.get("assets") orelse {
        launcher_update_status = .err;
        return error.InvalidResponse;
    };

    const url = findAssetUrl(allocator, assets_val) catch |e| {
        logger.err("launcher asset not found: {}", .{e});
        launcher_update_status = .err;
        return;
    };
    defer allocator.free(url);

    // Download the archive — use ARCHIVE_LIMIT (200 MiB) not the JSON 10 MiB cap
    logger.info("launcher: downloading {s}", .{url});
    const archive = http_client.fetchBodyLimit(allocator, url, http_client.ARCHIVE_LIMIT) catch |e| {
        logger.err("launcher archive download err: {}", .{e});
        launcher_update_status = .err;
        return;
    };
    defer allocator.free(archive);

    // Resolve paths
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse return;

    const new_path = try std.fs.path.join(allocator, &.{ self_dir, "launcher.new" });
    defer allocator.free(new_path);
    const old_path = try std.fs.path.join(allocator, &.{ self_dir, "launcher.old" });
    defer allocator.free(old_path);

    {
        const out_file = try std.fs.createFileAbsolute(new_path, .{});
        defer out_file.close();

        // Extract the binary from the archive
        if (comptime builtin.os.tag == .windows) {
            extractZipBinary(archive, out_file) catch |e| {
                logger.err("launcher zip extract err: {}", .{e});
                launcher_update_status = .err;
                return;
            };
        } else {
            extractTarGzBinary(allocator, archive, out_file) catch |e| {
                logger.err("launcher tar.gz extract err: {}", .{e});
                launcher_update_status = .err;
                return;
            };
            // Make executable on Linux
            try out_file.chmod(0o755);
        }
    }

    // Atomic swap: current -> old, new -> current
    logger.info("launcher: applying atomic swap...", .{});

    const exe_basename = std.fs.path.basename(self_path);
    const old_basename = std.fs.path.basename(old_path);
    const new_basename = std.fs.path.basename(new_path);

    if (comptime builtin.os.tag == .windows) {
        const win = std.os.windows;
        // sliceToPrefixedFileW handles converting to UTF-16 and adding the required NT path prefixes.
        // We use MoveFileExW directly because std.fs.Dir.rename requests GENERIC_WRITE access
        // when opening the source file, which is forbidden for a running executable.
        const self_path_w = try win.sliceToPrefixedFileW(null, self_path);
        const old_path_w = try win.sliceToPrefixedFileW(null, old_path);
        const new_path_w = try win.sliceToPrefixedFileW(null, new_path);

        logger.info("launcher: renaming self to {s}", .{old_basename});
        if (win.kernel32.MoveFileExW(self_path_w.span().ptr, old_path_w.span().ptr, win.MOVEFILE_REPLACE_EXISTING) == win.FALSE) {
            const err = win.kernel32.GetLastError();
            logger.info("launcher: note: could not move self to .old: GetLastError {d}", .{@intFromEnum(err)});
        }

        logger.info("launcher: renaming {s} to self", .{new_basename});
        if (win.kernel32.MoveFileExW(new_path_w.span().ptr, self_path_w.span().ptr, win.MOVEFILE_REPLACE_EXISTING) == win.FALSE) {
            const err = win.kernel32.GetLastError();
            logger.err("launcher: failed to move .new to self: GetLastError {d}", .{@intFromEnum(err)});
            launcher_update_status = .err;
            return error.AccessDenied;
        }
    } else {
        var dir = try std.fs.openDirAbsolute(self_dir, .{});
        defer dir.close();

        logger.info("launcher: renaming self ({s}) to {s}", .{ exe_basename, old_basename });
        dir.rename(exe_basename, old_basename) catch |e| {
            logger.info("launcher: note: could not move self to .old (might be fine if first run): {}", .{e});
        };

        logger.info("launcher: renaming {s} to {s}", .{ new_basename, exe_basename });
        dir.rename(new_basename, exe_basename) catch |e| {
            logger.err("launcher: failed to move .new to self: {}", .{e});
            launcher_update_status = .err;
            return e;
        };
    }

    logger.info("launcher: update applied, restarting", .{});
    try relaunch(allocator, self_path);
}

/// Relaunches the application at `exe_path` and terminates the current process.
/// Handles platform-specific spawning details to ensure focus and stability.
fn relaunch(allocator: std.mem.Allocator, exe_path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        const win = std.os.windows;
        
        // Use standard Win32 externs for focus and process creation
        const user32 = struct {
            pub extern "user32" fn AllowSetForegroundWindow(dwProcessId: win.DWORD) callconv(.winapi) win.BOOL;
        };
        const ASFW_ANY: win.DWORD = @bitCast(@as(i32, -1));
        const STARTF_USESHOWWINDOW = 0x00000001;
        const SW_SHOWNORMAL = 1;

        var si = std.mem.zeroInit(win.STARTUPINFOW, .{ 
            .cb = @sizeOf(win.STARTUPINFOW),
            .dwFlags = STARTF_USESHOWWINDOW,
            .wShowWindow = SW_SHOWNORMAL,
        });
        var pi: win.PROCESS_INFORMATION = undefined;

        // Use standard UTF-16 conversion. CreateProcessW expects a standard Win32 path.
        // sliceToPrefixedFileW returns an NT prefix (\??\) which CreateProcessW does not always support.
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, exe_path);
        defer allocator.free(path_w);

        var attempts: usize = 0;
        while (attempts < 5) : (attempts += 1) {
            logger.info("relauncher: restart attempt {d}...", .{attempts + 1});
            
            // Allow ANY process to take foreground focus (including our soon-to-be child)
            _ = user32.AllowSetForegroundWindow(ASFW_ANY);

            if (win.kernel32.CreateProcessW(
                path_w.ptr,
                null, 
                null, 
                null,
                win.FALSE, 
                .{}, 
                null, 
                null,
                &si,
                &pi,
            ) != win.FALSE) {
                // Also explicitly allow the specific child PID just in case
                _ = user32.AllowSetForegroundWindow(pi.dwProcessId);
                
                win.CloseHandle(pi.hProcess);
                win.CloseHandle(pi.hThread);
                logger.info("relauncher: restart successful, exiting", .{});
                
                // Small sleep to ensure the OS registers the AllowSetForegroundWindow 
                // before the parent process completely disappears.
                std.Thread.sleep(50 * std.time.ns_per_ms);
                std.process.exit(0);
            }

            const err = win.kernel32.GetLastError();
            var buf_w: [512:0]win.WCHAR = undefined;
            const len = win.kernel32.FormatMessageW(
                win.FORMAT_MESSAGE_FROM_SYSTEM | win.FORMAT_MESSAGE_IGNORE_INSERTS,
                null,
                err,
                1024,
                &buf_w,
                buf_w.len,
                null,
            );
            
            if (len > 0) {
                logger.err("relauncher: spawn failed (attempt {d}): GetLastError {d}: {f}", .{
                    attempts + 1, @intFromEnum(err), std.unicode.fmtUtf16Le(buf_w[0..len]),
                });
            } else {
                logger.err("relauncher: spawn failed (attempt {d}): GetLastError {d}", .{
                    attempts + 1, @intFromEnum(err),
                });
            }

            if (attempts == 4) return error.Unexpected;
            std.Thread.sleep(200 * std.time.ns_per_ms);
        }
    } else {
        var child = std.process.Child.init(&.{exe_path}, allocator);
        child.create_no_window = false;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        var attempts: usize = 0;
        while (attempts < 5) : (attempts += 1) {
            logger.info("relauncher: restart attempt {d}...", .{attempts + 1});
            child.spawn() catch |err| {
                logger.err("relauncher: spawn failed (attempt {d}): {}", .{ attempts + 1, err });
                if (attempts == 4) return err;
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            };
            logger.info("relauncher: restart successful, exiting", .{});
            std.process.exit(0);
        }
    }
}
