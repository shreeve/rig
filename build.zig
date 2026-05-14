//! Rig Build Configuration
//!
//! Steps:
//!   zig build              — build bin/rig
//!   zig build parser       — regenerate src/parser.zig from rig.grammar via Nexus
//!   zig build run -- ...   — run bin/rig with args
//!   zig build test         — run tests
//!
//! Nexus must be built first: (cd ../nexus && zig build -Doptimize=ReleaseSafe)

const std = @import("std");

const version = "0.1.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------
    // parser generation step
    // -----------------------------------------------------------------

    const parser_step = b.step("parser", "Regenerate src/parser.zig from rig.grammar");
    const gen_cmd = b.addSystemCommand(&.{
        "../nexus/bin/nexus",
        "rig.grammar",
        "src/parser.zig",
    });
    parser_step.dependOn(&gen_cmd.step);

    // -----------------------------------------------------------------
    // rig executable
    // -----------------------------------------------------------------

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "rig",
        .root_module = main_mod,
    });

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/rig",
    });
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Rig compiler");
    run_step.dependOn(&run_cmd.step);

    // -----------------------------------------------------------------
    // tests
    // -----------------------------------------------------------------

    const test_step = b.step("test", "Run tests");

    const rig_test_mod = b.createModule(.{
        .root_source_file = b.path("src/rig.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rig_tests = b.addTest(.{ .root_module = rig_test_mod });
    const run_rig_tests = b.addRunArtifact(rig_tests);
    test_step.dependOn(&run_rig_tests.step);
}
