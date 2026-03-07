const std = @import("std");

/// Launcher configuration loaded from and saved to config.json
pub const Preset = struct {
    name: []const u8 = "",
    username: []const u8 = "",
    ip: []const u8 = "",
    port: []const u8 = "",
};

pub const Config = struct {
    saves_path: []const u8 = "",
    active_preset: u32 = 0,
    presets: []Preset = &[_]Preset{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.saves_path.len > 0) allocator.free(self.saves_path);
        for (self.presets) |preset| {
            if (preset.name.len > 0) allocator.free(preset.name);
            if (preset.username.len > 0) allocator.free(preset.username);
            if (preset.ip.len > 0) allocator.free(preset.ip);
            if (preset.port.len > 0) allocator.free(preset.port);
        }
        if (self.presets.len > 0) allocator.free(self.presets);
        self.* = .{};
    }
};

const safe_fs = @import("safe_fs.zig");

/// Load config from ~/.lcelauncher/config.json, returns defaults if missing
pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    const base = try safe_fs.getBaseDir(allocator);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&path_buf, "{s}config.json", .{base});

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Return defaults with saves path set
            var cfg = Config{};
            const saves = try safe_fs.getSavesDir(allocator);
            cfg.saves_path = saves;

            // Initial default preset
            const default_presets = try allocator.alloc(Preset, 1);
            default_presets[0] = .{
                .name = try allocator.dupe(u8, "Default"),
                .port = try allocator.dupe(u8, "25565"),
            };
            cfg.presets = default_presets;
            return cfg;
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var config = Config{};

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        // If JSON is invalid, return defaults
        const saves = try safe_fs.getSavesDir(allocator);
        config.saves_path = saves;
        const default_presets = try allocator.alloc(Preset, 1);
        default_presets[0] = .{
            .name = try allocator.dupe(u8, "Default"),
            .port = try allocator.dupe(u8, "25565"),
        };
        config.presets = default_presets;
        return config;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root == .object) {
        if (root.object.get("saves_path")) |sp| {
            if (sp == .string) {
                config.saves_path = try allocator.dupe(u8, sp.string);
            }
        }
        if (root.object.get("active_preset")) |ap| {
            if (ap == .integer) {
                config.active_preset = @intCast(@as(u32, @truncate(@as(u64, @bitCast(ap.integer)))));
            }
        }
        if (root.object.get("presets")) |presets_val| {
            if (presets_val == .array) {
                const count = presets_val.array.items.len;
                config.presets = try allocator.alloc(Preset, count);
                for (presets_val.array.items, 0..) |item, i| {
                    config.presets[i] = .{}; // Initialize with defaults (empty strings)
                    if (item == .object) {
                        if (item.object.get("name")) |n| {
                            if (n == .string) config.presets[i].name = try allocator.dupe(u8, n.string);
                        }
                        if (item.object.get("username")) |u| {
                            if (u == .string) config.presets[i].username = try allocator.dupe(u8, u.string);
                        }
                        if (item.object.get("ip")) |ip| {
                            if (ip == .string) config.presets[i].ip = try allocator.dupe(u8, ip.string);
                        }
                        if (item.object.get("port")) |p| {
                            if (p == .string) config.presets[i].port = try allocator.dupe(u8, p.string);
                        }
                    }
                    // Final fallback for required fields
                    if (config.presets[i].name.len == 0) config.presets[i].name = try allocator.dupe(u8, "Default");
                    if (config.presets[i].port.len == 0) config.presets[i].port = try allocator.dupe(u8, "25565");
                }
            }
        }
    }

    // Default saves_path if not set
    if (config.saves_path.len == 0) {
        config.saves_path = try safe_fs.getSavesDir(allocator);
    }

    // Ensure at least one preset exists
    if (config.presets.len == 0) {
        const default_presets = try allocator.alloc(Preset, 1);
        default_presets[0] = .{
            .name = try allocator.dupe(u8, "Default"),
            .port = try allocator.dupe(u8, "25565"),
        };
        config.presets = default_presets;
    }

    return config;
}

/// Atomic save: write to config.json.tmp then rename to config.json
pub fn saveConfig(allocator: std.mem.Allocator, config: *const Config) !void {
    const base = try safe_fs.getBaseDir(allocator);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&path_buf, "{s}config.json.tmp", .{base});
    var final_buf: [std.fs.max_path_bytes]u8 = undefined;
    const final_path = try std.fmt.bufPrint(&final_buf, "{s}config.json", .{base});

    // Build JSON string manually for control over format
    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(allocator);
    const writer = json_buf.writer(allocator);

    try writer.writeAll("{\n");
    try writer.print("  \"saves_path\": \"{s}\",\n", .{config.saves_path});
    try writer.print("  \"active_preset\": {d},\n", .{config.active_preset});
    try writer.writeAll("  \"presets\": [\n");
    for (config.presets, 0..) |preset, i| {
        try writer.writeAll("    { ");
        try writer.print("\"name\": \"{s}\", ", .{preset.name});
        try writer.print("\"username\": \"{s}\", ", .{preset.username});
        try writer.print("\"ip\": \"{s}\", ", .{preset.ip});
        try writer.print("\"port\": \"{s}\"", .{preset.port});
        try writer.writeAll(" }");
        if (i < config.presets.len - 1) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ]\n");
    try writer.writeAll("}\n");

    // Write to tmp file
    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer tmp_file.close();
    try tmp_file.writeAll(json_buf.items);

    // Atomic rename
    try std.fs.renameAbsolute(tmp_path, final_path);
}
