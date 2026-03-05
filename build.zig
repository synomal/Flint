const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Write commit.txt from git rev-parse HEAD (fallback to "dev") ---
    const git_commit_step = b.addSystemCommand(&.{ "sh", "-c", "git rev-parse HEAD 2>/dev/null || echo dev" });
    const git_output = git_commit_step.captureStdOut();
    const write_commit = b.addUpdateSourceFiles();
    write_commit.addCopyFileToSource(git_output, "src/commit.txt");
    write_commit.step.dependOn(&git_commit_step.step);

    // --- SDL3 dependency ---
    const sdl3_dep = b.dependency("SDL", .{
        .target = target,
        .optimize = optimize,
    });

    // --- SDL3_ttf dependency ---
    const sdl3_ttf_dep = b.dependency("SDL_ttf", .{
        .target = target,
        .optimize = optimize,
    });

    // --- Main executable ---
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add C include paths to the module
    mod.addIncludePath(b.path("vendor/clay"));
    mod.addIncludePath(b.path("vendor/stb"));

    // Clay: compile as C source
    mod.addCSourceFile(.{
        .file = b.path("vendor/clay/clay_impl.c"),
        .flags = &.{"-std=c99"},
    });

    // stb_image: compile as C source
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });

    // Link SDL3 and SDL3_ttf
    mod.linkLibrary(sdl3_dep.artifact("SDL3"));
    mod.linkLibrary(sdl3_ttf_dep.artifact("SDL3_ttf"));

    const exe = b.addExecutable(.{
        .name = "flint",
        .root_module = mod,
    });

    // Make sure commit.txt is written before compilation
    exe.step.dependOn(&write_commit.step);

    b.installArtifact(exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the launcher");
    run_step.dependOn(&run_cmd.step);
}
