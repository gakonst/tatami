const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The window manager and its command line client, one binary.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // System frameworks only. tatami has no dependencies.
    for ([_][]const u8{ "CoreFoundation", "ApplicationServices", "Carbon", "AppKit" }) |framework| {
        exe_module.linkFramework(framework, .{});
    }
    exe_module.linkSystemLibrary("objc", .{});
    const exe = b.addExecutable(.{ .name = "tatami", .root_module = exe_module });
    b.installArtifact(exe);

    // The deterministic simulator: the engine against a fake macOS.
    const sim = b.addExecutable(.{
        .name = "tatami-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(sim);
    const sim_run = b.addRunArtifact(sim);
    sim_run.addPassthruArgs();
    b.step("sim", "Run the deterministic simulator").dependOn(&sim_run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.step("test", "Run unit tests and simulation tests").dependOn(&b.addRunArtifact(tests).step);
}
