const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dir = try std.fs.openDirAbsolute("/home/synima/Projects/Flint/src", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var total: u64 = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            if (dir.statFile(entry.path)) |st| {
                total += st.size;
            } else |_| {}
        }
    }
    std.debug.print("total: {d}\n", .{total});
}
