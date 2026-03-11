const std = @import("std");
const logger = @import("logger.zig");

const JSON_LIMIT: std.Io.Limit = .limited(10 * 1024 * 1024); // 10 MiB for API responses
pub const ARCHIVE_LIMIT: std.Io.Limit = .limited(200 * 1024 * 1024); // 200 MiB for binaries

pub fn fetchBody(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    return fetchBodyLimit(allocator, url, JSON_LIMIT);
}

pub fn fetchBodyLimit(allocator: std.mem.Allocator, url: []const u8, limit: std.Io.Limit) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    client.ca_bundle.rescan(allocator) catch {};

    var current_url = try allocator.dupe(u8, url);
    defer allocator.free(current_url);

    var redirect_count: usize = 0;
    const max_redirects = 10;

    while (redirect_count < max_redirects) {
        const uri = try std.Uri.parse(current_url);
        var req = try client.request(.GET, uri, .{
            .headers = .{
                .user_agent = .{ .override = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Flint/0.1.0" },
                .accept_encoding = .{ .override = "gzip, identity" },
            },
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buffer: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        switch (response.head.status) {
            .ok => {
                var transfer_buf: [8192]u8 = undefined;
                const body_reader = response.reader(&transfer_buf);
                const raw = try body_reader.allocRemaining(allocator, limit);
                errdefer allocator.free(raw);
                return handleTransportDecompression(allocator, raw, response.head.content_encoding);
            },
            .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => {
                if (response.head.location) |loc| {
                    logger.info("http redirect: {s} -> {s}", .{ current_url, loc });

                    const next_url = try allocator.dupe(u8, loc);
                    allocator.free(current_url);
                    current_url = next_url;

                    redirect_count += 1;
                    continue;
                }
                logger.err("http redirect without location header", .{});
                return error.HttpRedirectNoLocation;
            },
            else => {
                logger.err("http status {s} ({s})", .{ @tagName(response.head.status), current_url });
                return error.HttpNotOk;
            },
        }
    }

    return error.TooManyRedirects;
}

fn handleTransportDecompression(allocator: std.mem.Allocator, body: []const u8, encoding: std.http.ContentEncoding) ![]const u8 {
    if (encoding == .identity) return body;

    // Only decompress if the transport layer explicitly gzipped/deflated it.
    // Sniffing magic bytes (0x1f 0x8b) was causing double-decompression for .tar.gz files.
    if (encoding == .gzip or encoding == .deflate) {
        var in_reader = std.Io.Reader.fixed(body);
        var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&in_reader, .gzip, &window_buf);

        const decompressed = try decomp.reader.allocRemaining(allocator, .limited(64 * 1024 * 1024));
        allocator.free(body);
        return decompressed;
    }

    return body;
}
