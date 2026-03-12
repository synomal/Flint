const std = @import("std");
const c = @import("c_imports.zig").c;

pub var redraw_event_type: u32 = 0;

pub fn pushRedrawEvent() void {
    const et = redraw_event_type;
    if (et == 0) return;

    var event: c.SDL_Event = undefined;
    @memset(std.mem.asBytes(&event), 0);
    event.type = et;
    if (!c.SDL_PushEvent(&event)) {
        // We can't easily log here without circular imports, so we just ignore
        // since redraw events are non-critical and will likely recover on next event.
    }
}
