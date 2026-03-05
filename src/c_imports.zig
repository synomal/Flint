// Shared C imports — all modules must use this single @cImport
// to avoid duplicate opaque type errors across compilation units.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
    @cInclude("clay.h");
    @cInclude("stb_image.h");
});
