# revamp-base: the "before" baseline of the cleanup round (2026-11-24)

Rig - Final, for Rig (foreman), with the owner's approval. This records the state of Rig at the tag `revamp-base`
(645996606, main after #1251), which the owner's milestone made the before state of the cleanup round. Every number
here is for exactly that commit, and every command used is in `data/cmds/`, so a later step can rerun it and compare.
Large artifacts are kept outside git, in `~/Data/Code/Claude/rig/rig/revamp-base/` on the Mac: the emitted Zig, Trig's
source as measured, the bench builds and a Trig binary.

## Toolchain and machines

| | Mac (pop) | pup | burst |
|---|---|---|---|
| machine | Apple M5, 10 cores, macOS (Darwin 27.2) | Core Ultra 9 185H, Linux x86-64; timing on P-cores 0-11 | Google Compute, 96 threads, Linux x86-64 |
| Zig | 0.17.0 | 0.17.0 | 0.17.0 |
| Nexus | 2.3.1 (2c598ce), built `-Doptimize=safe` | 2.3.1 (2c598ce) | 2.3.1 (2c598ce) |
| used for | build, core suite, emit snapshot, guards, compiler and bench timing, loco's light gate | build, compiler and bench timing (slots 758 and 759), Trig's light gate | the full suite |

- **Nexus 2.3.1** was released for this baseline (nexus#80, tag `v2.3.1`), so all three machines build from one
  commit. Before it they ran 2.3.0 from three different commits. The parser every one of them generates from
  `rig.grammar` is the same: `src/parser.zig` sha256 732d20a8… under 2.3.1 (3020ba85… under 2.3.0, which differs only
  in the version line). pup's `bin/rig` was byte-identical under the two.
- **Zig on the Mac:** a shell whose PATH puts mise's 0.17.1 ahead of its shims runs 0.17.1 even in this checkout,
  whose `mise.toml` pins 0.17.0. Every Mac command here ran with 0.17.0's `bin` first on PATH (`data/cmds/mac-chain.sh`).
  A first pass under 0.17.1 was thrown away. Its emit snapshot was byte-identical to 0.17.0's; nothing else was kept.
- **Trig:** 950f14b3 (Trig main), with its generated modules `libtrees` and `buildinfo` made by
  `tools/trig/gen-libtrees` with revamp-base's `bin/rig`, and laid out as `tools/emit-diff` lays it out (Trig's
  `src/` with `tools/trig/main.rig` beside it). Trig pins b4d9e7247; every Trig step here overrides that pin.

## 1. Build

`data/cmds/build-time.sh 2`: two clean `zig build`s (ReleaseSafe, the default), each after removing `.zig-cache`,
`zig-out` and `bin/rig`, with the global Zig cache kept.

| | build 1 | build 2 | warnings | `bin/rig` |
|---|---:|---:|---:|---:|
| Mac | 86.3 s | 85.9 s | 0 | 11,601,472 bytes |
| pup (P-cores 0-11, slot 758) | 156.6 s | 156.2 s | 0 | 46,911,280 bytes |

On the Mac the two builds' `bin/rig` differ in their bytes (sha256 f4495803… and 1806f2fa…), at the same size. On pup every
rebuild was byte-identical (eb2a1a21…), the slot's two included. Where the Mac's differ was not traced. pup's
`bin/rig` is four times the Mac's because its debug information stays in the executable.

## 2. Correctness

| check | where | result |
|---|---|---|
| core suite, `tools/heavy swarm test/rig.rip -w 4 -q` | Mac | run 1: 12,743 jobs, none died, 937 s (cold: 122 s building `rig` and `rig-oracle`, 53 packs); run 2: 12,690 jobs, none died, 393 s (packs cached). Load 5-8 from other sessions. |
| full suite, `swarm test/rig.rip all -w 64` | burst | run 1: 12,783 jobs, 415 s cold (214 s build); run 2: 12,783, none died, 126 s; run 3: 12,730 (packs cached), none died, 124 s |
| doc examples | | 1,137 `rig` blocks in 33 docs: 668 plain, 441 `reject`, 19 `file=` modules, 7 `pending`, 1 `fragment`, 1 `facts`; 1,118 doc jobs (the modules join their program) |
| oracle | | `test/oracle/rejections` 5,160 functions; `coverage` floors: tests 23,291, docs 1,201, matrix 71,945; `differences` 142 entries (359 lines with comments), all `prod-rejects`; `agreement` 2 |
| Trig's light gate (`tools/pup-rig 645996606`, `tools/light`) | pup | GREEN in 198 s, 119 of 119 jobs |
| loco's light gate (`rig/tools/light`) | Mac | GREEN in 287 s: unit tests 7 passed, checks 51 passed, 122 runs, 0 differ from the Rust loc |

burst's run 1 lost three jobs to burst's own environment, not to Rig: its `env.sh` sets `RIG_NO_CRASH_REPORT=1`, and
`cli.no_crash_report`, `std-misc.033` and `std-misc.033r` test the variable unset. They pass with it unset, as in
runs 2 and 3. `all` here runs 12,783 jobs, 40 more than the core.

## 3. The emit snapshot

`data/cmds/emit-snapshot.py OUT`: every program `tools/emit-diff` emits, emitted as it emits them (`rig emit` with
`RIG_OUT_DIR`, and `RIG_STD` and `RIG_BUILD_STORE` unset), into a fixed directory, with a sha256 manifest.

- **38 programs, 1,067 files, none failed:** the 14 examples, every Rig program under `bench/` (22), the program that
  uses every std module (22 modules), and Trig.
- **The manifest** is `data/emit/MANIFEST` (its own sha256 4d34a698f47f92a2…), and each program's exit status is in
  `data/emit/STATUS`. The emitted files are in `~/Data/Code/Claude/rig/rig/revamp-base/emit/` (127 MB).
- **Reproducible at a fixed path:** a second emit into the same directory gave an identical manifest.
- **`tools/emit-diff revamp-base` against itself is not clean.** Two findings:
  1. Trig's `libtrees.zig` differs in all 351 of its embed lines. Each names its embedded file by absolute path under
     the emit directory (`rig.Embed(..., "/…/rig-emit-diff.X/base/trig/__rig_embed/…")`), and emit-diff emits the two
     sides into different directories. Every other file is identical.
  2. emit-diff has not been comparing Trig. Trig's `libtrees` and `buildinfo` modules are generated and never checked
     in, so a Trig checkout has neither, and emit-diff reports Trig as "not compared" (`emit fails with both`). The
     snapshot generates them first (`tools/trig/gen-libtrees`).

## 4. Compiler speed

### bench/check/guard.py (Mac, two runs)

| | run 1 | run 2 | `guard.txt` |
|---|---:|---:|---:|
| instructions (fewest of 7) | 2,187,498,651 (1.4% above) | 2,196,579,644 (1.8% above) | 2,157,462,149 |
| load | 4.1 | 4.1 | |
| scaling exponents (modules, variants, fields, funcs, stmts) | 1.02 1.01 1.00 1.01 1.00 | 1.02 1.00 1.01 1.00 1.01 | limit 1.15 |
| pass total, best of 7 | 107.7 ms | 109.7 ms | 101.4 ms |

Each pass, best of 7, run 1 / run 2 (ms): lex and parse 14.5 / 14.8, resolve 12.5 / 12.7, typecheck 20.5 / 21.0,
storage 29.0 / 29.1, ownership 12.0 / 11.8, proofs 7.7 / 7.5, inlining 6.5 / 6.8, other 3.6 / 3.5. The Mac was at a
load of 4.1 from other sessions' work, which the guard counts in its instructions, so both runs sit above the
committed baseline. Both pass the 2% gate.

### `rig check --time` on Trig (best of 7, two sets)

`data/cmds/trig-check.sh RIG TRIGDIR 7`, then `data/cmds/check-best.py`. Times in ms.

| pass | Mac set 1 | Mac set 2 | spread | pup set 1 | pup set 2 | spread |
|---|---:|---:|---:|---:|---:|---:|
| lex and parse | 146.2 | 146.8 | 0.4% | 273.3 | 271.6 | 0.6% |
| resolve | 151.3 | 149.0 | 1.5% | 208.9 | 208.0 | 0.4% |
| typecheck | 711.3 | 705.1 | 0.9% | 1,042.9 | 1,037.2 | 0.6% |
| storage | 655.4 | 656.4 | 0.2% | 929.7 | 931.0 | 0.1% |
| ownership | 252.1 | 246.8 | 2.2% | 381.1 | 378.6 | 0.7% |
| proofs | 61.2 | 59.8 | 2.3% | 92.1 | 90.9 | 1.3% |
| inlining | 75.7 | 74.3 | 1.9% | 110.4 | 109.5 | 0.9% |
| other | 37.4 | 37.3 | 0.2% | 76.1 | 74.5 | 2.1% |
| total | 2,107.7 | 2,083.7 | 1.1% | 3,124.5 | 3,115.9 | 0.3% |
| wall | 2.1 s | 2.1 s | 1.0% | 3.2 s | 3.2 s | 0.0% |
| peak RSS | 673.6 MB | 673.6 MB | 0.0% | 610.2 MB | 610.1 MB | 0.0% |

### Trig's release build

`data/cmds/trig-build.sh`: `rig build --release -o trig main.rig` into a fresh `RIG_OUT_DIR`, with `ZIG` pointed at
`data/cmds/zigtime`, which logs each Zig call's wall time.

| | build 1 | build 2 | of which Zig | Trig binary | frame warnings |
|---|---:|---:|---|---:|---:|
| Mac | 668.1 s | 549.3 s | 661.7 s, 543.1 s (one `build-obj`, then `build-exe` links in 0.2 s) | 29,709,424 bytes | 34 |
| pup (P-cores 0-11, slot 759) | 1,053.4 s | 1,038.6 s | 1,049.1 s, 1,034.3 s (one `build-exe`) | 166,216,800 bytes | 33 |

The Mac's two builds are 22% apart, in Zig's single LLVM job. Other sessions' work kept the Mac's load at 4 to 8 (the
logs' first lines give it), so the Mac's figures are a range, not a point. pup's two are 1.4% apart; its Trig binary is larger because the Linux build keeps its debug
information in the executable, where the Mac's goes to `trig.dSYM`. pup's two binaries differ in size by 8 bytes
(166,216,800 and 166,216,808): a Trig release build is not reproducible byte for byte either. On pup's E-cores 12-19 (`prep.sh`, not part of the record's timing) one build took 2,035 s. The frame warnings are `rig build --release`'s, for functions whose frame passes a page
because of what is inlined into them (`data/logs/mac-trig-build-warnings.log`).

## 5. Generated code

### The instruction guards (Mac, two runs each, against their committed `guard.txt`)

- **json** (`bench/json/guard.py`, the corpus linked from the main checkout): instructions per byte, run 1 / run 2:
  twitter 6.2312 / 6.2308, twitterescaped 7.4053 / 7.4077, canada 14.7811 / 14.7895, citm_catalog 6.0390 / 6.0380,
  gsoc-2018 2.8980 / 2.8976, github_events 5.2550 / 5.2535. Every row within 0.1% of its baseline.
- **hash** (`bench/hash/guard.py`): every `Map` and `HashMap` row within 0.2% of its baseline or below it, except
  `map int-churn` (0.6% fewer) and `map text-churn` (1.1% and 1.3% fewer). Both runs are in `data/logs/`.
- **text** (`bench/text/guard.py`): every row within 0.03% of its baseline.
- **print** (`bench/print/guard.py`): 61 bytes of code per print site, both runs, against a bound of 78.

### The concurrency benches (rig-safe, `--time-only` on builds made once)

**Mac** (each bench's default reps; http with 5,000 idle connections):

| bench | run 1 | run 2 |
|---|---|---|
| tasks | spawn 85 ns, chain 25 ns, fanout 71.1 ms, yield 6 ns, hog 118 ns, produce 5.2 ms, memory 16.6 KiB | spawn 154 ns, chain 25 ns, fanout 68.8 ms, yield 7 ns, hog 96 ns, produce 5.2 ms, memory 16.6 KiB |
| actors | solo 5.1 ns, contend 15 ns, spread 0.9 ns | solo 5.1 ns, contend 14 ns, spread 0.8 ns |
| net | pingpong 16.63 us, echo 5.85 us, connect 49.52 us | pingpong 16.55 us, echo 5.93 us, connect 50.95 us |
| http | 154,366 req/s, p50 397 us, p99 688 us, 16.7 KiB per idle conn | 154,076 req/s, p50 399 us, p99 668 us, 16.7 KiB |

The Mac's `spawn` moves from 85 to 154 ns between runs, as it has before (the first program after an idle spell
reads low); `hog` moves 96-118 ns. Read both as ranges.

**pup** (P-cores 0-11, slot 758; http with 10,000 idle connections):

| bench | run 1 | run 2 |
|---|---|---|
| tasks | spawn 105 ns, chain 47 ns, fanout 59.6 ms, yield 6 ns, hog 160 ns, produce 5.1 ms, memory 4.6 KiB | spawn 112 ns, chain 48 ns, fanout 59.6 ms, yield 6 ns, hog 166 ns, produce 5.4 ms, memory 4.6 KiB |
| actors | solo 12 ns, contend 19 ns, spread 1.8 ns | solo 11 ns, contend 19 ns, spread 1.9 ns |
| net | pingpong 4.95 us, echo 936 ns, connect 26.19 us | pingpong 4.89 us, echo 969 ns, connect 25.76 us |
| http | 964,151 req/s, p50 52 us, p99 228 us, 4.8 KiB per idle conn | 953,866 req/s, p50 52 us, p99 241 us, 4.8 KiB |

Slot 758 ran 21:19:55 to 21:26:32 and slot 759 21:27:13 to 22:02:05, both with nothing of this baseline paused. The
guard paused 8 outside builds that started during 759 and resumed them at its close; none ran on a timed P-core.

## 6. Structure

`data/cmds/structure.py`: the tracked files at revamp-base, by area and language (`data/structure.md` has every row).

| area | language | files | lines | code (no blanks or comment lines) |
|---|---|---:|---:|---:|
| compiler (src/, with rig.grammar) | Zig | 29 | 102,736 | 74,380 |
| | grammar | 1 | 1,466 | 935 |
| runtime (src/runtime, sched, tasks, net, alloc, ordered, unordered) | Zig | 7 | 37,342 | 25,506 |
| std/ | Rig | 41 | 12,767 | 8,277 |
| | Zig | 24 | 10,361 | 8,973 |
| tests (test/) | Rig tests (`.rig.test`) | 197 | 1,340,943 | 1,275,536 |
| | shell | 170 | 18,088 | 13,413 |
| | Zig (the oracle) | 8 | 8,246 | 6,037 |
| | Python | 13 | 7,043 | 5,661 |
| docs (root and docs/, not history) | Markdown | 55 | 62,550 | |
| docs/history/ | Markdown | 1,265 | 217,291 | |
| tools/ | Python | 36 | 14,639 | 12,572 |
| formal/ | Lean | 32 | 9,372 | 8,187 |
| bench/ | Zig, Python, Rig, Rust, Go | 135 | 19,374 | |

The 20 largest source files, by lines: test/rig/probes-10.rig.test 1,071,868 (generated probes, 80% of the tests'
lines); src/typecheck.zig 26,390; src/sema.zig 19,539; SPEC.md 16,119; src/emit.zig 12,537; src/runtime.zig 12,333;
src/sched.zig 11,482; test/rig/ownership-misc-1.rig.test 11,051; src/ownership.zig 9,768; test/rig/probes-29.rig.test
8,359; test/rig/probes-08.rig.test 8,125; src/rig.zig 7,706; test/rig/types-misc-1.rig.test 7,602;
docs/internals/INTERNALS.md 6,798; test/rig/types-apis.rig.test 6,790; test/rig/probes-04.rig.test 6,633;
src/resolve.zig 5,930; test/rig/emit-inline-budget.rig.test 5,626; test/rig/syntax-misc.rig.test 5,330;
test/oracle/lower.zig 4,972.

### The passes

From INTERNALS, "Pipeline":

1. **Lexer** (`src/rig.zig`): layout, keywords and position, giving tokens.
2. **BaseParser** (`src/parser.zig`), generated by Nexus from `rig.grammar`.
3. **Parser** (`src/rig.zig`): a few tree rewrites, giving the semantic IR.
4. **modules** (`src/modules.zig`): loads `use`d files and checks them in dependency order.
5. **sema** (`src/sema.zig`): names, types, effects and the facts table, through **resolve** (`src/resolve.zig`),
   **typecheck** (`src/typecheck.zig`) and **cteval** (`src/cteval.zig`).
6. **storage** (`src/storage.zig`): the hidden storage emit makes.
7. **ownership** (`src/ownership.zig`): moves, views, drops and aliasing.
8. **proofs** (`src/proofs.zig`): the checks known to pass.
9. **inlining**, **returns**, **units**, **symbols** (`src/inlining.zig`, `returns.zig`, `units.zig`,
   `symbols.zig`): program-wide decisions.
10. **emit** (`src/emit.zig`): one Zig file per module, with the runtime written beside them.
11. **zig** (`zig run`, `build-exe`, or `build-obj` per unit in a split build), then **rig build**'s `frames.zig`,
    `bolt.zig` and `pgo.zig`.

**sema runs twice** on a module with a `for` over an iterator: after the module's first check the Parser wrapper's
rewrite turns that `for` into a `while`, and the module is checked again (AGENTS.md, "Pitfalls").

## Rerunning

From a Rig checkout at the commit to compare, with Zig 0.17.0 first on PATH and Nexus 2.3.1:

- **The Mac chain:** `data/cmds/mac-chain.sh` (its paths name this baseline's folders; change `R` and `W`).
- **Correctness:** `tools/heavy swarm test/rig.rip -w 4 -q`; on burst, `data/cmds/burst-all.sh` under `cpuq run`,
  with `RIG_NO_CRASH_REPORT` unset.
- **The emit snapshot:** `TRIG=<Trig with its generated modules> python3 data/cmds/emit-snapshot.py <fixed dir>`,
  then compare its `MANIFEST` with `data/emit/MANIFEST`. A difference in `trig/libtrees.zig` alone means the directory
  differs.
- **pup:** `data/cmds/prep.sh` on E-cores, then `slot-rb-a.sh` and `slot-rb-b.sh` in ab slots Rig opens, with
  `PUP_SLOT_OWNER` set to the script's shell (rig#1253).
- **Counts:** `data/cmds/doc-count.py` and `data/cmds/structure.py` from the checkout's root.
