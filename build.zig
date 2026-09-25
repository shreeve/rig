//! Rig Build Configuration
//!
//! Steps:
//!   zig build              — build bin/rig (with `-p PREFIX`: PREFIX/bin/rig)
//!   zig build parser       — regenerate src/parser.zig from rig.grammar via Nexus
//!   zig build run -- ...   — run bin/rig with args
//!   zig build test         — run the Zig unit tests (./test/run runs these too)
//!
//! `zig build parser` runs Nexus: `-Dnexus=PATH`, else nexus/bin/nexus in the
//! nearest parent directory (build it with `zig build -Doptimize=ReleaseSafe`).

const std = @import("std");

const version = "0.1.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------
    // parser generation step
    // -----------------------------------------------------------------

    const parser_step = b.step("parser", "Regenerate src/parser.zig from rig.grammar");
    const nexus = b.option([]const u8, "nexus", "Path to the Nexus binary") orelse findNexus(b);
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

    const exe = b.addExecutable(.{
        .name = "rig",
        .root_module = main_mod,
    });

    // Without `--prefix`, bin/rig in the checkout, where ./test/run and
    // the docs expect it.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = if (std.mem.eql(u8, b.install_prefix, default_prefix)) .{ .override = .{ .custom = "../bin" } } else .default,
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

    const test_step = b.step("test", "Run the Zig unit tests of the compiler and the runtime");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = main_mod })).step);
}

/// `nexus/bin/nexus` in the nearest parent directory of the build root
/// that has one (the checkout's sibling, also from nested git worktrees).
fn findNexus(b: *std.Build) []const u8 {
    const root = b.build_root.path orelse ".";
    var dir: []const u8 = b.pathResolve(&.{root});
    while (std.fs.path.dirname(dir)) |parent| : (dir = parent) {
        const candidate = b.pathJoin(&.{ parent, "nexus", "bin", "nexus" });
        std.Io.Dir.cwd().access(b.graph.io, candidate, .{}) catch continue;
        return candidate;
    }
    return "../nexus/bin/nexus";
}
