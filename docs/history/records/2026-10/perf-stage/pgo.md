# Profile-guided optimization: measured and built (2026-10-25)

The question: tsrs ships with PGO, LTO, and BOLT, and its shipped build runs 11% fewer instructions than its source build on ts-pattern (7.23G against 8.13G). Can Rig build Trig with LLVM's PGO on top of BOLT, and what is it worth? The owner approved the measurement, and then the build (`rig build --release --pgo`, branch `pgo`).

## The path

Zig 0.17 has no PGO flag: `zig build-exe --help` lists `-femit-llvm-bc`, `-femit-llvm-ir`, and `-flto`, but no `-fprofile-*`, and `std.Build` has no PGO option either. So the build takes Zig's bitcode and finishes it with Zig's clang and linker:

1. `zig build-exe -Osafe ... -femit-llvm-bc=program.bc -fno-emit-bin`. This is the unoptimized module; Trig's is 257 MB.
2. `zig cc -target x86_64-linux-none -mcpu=native -c -O3 -fno-PIC -fno-PIE -Xclang -fmerge-functions -fprofile-generate program.bc`.
3. Link that with Zig's own static link (`zig build-exe OBJ -Osafe`), adding LLVM's `libclang_rt.profile` and a profile writer.
4. Run the workload, then `llvm-profdata merge`.
5. Compile the same bitcode with `-fprofile-use` and link it with Zig.

Zig 0.17 is LLVM 22.1.8. pup has LLVM 22's tools (`/usr/lib/llvm-22`: llvm-profdata 22.1.2 and the profile runtime). Ubuntu's LLVM 21 cannot read Zig's bitcode.

**A program without libc.** LLVM's runtime writes its profile from `atexit`, which never runs in a Zig program without libc: Zig's start code and Rig's runtime end with `exit_group`. An earlier spike (2026-10-24) linked libc to get `atexit`. That cost 5-7%, and it changed Zig's analysis order: Zig numbers about half of all functions (`__func_N`), so 8,300 names of the no-libc build were missing from the profile.

The build instead links `src/pgo_dump.c`. It is freestanding: the runtime's few C calls (`calloc` from an arena, the rest stubs), plus `__rig_pgo_dump`, which writes the profile with the runtime's own `lprofWriteData` by raw system calls. Rig's runtime calls it as the program ends (`writeProfile`: the end of `main`, `os.exit`, a closed stdout).

The instrumented and optimized builds read one bitcode, so the profile fits exactly: 0 hash mismatches, 0 functions without data.

The measurement below drove the writer from gdb at `exit_group`; the built feature calls it from the runtime.

## Measured (pup, before the build: Rig `6c3f35b78`, Trig `676760a`)

Each cell is the fastest of 10 runs, interleaved, on core 8 (its sibling idle). Each run is `trig -p tsconfig.trig.json --noEmit --singleThreaded`, under `perf stat -e cpu_core/instructions/u,cpu_core/cycles/u`. Every variant's stdout and exit status are byte-identical to tsc's on all six cli projects.

Each profile was trained on the other project from the one timed, one run under the instrumented build. "trig4" is Trig's own BOLT workload (mitt, neverthrow, superstruct, zod3), which never runs ts-pattern.

ts-pattern, profiles trained on zod3:

| variant | wall (two passes) | instructions | cycles |
|---|---:|---:|---:|
| release | 1.203 / 1.211 s | 10.540G | 4.866G |
| BOLT (trig4, as Trig ships) | 3.1 / 3.4% faster | 10.464G (0.7% fewer) | 5.0% fewer |
| **PGO (zod3)** | **10.5 / 10.0% faster** | **9.073G (13.9% fewer)** | 10.7% fewer |
| PGO + BOLT (trig4) | 10.9 / 11.1% faster | 9.064G (14.0% fewer) | 12.8% fewer |
| clang -O3 with no profile (control) | 0.5% slower | 10.666G (1.2% more) | |
| PGO trained on ts-pattern itself | 11.3% faster | 8.961G (15.0% fewer) | 13.5% fewer |

zod3, profiles trained on ts-pattern:

| variant | wall (two passes) | instructions | cycles |
|---|---:|---:|---:|
| release | 0.230 / 0.223 s | 1.908G | 0.865G |
| BOLT | 5.0 / 6.4% faster | 1.894G (0.8% fewer) | 7.3% fewer |
| **PGO** | **10.8 / 9.5% faster** | **1.623G (14.9% fewer)** | 10.9% fewer |
| PGO + BOLT | 9.5 / 11.0% faster | 1.622G (15.0% fewer) | 12.2% fewer |
| clang -O3 with no profile (control) | 3.8% slower | 1.949G (2.1% more) | |
| PGO trained on zod3 itself | 9.8% faster | 1.574G (17.5% fewer) | 12.8% fewer |

**PGO + BOLT against BOLT alone:** 8.6-8.8% faster on ts-pattern (13.4% fewer instructions), and 4.8-5.6% faster on zod3 (14.4% fewer).

BOLT on top of PGO adds 0-1.5%, inside the noise, and nothing in instructions.

Reading it:
- Leaving Zig's pipeline for clang's costs 0.5-3.8% (the control), so the profile itself is worth 11-14%.
- Training on the other project costs about 1-2.6 points of instructions against training on the project itself, and nothing measurable in time.
- `.text` grows 3-11%.

## Cost

These are CPU times on one pup P-core, for Trig. Each Zig or clang step peaks at 8.5-9.7 GB.

| step | time |
|---|---:|
| the bitcode | about 5 min |
| the instrumented compile | 5.6 min |
| training | seconds per project |
| the optimized compile | 5.3-6.0 min |
| each link | under 1 s |

That is about 17 minutes against 7 for a plain release build.

Standing costs:
- The build host needs `llvm-profdata` and the profile runtime of Zig's LLVM major (Ubuntu's `llvm-22` and `libclang-rt-22-dev`), and they move with every Zig LLVM bump.
- A profile fits only the program it was trained on, so a release build trains each time. A saved one (`--pgo-profile`) is used for the functions that did not change.
- The feature is Linux only, for programs that link no C library.

## What was built

- `rig build --release --pgo -- WORKLOAD`, and `--pgo-profile=FILE` to keep the profile or build by it. This is `src/pgo.zig` and `src/pgo_dump.c`.
- The runtime's `writeProfile` is compiled only into a package whose root declares `__rig_pgo`, which only `--pgo` writes. Both `--pgo` links define `__rig_pgo_dump`, as the writer or as a function that does nothing. A weak symbol did not work: Zig's front end takes a weak extern function's address as non-null and drops the test.
- **Every other build is unchanged.** `tools/emit-diff origin/main` finds every module's Zig identical, with only `rig/runtime.zig` 18 lines longer, all of it compiled out without `--pgo`. Trig built in release by main and by the branch has the same `.text`, `.rodata`, and `.data` (below).
- test/cli/pgo.sh covers:
  - the usage errors;
  - the error for missing tools, which names Zig's LLVM version;
  - the optimized program printing what the plain one does;
  - no counters left in the optimized program, and no working files;
  - a saved profile reused without a warning;
  - a changed program warned about but built;
  - a program that ends by `os.exit` writing its profile.

## End to end, as built (pup, Rig `pgo` at its PR on Trig `0636f99`)

Three Trig builds:
- **main:** `rig build --release` by Rig main `57b0360fe`;
- **branch:** the same command by the branch;
- **pgo:** the branch with `--release --pgo -- tools/trig/bolt-train BIN`. That is Trig's BOLT workload: mitt, neverthrow, superstruct and zod3, three rounds, with default checkers. It never runs ts-pattern or tiny-invariant.

All three are byte-identical to tsc on the six cli projects. main and branch have the same `.text` (9,967,145 bytes), `.rodata`, and `.data`.

The pgo build took 17 minutes on a release slot, against 6.5 for main's, and peaked at 9.8 GB.

Timing: fastest of 10, interleaved, core 8, `--singleThreaded`, with pup at load 3.4-4.6 from other sessions' builds.

| project | main | pgo | instructions | cycles |
|---|---:|---:|---:|---:|
| ts-pattern (pass 1) | 1.218 s | 7.6% faster | 13.2% fewer (10.359G to 8.995G) | 6.5% fewer |
| ts-pattern (pass 2) | 1.186 s | **10.1% faster** | 13.2% fewer | 11.0% fewer |
| tiny-invariant | 0.109 s | **11.0% faster** | 13.9% fewer | 11.2% fewer |
| zod3 (in the training set) | 0.228 s | 9.6% faster | 15.6% fewer | 10.2% fewer |

In pass 2, the measurement's binary (trained on zod3 alone, older mains) ran 9.6% faster than main with 12.4% fewer instructions. The built feature matches the measurement.
