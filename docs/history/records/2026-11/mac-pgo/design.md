# macOS PGO: design (2026-11-09)

No code yet. The build starts when #1045 lands, since both touch the steps after the link.
The experiment's files are in this session's scratchpad (`macpgo/`): one Rig program that makes tasks (so it is preempted and has `__rig_text`), arm64 Mac.

## What the experiment showed

| Step | Result |
|---|---|
| Zig writes bitcode, `zig cc -fprofile-generate` compiles it | works; Zig's LLVM 22 |
| Link with Zig's linker and Xcode's `libclang_rt.profile_osx.a` | links, runs, writes a raw profile |
| Merge that profile | **fails** in Apple's llvm-profdata (21) and pup's (22): "counter offset 46269160 is greater than the maximum counter offset 78543" |
| Same failure from plain C through `zig cc` and Zig's linker | yes; Apple clang and ld on the same C merge. So it is Zig's Mach-O linker, not Rig and not the LLVM version |
| Same Rig object linked by Apple's `ld` (through `clang`) | runs, merges, 474 functions |
| `zig cc -fprofile-use` (LLVM 22) reads Apple's merged profile (LLVM 21) | no warnings, no mismatches |
| Optimized object linked by Zig's linker | runs and prints the right answer; 441 KB against 541 KB |
| x15 stays reserved | yes: `+reserve-x15` is in every function's target-features in the bitcode; 0 uses of x15 in `__rig_text` |

The raw format is version 10 on both sides. The toy's time is level, as a hash loop should be. Trig has not been tried on the Mac, so there is no gain figure yet.

## Design

**Tools.** `xcrun --find llvm-profdata`, `xcrun --find clang`, and `<toolchain>/usr/lib/clang/*/lib/darwin/libclang_rt.profile_osx.a`. No Homebrew LLVM. Linux's "same LLVM major as Zig" check cannot hold here (Apple 21, Zig 22) and is not needed: a format change after a Zig upgrade fails loudly at the merge, and `rig` reports that.

**Steps.** The same four as Linux, one bitcode. What differs on the Mac:

1. Target `aarch64-macos`, without `-fno-PIC -fno-PIE`. `-mcpu=native+reserve_x15` comes from `pkg.zigFlags`.
2. Both objects go through `keepCodeApart`. Today `pkg.keepsCodeApart()` returns before the `--pgo` branch in `buildCommand`; the `--pgo` check moves first.
3. The instrumented link is Apple's: `clang counted-apart.o dump.o RT -o OUT`. Its only cost is a warning from ld about unwind information in `__rig_text`, captured and dropped. The optimized link stays Zig's, as every Mac build is.
4. The writer. `endProcess` calls `_exit`, so no `atexit` handler runs, and `pgo_dump.c` is Linux's (raw system calls and stubs). The Mac's is two lines in the same file under `#ifdef __APPLE__`: `__llvm_profile_set_filename(RIG_PGO_DIR "/raw-%p.profraw"); __llvm_profile_dump();`. The hook in `writeProfile` is unchanged. It runs after `sched.tearDown`; the counters are in `__DATA` and the runtime's records in libc's heap, so tearing down Rig's memory does not touch them. A test ending in `os.exit` checks that.
5. The refusal of a program that links libc is Linux's only, since a Mac program always links libSystem.

**After the link.** Zig's link, then #1045's `sealDenseGuard` (it re-signs), then `writeDsym`, then `warnFrames`. The `--pgo` path has none of the first two today and gets them. **Seal the instrumented executable too**: unsealed, it never takes the dense-stack paths, their counts are zero, and the optimized build would treat them as cold. This holds on Linux as well, so the build fixes it on both.

Signing needs nothing more: both linkers sign ad hoc, and the seal re-signs. BOLT stays Linux's.

**Where the code goes.** `src/pgo.zig` shares bitcode, merge, `-fprofile-use`, and the stale-profile warnings, and has one host switch for the tools, flags, and instrumented link. `keepCodeApart` is passed in from main.zig. About 40-60 lines, by estimate. The feature still comes out by the same list of deletions.

**Trig's `tools/trig/pgo`.** The `rig build` line needs no change. Its "Linux only" comment goes, and `tools/release-slot` must take no `TRIG_RELEASE_SLOTS` on the Mac (it uses `taskset` only with a slot list). The script reports 20 minutes and near 10 GB on pup, so the Mac build runs under the slot guard.

**Tests.** `test/cli/pgo.sh` runs its build cases on the Mac instead of expecting "needs Linux": a program that makes tasks, a program ending in `os.exit`, a saved profile, a stale profile, and no x15 in `__rig_text` (`llvm-objdump -d --section=__rig_text`).

**Gate.** The usual one: a measured gain on Trig on the Mac, on runs it was not trained on, more than 1.5% faster or at least 1% fewer instructions, and no higher peak memory.

## Not shown yet

Trig's size on this path, the gain, and `os.exit`. The Zig linker fault is worked around, not fixed; it may be worth reporting upstream.
