const std = @import("std");
const c = @import("../c_imports.zig").c;
pub const colors = @import("colors.zig");

// ── Font constants ────────────────────────────────────────────────────────

pub const FONT_ID: u16 = 0;
pub const FONT_SIZE_SMALL: u16 = 10;
pub const FONT_SIZE_NORMAL: u16 = 12;
pub const FONT_SIZE_HEADER: u16 = 16;

// ── Clay string/ID utilities ──────────────────────────────────────────────

pub fn clayStr(s: []const u8) c.Clay_String {
    return .{ .length = @intCast(s.len), .chars = s.ptr };
}

pub fn clayId(name: []const u8) c.Clay_ElementId {
    return c.Clay__HashString(clayStr(name), 0);
}

pub fn clayIdI(name: []const u8, index: u32) c.Clay_ElementId {
    return c.Clay__HashStringWithOffset(clayStr(name), index, 0);
}

pub fn openElement(name: []const u8) void {
    c.Clay__OpenElementWithId(clayId(name));
}

pub fn openElementI(name: []const u8, index: u32) void {
    c.Clay__OpenElementWithId(clayIdI(name, index));
}

pub fn closeElement() void {
    c.Clay__CloseElement();
}

// ── Text element ──────────────────────────────────────────────────────────

// Module-local counter reset each frame by layoutRoot
pub var text_id_counter: u32 = 0;

pub fn textElement(s: []const u8, font_size: u16, color: c.Clay_Color) void {
    text_id_counter +%= 1;
    c.Clay__OpenElementWithId(c.Clay__HashStringWithOffset(clayStr(s), text_id_counter, 0));
    c.Clay__ConfigureOpenElement(.{ .layout = .{ .sizing = .{ .width = fitWidth(), .height = fitHeight() } } });

    c.Clay__OpenTextElement(clayStr(s), c.Clay__StoreTextElementConfig(.{
        .fontId = FONT_ID,
        .fontSize = font_size,
        .textColor = color,
    }));

    closeElement();
}

pub fn imageElement(name: []const u8, texture: ?*c.SDL_Texture, width: f32, height: f32) void {
    if (texture) |tex| {
        openElement(name);
        c.Clay__ConfigureOpenElement(.{
            .layout = .{ .sizing = .{ .width = fixedW(width), .height = fixedH(height) } },
            .image = .{ .imageData = tex },
        });
        closeElement();
    }
}

pub fn button(id: []const u8, text: []const u8, fontSize: u16, bgColor: c.Clay_Color, widthSizing: c.Clay_SizingAxis) void {
    openElement(id);
    c.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{ .width = widthSizing, .height = fitHeight() },
            .padding = .{ .left = 16, .right = 16, .top = 6, .bottom = 6 },
            .childAlignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_CENTER },
        },
        .backgroundColor = bgColor,
        .cornerRadius = uniformCorner(4),
    });
    c.Clay__OpenTextElement(clayStr(text), c.Clay__StoreTextElementConfig(.{
        .fontSize = fontSize,
        .textColor = colors.COLOR_WHITE,
        .fontId = FONT_ID,
    }));
    closeElement();
}

// ── Sizing helpers ────────────────────────────────────────────────────────

pub fn growSize() c.Clay_Sizing {
    return .{
        .width = .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW },
        .height = .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW },
    };
}

pub fn growWidth() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW };
}

pub fn growHeight() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW };
}

pub fn fitWidth() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_FIT };
}

pub fn fitHeight() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_FIT };
}

pub fn fixedW(w: f32) c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = w, .max = w } }, .type = c.CLAY__SIZING_TYPE_FIXED };
}

pub fn fixedH(h: f32) c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = h, .max = h } }, .type = c.CLAY__SIZING_TYPE_FIXED };
}

pub fn percentW(pct: f32) c.Clay_SizingAxis {
    return .{ .size = .{ .percent = pct }, .type = c.CLAY__SIZING_TYPE_PERCENT };
}

pub fn uniformCorner(r: f32) c.Clay_CornerRadius {
    return .{ .topLeft = r, .topRight = r, .bottomLeft = r, .bottomRight = r };
}

pub fn uniformBorder(width: u16) c.Clay_BorderWidth {
    return .{ .left = width, .right = width, .top = width, .bottom = width, .betweenChildren = 0 };
}

pub fn pad4(l: u16, r: u16, t: u16, b: u16) c.Clay_Padding {
    return .{ .left = l, .right = r, .top = t, .bottom = b };
}
