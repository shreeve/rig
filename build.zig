//! Rig Build Configuration
//!
//! Steps:
//!   zig build              — build bin/rig (with `-p PREFIX`: also PREFIX/bin/rig)
//!   zig build parser       — regenerate src/parser.zig from rig.grammar via Nexus
//!   zig build run -- ...   — run bin/rig with args
//!   zig build test         — run the Zig unit tests (./test/run runs these too)
//!   zig build oracle       — build bin/rig-oracle, the test suite's reference
//!                            ownership checker (test/oracle/)
//!
//! `zig build parser` runs Nexus: `-Dnexus=PATH` (relative to where `zig build`
//! runs), else nexus/bin/nexus in the nearest parent directory (build it with
//! `zig build -Doptimize=safe`).

const std = @import("std");

const version = "0.2.8";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------
    // parser generation step
    // -----------------------------------------------------------------

    const parser_step = b.step("parser", "Regenerate src/parser.zig from rig.grammar");
    // A relative `-Dnexus` names a path from where `zig build` was run.
    const nexus = if (b.option([]const u8, "nexus", "Path to the Nexus binary")) |p|
        b.pathResolve(&.{ std.process.currentPathAlloc(b.graph.io, b.allocator) catch @panic("cannot read the working directory"), p })
    else
        findNexus(b);
    const gen_cmd = b.addSystemCommand(&.{ nexus, "rig.grammar", "src/parser.zig" });
    gen_cmd.setCwd(b.path("."));
    parser_step.dependOn(&gen_cmd.step);

    // -----------------------------------------------------------------
    // rig executable
    // -----------------------------------------------------------------

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    main_mod.addOptions("build_options", options);
    // The standard library's sources, embedded in the compiler.
    main_mod.addImport("rig_std", b.createModule(.{ .root_source_file = b.path("std/embed.zig") }));

    const exe = b.addExecutable(.{
        .name = "rig",
        .root_module = main_mod,
    });

    // bin/rig in the checkout, where ./test/run and the docs expect it,
    // and PREFIX/bin/rig (zig-out/bin/rig without `-p`).
    const checkout_bin = b.addUpdateSourceFiles();
    checkout_bin.addCopyFileToSource(exe.getEmittedBin(), "bin/rig");
    b.getInstallStep().dependOn(&checkout_bin.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the Rig compiler");
    run_step.dependOn(&run_cmd.step);

    // -----------------------------------------------------------------
    // tests
    // -----------------------------------------------------------------

    const test_step = b.step("test", "Run the Zig unit tests of the compiler and the runtime");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = main_mod })).step);

    // -----------------------------------------------------------------
    // the reference ownership checker (test only)
    // -----------------------------------------------------------------

    // The oracle reaches the compiler through src/lib.zig; bin/rig never
    // imports it.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("rig_std", b.createModule(.{ .root_source_file = b.path("std/embed.zig") }));
    const oracle_exe = b.addExecutable(.{
        .name = "rig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/oracle/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "rig_lib", .module = lib_mod }},
        }),
    });
    const oracle_bin = b.addUpdateSourceFiles();
    oracle_bin.addCopyFileToSource(oracle_exe.getEmittedBin(), "bin/rig-oracle");
    b.step("oracle", "Build bin/rig-oracle, the reference ownership checker").dependOn(&oracle_bin.step);
}

/// `nexus/bin/nexus` in the nearest parent directory of the build root
/// that has one (the checkout's sibling, also from nested git worktrees).
/// The configuration is cached: a found binary is a declared input, and
/// without one every `zig build` looks again.
fn findNexus(b: *std.Build) []const u8 {
    var dir: []const u8 = b.pathResolve(&.{b.fmt("{f}", .{b.root})});
    while (std.fs.path.dirname(dir)) |parent| : (dir = parent) {
        const candidate = b.pathJoin(&.{ parent, "nexus", "bin", "nexus" });
        std.Io.Dir.cwd().access(b.graph.io, candidate, .{}) catch continue;
        b.dependOnFileMetadata(.{ .cwd_relative = candidate });
        return candidate;
    }
    b.graph.poisonCache();
    return "../nexus/bin/nexus";
}
