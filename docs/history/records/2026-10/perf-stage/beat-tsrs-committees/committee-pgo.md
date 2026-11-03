# LLVM PGO for Trig: measurement (pup, 2026-10-25)

Owner-approved measurement, supervised by Rig (OG). No repository changed. Everything (clones, bitcode, objects, binaries, profiles, scripts, logs) is in `pup:/zfs/trig-pup/trial/pgo/`.

- Rig main `6c3f35b78`, built in `pgo/rig`.
- Trig main `676760a`: `pgo/trig`, with the pack `pgo/pack/src` (`tools/trig/main.rig` plus links to `src/*`, as `tests/lib.rip` makes it) and `misc/projects` copied from `/zfs/trig-pup/full/trig`.

Yesterday's spike (`/zfs/worktrees/rig/pgo-spike/work/pgo-spike.md`, trained on the checker corpus, older mains) found the same route but needed libc for the profile runtime. This run removes that.

## Answer

Yes. LLVM IR PGO through Zig's bitcode works on today's no-libc Trig, with a profile that matches the shipped bitcode exactly (0 hash mismatches, 0 functions without profile data).

Trained on a different project from the one timed, PGO is:
- **10.0–10.5% faster on ts-pattern** with **13.9% fewer instructions**;
- **9.5–10.8% faster on zod3** with **14.9% fewer instructions**.

**PGO + BOLT against BOLT alone** (what Trig ships today):
- **8.6–8.8% faster** on ts-pattern, with 13.4% fewer instructions;
- **4.8–5.6% faster** on zod3, with 14.4% fewer instructions.

BOLT on top of PGO adds 0–1.5% in time, inside the noise, and nothing in instructions.

That clears the speed bar by a wide margin (>2% faster in time, ≥1% fewer instructions). For scale: shipped tsrs runs 7.23G instructions against 8.13G for tsrs built from source; PGO takes Trig from 10.54G to 9.07G.

## The path

1. **Zig 0.17 has no PGO flags.** `zig build-exe --help` lists `-femit-llvm-bc`, `-femit-llvm-ir`, `-flto` and `-fllvm`, but no `-fprofile-*`, and `std.Build` has no PGO option either.
   - `-femit-llvm-bc` writes the unoptimized module (257 MB here).
   - Zig is LLVM 22.1.8. The matching tools are `/usr/lib/llvm-22` (llvm-profdata 22.1.2, `libclang_rt.profile-x86_64.a`), plus `zig cc` (clang 22.1.8) to compile the bitcode.
   - Ubuntu's LLVM 21 cannot read Zig's bitcode. BOLT stays on llvm-21, as Rig's `src/bolt.zig` uses it.
2. **Bitcode and a relocs binary in one run.** In `RIG_OUT_DIR` from `rig build --release`, one Zig run wrote both: `zig build-exe -Osafe __rig_main.zig -femit-llvm-bc=trig.bc -femit-bin=plain-relocs --emit-relocs`. Its `.text` is byte-identical to `rig build --release`'s.
3. **Compile** (`tools/cc.sh`): `zig cc -target x86_64-linux-none -mcpu=native -c -O3 -fno-PIC -fno-PIE -Xclang -fmerge-functions trig.bc`.
   - The instrumented compile adds `-fprofile-generate`; the use compile adds `-fprofile-use=X.profdata`.
4. **Instrumented build with no libc: the new part.** Zig's `_start` exits by `exit_group` and never runs `atexit`, so the profile runtime's file writer never runs. Instead:
   - `tools/pgodump.c` (69 lines, freestanding) supplies what the runtime needs from libc: `calloc`/`malloc` as a bump arena, plus stubs for `getenv`, `strtol`, `stderr`, `__vfprintf_chk` and `__stack_chk_fail`.
   - It also defines `pgo_dump()`, which calls the runtime's own `lprofWriteData` with the value-profile reader and a raw-syscall file writer.
   - It is linked with `libclang_rt.profile-x86_64.a` by Zig's own static link (`zig build-exe OBJ -OReleaseSafe`).
   - `tools/train.sh` runs the instrumented trig under `gdb -batch -ex 'catch syscall exit_group' -ex run -ex 'call pgo_dump()'`, then `llvm-profdata merge`.
   - The instrumented and final builds come from the **same bitcode**, so every name (including Zig's `__func_N` ones) matches. That removes yesterday's libc detour, which cost 5–7% and scrambled about 8,300 names.
   - Each training run was one `trig -p tsconfig.trig.json --noEmit --singleThreaded` of the project, on core 8: 8–10 s under gdb. The profile is 3.3 MB, with 5,194 functions counted.
5. **Link:** `zig build-exe OBJ -OReleaseSafe` (plus `--emit-relocs` for BOLT), under 1 s.
6. **BOLT** (`tools/bolt.sh`): `src/bolt.zig`'s exact perf, perf2bolt and llvm-bolt flags. Each BOLT profile is 3 rounds on the named projects, on core 8.
   - `trig4` is Trig's own `tools/trig/bolt-train` set (mitt, neverthrow, superstruct, zod3): today's shipped layout.

## Numbers

How the numbers were taken (`tools/pgotime.py`):
- `taskset -c 8`, `trig -p tsconfig.trig.json --noEmit --singleThreaded`, fastest of 10, interleaved;
- `perf stat -e cpu_core/instructions/u,cpu_core/cycles/u`;
- pup load was about 2.7–3.1, from other sessions' builds on the release slots; core 9 stayed idle.

Before timing, and on every timed run, each variant's stdout and exit status equalled tsc's at the pin (`tools/check6.py` and `pgotime.py`). All 10 variants are byte-identical to tsc on **all six cli projects**: mitt, neverthrow, superstruct, tiny-invariant, zod3 and ts-pattern.

In one early check pass every variant returned exit 1 under perf stat. It never reproduced, and every later check and timed run matched tsc.

### ts-pattern (profiles trained on zod3; trig4 BOLT never sees ts-pattern)

| variant | wall, pass 1 | wall, pass 2 | instructions | cycles (pass 2) |
|---|---:|---:|---:|---:|
| plain | 1.203 s | 1.211 s | 10.540G | 4.866G |
| BOLT (trig4, as shipped) | 3.1% faster | 3.4% faster | 10.464G (0.7% fewer) | 5.0% fewer |
| BOLT (zod3) | 3.8% faster | — | 10.459G (0.8% fewer) | — |
| **PGO (zod3)** | **10.5% faster** | **10.0% faster** | **9.073G (13.9% fewer)** | 10.7% fewer |
| PGO (zod3) + BOLT (trig4) | 10.9% faster | 11.1% faster | 9.064G (14.0% fewer) | 12.8% fewer |
| PGO (zod3) + BOLT (zod3) | 11.4% faster | 11.1% faster | 9.068G (14.0% fewer) | 13.1% fewer |
| no profile, clang -O3 (control) | 0.5% slower | — | 10.666G (1.2% more) | — |
| PGO self-trained on ts-pattern (overfit control) | — | 11.3% faster | 8.961G (15.0% fewer) | 13.5% fewer |

### zod3 (profiles trained on ts-pattern)

| variant | wall, pass 1 | wall, pass 2 | instructions | cycles (pass 2) |
|---|---:|---:|---:|---:|
| plain | 0.230 s | 0.223 s | 1.908G | 0.865G |
| BOLT (ts-pattern) | 5.0% faster | 6.4% faster | 1.894G (0.8% fewer) | 7.3% fewer |
| **PGO (ts-pattern)** | **10.8% faster** | **9.5% faster** | **1.623G (14.9% fewer)** | 10.9% fewer |
| PGO + BOLT (ts-pattern) | 9.5% faster | 11.0% faster | 1.622G (15.0% fewer) | 12.2% fewer |
| no profile, clang -O3 (control) | 3.8% slower | — | 1.949G (2.1% more) | — |
| PGO self-trained on zod3 (overfit control) | — | 9.8% faster | 1.574G (17.5% fewer) | 12.8% fewer |

### PGO + BOLT against BOLT alone

| project | BOLT alone | PGO + BOLT | time | instructions |
|---|---:|---:|---:|---:|
| ts-pattern (trig4 BOLT) | 1.166 / 1.170 s | 1.072 / 1.077 s | 8.8% / 8.6% faster | 13.4% fewer |
| zod3 (ts-pattern BOLT) | 0.219 / 0.209 s | 0.209 / 0.198 s | 4.8% / 5.6% faster | 14.4% fewer |

Reading it:
- Leaving Zig's pipeline for clang's costs 0.5–3.8% (the no-profile control), so PGO's own effect is about 11–14% in time.
- Training on the other project loses only 1–2.6 points of instructions against self-training, and about nothing in time. Overfitting is not a concern, and a fixed training set (for example Trig's four BOLT projects) is enough.
- PGO lowers IPC (2.17 to 2.11): it removes cheap instructions (inlined calls, folded branches) more than it removes cycles.
- `.text` grows 3–11% (9.87 MB plain; 10.18 MB with the ts-pattern profile, 10.92 MB with zod3's).

## Costs

These are pup CPU times of each step. The waits are not counted: the wall times in the logs include 10–25 minutes of queueing for release slots behind other sessions' builds.

| step | CPU | peak memory |
|---|---:|---:|
| Zig run: bitcode, plus the binary if wanted (today's release build is this run) | about 6.5 min (5 min with `-fno-emit-bin`, from the 2026-10-24 spike) | 8.6 GB |
| `zig cc -fprofile-generate` | 5.6 min | 9.5 GB |
| training, one project, under gdb | 8–10 s | 1.2 GB |
| `llvm-profdata merge` | under 0.1 s | small |
| `zig cc -fprofile-use` | 5.3–6.0 min | 9.7 GB |
| link | under 1 s | under 0.5 GB |

A PGO release build is three LLVM-heavy steps instead of one: about 17 minutes of one core against about 7, with three release slots taken in turn. BOLT, if kept, adds about 1 minute.

**What would live in Rig** (`src/pgo.zig` beside `src/bolt.zig`, with `rig build --release --pgo -- WORKLOAD` as `--bolt` has):
- finding `llvm-profdata` and `libclang_rt.profile` for Zig's LLVM major: about 40 lines;
- the instrumented build (bitcode, `zig cc -fprofile-generate`, the link with the runtime and the dumper): about 50 lines;
- running the workload and merging: about 25 lines;
- the use build and link: about 30 lines;
- the dumper itself: about 70 lines of C, or Zig;
- flags, a CLI test, and docs: about 60 lines.

That is about 270 lines in all.

**gdb can go.** A weak `__rig_pgo_dump` that the runtime calls just before `exit_group` would let the instrumented binary write its own profile. It is null in a normal build: one load and branch at exit. It is in the bitcode on both sides, so names still match. That is a few lines in Rig's runtime.

Standing costs:
- **The build host needs LLVM tools of Zig's LLVM major** (`llvm-22`, on pup now), and they move with every Zig LLVM bump.
- **A profile only fits the bitcode it was trained on** (Zig's `__func_N` names shift with code changes), so every release build trains anew. No profile file is kept in the repository.
- **The Mac is not done.** It would need the macOS profile runtime and llvm-profdata 22 (Homebrew `llvm@22`). Its builds can stay unprofiled.

## Recommendation

**Adopt PGO in Trig's release build.** It is about 10% faster and saves about 14% of single-thread instructions on both projects, trained away from the project timed. That is five times the time bar and fourteen times the instruction bar.

It also beats today's BOLT by 5–9%. Once PGO lands, BOLT is optional: on top of PGO it adds at most noise (0–1.5%). Keep it only if its extra minute of build stays cheap.

Owner of the build pipeline: Rig (`--pgo` in `rig build`, a sibling of `--bolt`). Owner of the training set and the release script: Trig (its `tools/trig/bolt-train` set works as is).

## Files on pup (`/zfs/trig-pup/trial/pgo/`)

- `tools/`:
  - `pgodump.c`: the freestanding profile writer;
  - `cc.sh`, `link.sh`, `train.sh`, `bolt.sh`: the pipeline;
  - `pgotime.py`: timing;
  - `check6.py`: the check against tsc on all six projects.
- `trig.bc`: the bitcode.
- `obj/*.o` and `obj/*.o.log`: the compiles, with their time and memory.
- `prof-{zod3,ts-pattern}{.profdata,/}`: the profiles and gdb logs.
- `bin/{plain,plain-relocs,hand,instr,pgo-zod3,pgo-ts-pattern}` and `bolt/*`: the binaries.
- `times-{ts-pattern,zod3}-{1,2}.md`: the raw timing tables.
- `toy/`: the first proof of the dumper on a small Zig program.
