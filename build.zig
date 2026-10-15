//! Rig Build Configuration
//!
//! Steps:
//!   zig build              — build bin/rig (with `-p PREFIX`: also PREFIX/bin/rig)
//!   zig build parser       — generate src/parser.zig from rig.grammar via Nexus
//!                            (every other step does this first; it is not tracked)
//!   zig build run -- ...   — run bin/rig with args
//!   zig build test         — run the Zig unit tests (./test/run runs these too)
//!   zig build oracle       — build bin/rig-oracle, the test suite's reference
//!                            ownership checker (test/oracle/)
//!
//! src/parser.zig is generated, not committed. Nexus runs again only when
//! rig.grammar or the Nexus binary changes. The binary is `-Dnexus=PATH`
//! (relative to where `zig build` runs), else the path in the environment
//! variable NEXUS, else nexus/bin/nexus in the nearest parent directory
//! (build it with `zig build -Doptimize=safe`).

const std = @import("std");

const version = "0.2.9";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default: every safety check on, and about ten times
    // the speed of a debug build. `-Doptimize=debug` builds for compiler
    // work; `--release=fast` and `--release=small` are honored.
    const optimize: std.builtin.Optimize = b.option(std.builtin.Optimize, "optimize", "Prioritize performance, safety, or binary size (default: safe)") orelse switch (b.graph.release_mode) {
        .off, .any, .safe => .safe,
        .fast => .fast,
        .small => .small,
    };
    // The compiler's own consistency checks (facts.check_units, sema's
    // binding-access check): on in a debug build, and wherever
    // `-Dself-check=true` asks for them, as ./test/run does.
    const self_check = b.option(bool, "self-check", "Run the compiler's own consistency checks (default: in debug builds)") orelse (optimize == .debug);

    // -----------------------------------------------------------------
    // parser generation step
    // -----------------------------------------------------------------

    const parser_step = b.step("parser", "Generate src/parser.zig from rig.grammar");
    // `null` when Nexus is missing: the failing step below stops every target.
    const nexus: ?[]const u8 = if (b.option([]const u8, "nexus", "Path to the Nexus binary")) |p|
        b.pathResolve(&.{ std.process.currentPathAlloc(b.graph.io, b.allocator) catch @panic("cannot read the working directory"), p })
    else
        nexusFromEnv(b) orelse findNexus(b);
    // Every compile step depends on `parser_gen`.
    const parser_gen: *std.Build.Step = blk: {
        const path = nexus orelse {
            const fail = b.addFail("cannot generate src/parser.zig: Nexus not found.\n" ++
                "Looked for nexus/bin/nexus in every parent directory of the Rig checkout (normally ../nexus/bin/nexus).\n" ++
                "Get it: git clone https://github.com/shreeve/nexus ../nexus && (cd ../nexus && zig build -Doptimize=safe)\n" ++
                "or name a binary: zig build -Dnexus=PATH, or NEXUS=PATH zig build");
            parser_step.dependOn(&fail.step);
            break :blk &fail.step;
        };
        // The Nexus binary and the grammar are the run's inputs, so the
        // output is cached until either changes.
        // Nexus reports progress on stderr; the wrapper shows it only on failure.
        const gen = std.Build.Step.Run.create(b, "nexus rig.grammar");
        gen.addArgs(&.{ "sh", "-c", "\"$@\" 2>\"$3.log\" || { cat \"$3.log\" >&2; exit 1; }", "nexus" });
        gen.addFileArg(.{ .cwd_relative = path });
        gen.addFileArg(b.path("rig.grammar"));
        const out = gen.addOutputFileArg("parser.zig");
        const place = b.addUpdateSourceFiles();
        place.addCopyFileToSource(out, "src/parser.zig");
        parser_step.dependOn(&place.step);
        break :blk &place.step;
    };

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
    options.addOption(bool, "self_check", self_check);
    main_mod.addOptions("build_options", options);
    // The standard library's sources, embedded in the compiler.
    main_mod.addImport("rig_std", b.createModule(.{ .root_source_file = b.path("std/embed.zig") }));

    const exe = b.addExecutable(.{
        .name = "rig",
        .root_module = main_mod,
    });
    exe.step.dependOn(parser_gen);

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
    const unit = b.addTest(.{ .root_module = main_mod });
    unit.step.dependOn(parser_gen);
    test_step.dependOn(&b.addRunArtifact(unit).step);

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
    lib_mod.addOptions("build_options", options);
    const oracle_exe = b.addExecutable(.{
        .name = "rig-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/oracle/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "rig_lib", .module = lib_mod }},
        }),
    });
    oracle_exe.step.dependOn(parser_gen);
    const oracle_bin = b.addUpdateSourceFiles();
    oracle_bin.addCopyFileToSource(oracle_exe.getEmittedBin(), "bin/rig-oracle");
    b.step("oracle", "Build bin/rig-oracle, the reference ownership checker").dependOn(&oracle_bin.step);
}

/// The Nexus binary named by the environment variable NEXUS (cpuq's packs
/// set it), relative to where `zig build` runs. The configuration cache does
/// not see the environment, so reading it poisons the cache. Null when NEXUS
/// is unset or empty.
fn nexusFromEnv(b: *std.Build) ?[]const u8 {
    const p = b.graph.environ_map.get("NEXUS") orelse return null;
    if (p.len == 0) return null;
    b.graph.poisonCache();
    return b.pathResolve(&.{ std.process.currentPathAlloc(b.graph.io, b.allocator) catch @panic("cannot read the working directory"), p });
}

/// `nexus/bin/nexus` in the nearest parent directory of the build root
/// that has one (the checkout's sibling, also from nested git worktrees).
/// The configuration is cached: a found binary is a declared input, and
/// without one every `zig build` looks again. Null when there is none.
fn findNexus(b: *std.Build) ?[]const u8 {
    var dir: []const u8 = b.pathResolve(&.{b.fmt("{f}", .{b.root})});
    while (std.fs.path.dirname(dir)) |parent| : (dir = parent) {
        const candidate = b.pathJoin(&.{ parent, "nexus", "bin", "nexus" });
        std.Io.Dir.cwd().access(b.graph.io, candidate, .{}) catch continue;
        b.dependOnFileMetadata(.{ .cwd_relative = candidate });
        return candidate;
    }
    b.graph.poisonCache();
    return null;
}
