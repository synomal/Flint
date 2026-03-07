const std = @import("std");
const safe_fs = @import("safe_fs.zig");

var log_file: ?std.fs.File = null;

pub fn init(allocator: std.mem.Allocator) !void {
    const base_dir = try safe_fs.getBaseDir(allocator);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&path_buf, "{s}latest.log", .{base_dir});

    log_file = std.fs.createFileAbsolute(log_path, .{ .truncate = true }) catch |e| {
        std.debug.print("Failed to create log file {s}: {}\n", .{ log_path, e });
        return e;
    };
}

pub fn deinit() void {
    if (log_file) |f| {
        f.close();
        log_file = null;
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (log_file) |f| {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        f.writeAll(msg) catch {};
    }
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (log_file) |f| {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[INFO] " ++ fmt ++ "\n", args) catch return;
        f.writeAll(msg) catch {};
    }
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (log_file) |f| {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[WARN] " ++ fmt ++ "\n", args) catch return;
        f.writeAll(msg) catch {};
    }
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (log_file) |f| {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[ERROR] " ++ fmt ++ "\n", args) catch return;
        f.writeAll(msg) catch {};
    }
}
