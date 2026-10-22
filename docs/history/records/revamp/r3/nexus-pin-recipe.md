# Nexus pin through Zig's package manager (recipe from the Nexus session, 2026-10-10)

Tested with Zig 0.17.0 and Nexus v2.2.0. No Nexus changes needed.

1. Pin the release: `zig fetch --save=nexus "git+https://github.com/shreeve/nexus#v2.2.0"`.
   - This adds `.nexus` (url plus hash) to build.zig.zon.
   - The first fetch needs the network; after that it comes from the cache.
2. Add this to build.zig:
```zig
const nexus = b.dependency("nexus", .{ .optimize = .ReleaseFast }).artifact("nexus");
const install_nexus = b.addInstallArtifact(nexus, .{});
b.step("nexus", "Install the pinned Nexus to zig-out/bin/nexus").dependOn(&install_nexus.step);
const gen = b.addRunArtifact(nexus);
gen.addFileArg(b.path("rig.grammar"));
const out = gen.addOutputFileArg("parser.zig");
_ = gen.captureStdErr(.{});
const update = b.addUpdateSourceFiles();
update.addCopyFileToSource(out, "src/parser.zig");
b.step("parser", "Regenerate src/parser.zig with the pinned Nexus").dependOn(&update.step);
```
3. Test runner: run `zig build nexus` first, then point `./test/run`'s freshness check and `$NEXUS`'s default at `zig-out/bin/nexus`.
4. To upgrade:
   - re-run `zig fetch` with the new tag;
   - run `zig build parser`;
   - commit build.zig.zon and src/parser.zig together.

   CI follows build.zig.zon, so the separate ref in shards.yml (and its Nexus cache step) can go. Keep `-Dcpu=baseline` concerns in mind: zig-built deps compile per runner, so the old cache issue doesn't apply.

Verified behaviour:
- the output is byte-identical to v2.2.0's;
- it is silent on success;
- a grammar error fails the build with `file:line:col`.

Nexus 2.3.0 may add its own build.zig.zon. The recipe above works either way.

Rig-side work: `zig build parser`'s current `-Dnexus=PATH` option, AGENTS.md's Nexus paragraph, test/README, the CI workflow.
