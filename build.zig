const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get raylib dependency
    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });

    // Get perlin noise dependency
    const perlin_dep = b.dependency("perlin", .{
        .target = target,
        .optimize = optimize,
    });

    // Create raylib module
    const raylib_module = b.addModule("raylib", .{
        .root_source_file = .{ .cwd_relative = "src/raylib.zig" },
    });

    // Create perlin module
    const perlin_module = b.addModule("perlin", .{
        .root_source_file = perlin_dep.path("lib/perlin.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "mmd",
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Link with raylib
    exe.linkLibrary(raylib_dep.artifact("raylib"));
    exe.linkLibC();

    // Add raylib include path
    exe.addIncludePath(raylib_dep.path("src"));
    exe.root_module.addImport("raylib", raylib_module);
    exe.root_module.addImport("perlin", perlin_module);

    // This declares intent for the executable to be installed
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
