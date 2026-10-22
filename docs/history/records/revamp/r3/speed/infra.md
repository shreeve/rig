# infra: make verification much faster without weakening it

Author: infra (speed analysis, 2026-10-06). Every number below was
measured on the Mac today, under the load of a working day (1-minute load
10-16). Scratch work: `$SCRATCH/infra/` (batch.py, batch2.py, pkgdiff.py,
wd.sh).

## Where a gate run's time goes

One accepted program run by `rig run` under the sanitizer:

| step | time |
|---|---|
| `rig check` / `rig emit` (Debug compiler) | 6-16 ms (process start is ~2.5 ms; ReleaseSafe compiler is only ~20% faster) |
| `zig run` of the emitted package, **cold** | **1.0-1.3 s**, nearly all fixed cost: hello.rig 1.06 s, generics.rig 1.13 s; semantic analysis alone (`-fno-emit-bin`) is 0.13 s, so ~0.9 s is LLVM codegen + link of std and the 97 KB runtime |
| `zig run`, **warm** (Zig cache hit) + running the program | 40-50 ms |
| test/run harness per test (bash re-exec of the 954-line script + ~10 forks) | **~70 ms** on top of the work (worker 79 ms vs `rig check` 10 ms) |
| test/run fixed start-up (discovery: `basename`/`dirname`/`selected` per file) | **~34 s per invocation** (17.6 s tests, 14.0 s corpus list, 2.0 s docs), even for `./test/run some/filter` |

Program counts: corpus 6,032 (2,720 accepted, 3,312 rejected), matrix
3,637 (1,453 run), suite ~2,650 (~1,500 build and run a program).

So a **cold** corpus is 2,720 x ~1.2 s = ~3,300 CPU-s of Zig compile plus
6,032 x ~0.08 s = ~480 CPU-s of harness, rig itself ~60 CPU-s: ~85% Zig
codegen, ~13% harness, ~2% Rig. At -j2 that is the 25-30 min in the logs.
A **warm** corpus would be ~2,720 x 0.05 + 480 = ~620 CPU-s, ~5 min at -j2.

### Finding 1 (bug): every gate run's corpus is cold

`gates.sh` runs `./test/run` (full, unfiltered) and then `./test/run
corpus`. A full run prunes "output directories of tests that are gone"
(test/run lines 836-859), and the corpus is in the pruned kinds, but a
full run lists only its 1-in-16 corpus sample. So the suite **deletes
15/16 of the corpus build caches every time**, and the corpus that
follows rebuilds ~2,550 programs from scratch. Evidence: in
`rig-seam2/.zig-cache/rig-test/corpus/`, every program directory was
created during the r2 run (06:28-06:54) though `corpus/` itself dates from
04:42 and seam2's final gates ran at 05:31; corpus re-gates in one
worktree never got faster (c-rules: 844, 878, 1140, 1155, 1109 s), while
the matrix, whose caches live elsewhere (`--keep`), dropped from ~13 min
cold to ~1 min warm on re-gates (seam2 and b4a log mtimes).

### Finding 2: almost nothing actually changes between gate runs

`pkgdiff.py` emitted every accepted corpus program's **sanitized package**
(all modules + runtime + shims) with `rig-main-0128` (main after round C)
and with HEAD (after B4a, hotfix7 and v0.2.2, three rounds): **2,708 of
2,720 identical, 12 differ**. The runtime.zig emitted is byte-identical
across all three binaries checked. A content-keyed build cache would
rebuild ~0.5% of the corpus per step.

### Finding 3: Zig's cache is not content-addressed

I hoped one shared `--cache-dir` would give cross-worktree hits for free.
It does not: Zig keys a manifest by (compiler, flags, root path as given)
and only *verifies* file contents. Same-named packages in different
directories thrash one manifest (measured: A hit, C miss, B miss, C miss
again). Zig never reuses a stale binary (it rebuilds), so the fix is to
put the content hash in the path (change 2).

### Finding 4: batching programs into one Zig compile is ~100x cheaper

`batch.py`/`batch2.py`: emit N packages (`RIG_SANITIZE=1`), put each in
`pK/`, share one `rig/runtime.zig`, and compile one multi-call driver
(`main` picks program K from argv and calls `pK.main`, returning its `u8`
or 0). Each program still runs in its **own process**, so the leak checker,
sanitizer and panics are per program, exactly as now.

| batch | one compile | per program | standalone cold |
|---|---|---|---|
| 10 corpus programs | 0.95 s | 0.095 s | ~1.1 s each |
| 150 corpus programs | 1.28 s | 0.009 s | 1.26 s each (189 s) |
| 391 programs, every 7th of the corpus (9 multi-file) | 2.38 s (515 MB peak) | 0.006 s | 392 s for all 391 (~1.0 s each) |
| same 391 with `-fstrip` | 1.25 s (314 MB) | 0.003 s | |

Results matched standalone `rig run` for 149/150 (the 1 "difference" was
the same SIGABRT panic, seen as 134 vs -6, and stack-frame names).
Of the 391: 385 matched exactly; 5 were the same SIGABRT panic (my
harness saw 134 vs -6, the signal's two encodings); 1 (review-std-r4)
prints a random shuffle and differs run to run. **391/391 agree.** The
whole accepted corpus+matrix (~4,200 programs) would compile in ~11
batches, ~30 s of one core, instead of ~84 CPU-min.

### Finding 5: `-fstrip` cuts a cold compile 2.7x

hello-sized package: default (LLVM, aarch64-macos) 1.29 s, `-fllvm` 1.34 s,
`-fstrip` 0.48 s. Debug-mode safety checks stay; only DWARF goes, so panic
and sanitizer reports lose source lines in their stack traces.
`-fno-llvm` (self-hosted aarch64) blew up to 64 GB RSS in two minutes and
was killed by the lead (it filled swap); **ruled out on the Mac; looks like
a Zig 0.17 memory blowup worth a minimal repro later.** On Linux x86_64
(pup, CI ubuntu) the self-hosted x86 backend is Zig's Debug default and is
much faster than LLVM; CI ubuntu ran the suite in 511 s on 4 vCPU vs
1,435 s on macos-latest.

### Finding 6: equivalence

Full `test/equiv.py rig-main-0128 bin/rig -j 2`: **9 min 05 s wall,
15 CPU-min**, 8,311 programs (46 differ). Each program costs ~11 rig
processes (4 sections + 3 for accepted, x2 compilers), each re-parsing and
re-checking from scratch; the base side is recomputed on every run though
the base binary is fixed for the whole step.

Equivalence's emit section is `rig emit`'s stdout: the **root module
only, unsanitized**. It does not see non-root modules, std shims, the
runtime, or the poison code `RIG_SANITIZE` adds. That is fine for its job
(proving a refactor), but it means equiv cannot be used to skip runs
(test impact analysis), and it could miss an emit change that only shows
in a sanitized or multi-module package. Cheap fix: add a `pkg` section,
the sha256 of the whole sanitized package (change 9).

### Finding 7: CI

`test.yml` runs only `./test/run -j 4` (suite; corpus sample) on
ubuntu-latest (10.5 min job) and macos-latest (25.5 min job, the merge
bottleneck: setup 36 s, build 24 s, suite 1,435 s, all cold). The repo is
**public**, so GitHub-hosted runners are free and unmetered (20 concurrent
jobs, 5 macOS). Nothing heavy runs there today.

### Finding 8: the compiler build is not a bottleneck

`zig build` of bin/rig in a fresh checkout (global cache warm): 7 s;
after touching src/emit.zig: 5 s. ReleaseSafe: 58 s. Sharing caches across
worktrees would save seconds; not worth doing.

## Changes, ranked by payoff

Times are for one full gate run (suite + corpus + matrix + unit) at
-j2 unless noted; today it is ~50 min cold (suite 4-11, corpus 25-30,
matrix 13, unit 1), ~40 min on a re-gate.

### 1. Stop the full suite from deleting the corpus caches (test/run)

Make the prune skip `corpus/<name>` directories whose program still
exists (or, simplest, put every corpus program in `keep` whether or not it
was sampled). ~3 lines.
**Saves ~18-22 min per re-gate** (corpus 25 min -> ~5-7 min warm; it
still recompiles programs whose package changed).
**Risk: none.** Zig verifies every input on a cache hit; the cache only
skips rebuilding identical packages.

### 2. Content-addressed package directories (src/main.zig, ~30 lines)

With `RIG_BUILD_STORE=DIR` set, `rig run/build/test` writes the package
to `DIR/<sha256 of every package file + zig argv>/` and builds with that
directory's `.zig-cache`; test/run and matrix.py set it to one per-user
store (e.g. `~/.cache/rig/store`, shared by every worktree, the base
binary and the new one). Prune entries whose `.used` stamp (touched on each hit; atime is
unreliable on macOS) is older than a few days, at the start of a full run.
**Saves:** the first gate on a new branch/worktree goes from cold to
~99.5% warm (finding 2): corpus 25 -> ~5 min, matrix 13 -> ~1 min, suite
4-11 -> ~2 min. Also makes `rig run` of the same program in two places
free, and fixes finding 1 as a side effect.
**Risk: very low.** The hash only chooses where to look; Zig still checks
compiler, flags and every file's content and rebuilds on any mismatch,
so a wrong or incomplete hash costs time, never correctness. Concurrent
builds of one hash are serialized by Zig's own cache locks.

### 3. Fix test/run start-up (discovery in one awk/find pass)

Replace the per-file `basename`/`dirname`/`selected` loops (and the
per-corpus-name `add`) with one `find | awk` that applies the filters.
**Saves ~30 s per invocation**: every targeted TDD run
(`./test/run behavior/foo`), each gate's suite and corpus, odv, and
`cli/test_out_dir` (74 s today, it runs test/run three times). Over a
round of ~50 targeted runs that is ~25 min of an implementer's waiting.
**Risk: none** if checked: diff the generated LIST before/after for
no filter, a kind, a substring, and `corpus`.

### 4. A lean worker (no bash re-exec per test)

Run the per-test checks in one long-lived process (port the worker to
Python with a thread pool, as matrix.py already does, or keep bash but
batch many tests per `--worker` call). ~70 ms -> ~5 ms per test.
**Saves ~600 CPU-s per gate run: ~5 min at -j2** (8,700 tests), ~1.5 min
per suite run.
**Risk: low.** The classification regexes and rules move verbatim; prove
it by running old and new runners over everything and diffing the
`st/*` result files (status + reason) once.

### 5. Batched multi-call builds for cold compiles

A `test/batch` helper (or `rig run --batch LIST`): emit each accepted
program's sanitized package, group by `-lc` and by shim contents, compile
~100-200 per Zig invocation into one multi-call binary, run each program
in its own process. On a batch compile error, fall back to per-program
`rig run` for that batch (so a Zig error is still attributed to its
program). Use it for corpus and matrix (they check failure classes, not
exact stdout); keep the suite's behavior tests and doc examples on
standalone `rig run` (they compare stdout, and `@typeName` would show the
`pK.` module prefix).
**Saves:** a fully cold corpus+matrix (runtime.zig changed, new Zig, new
machine, CI) from ~85 min CPU of Zig compiles to ~1 min (measured: 391 programs in
one 2.4 s compile), plus the runs themselves (~40 ms each). With 1-2 in place this
matters mostly for CI and pup, and for runtime changes (Static, the fold,
Box -> ^T, Vec -> List will all touch the runtime).
**Risk: low-medium.** The program's code is identical but the root is
the driver: flags (`__rig_sanitize`), `panic`, and main's `void`/`u8`
return must match (they are the only root hooks: runtime.zig reads
`root.__rig_sanitize`/`__rig_leak_trace`; emit's main is `void` or `u8`).
Guard: validate once over the whole corpus+matrix (results must equal
standalone), and on every gate run a random 2% sample through standalone
`rig run` and CI keeps one standalone job.

### 6. Run the heavy gates on GitHub (sharded) and on pup

Add `--shard I/N` to test/run (hash of id) and matrix.py, and a `gates`
workflow (`workflow_dispatch` + PR): suite+corpus+matrix+unit+odv in N
shards per OS (e.g. 6 ubuntu + 4 macOS; the repo is public, so free).
With 5 (batching) a shard's work is minutes; without it, ~4,200 cold
programs / 6 shards / 4 vCPU x ~1.3 s = ~4 min Linux.
**Saves:** gates leave the Mac entirely (~40-50 min of 2-4 cores per
run, and the contention that makes everything else slow); CI wall
~8-12 min with macOS sharded, vs 25 min today for a smaller job.
pup (20-core budget, Linux x86 self-hosted backend): pup.sh/pup-gates.sh
already exist (lead's agent); with 1-4 a full gate there is ~3-5 min.
**Risk: none for soundness** (same tests; adds a second OS). Cost:
WIP branches are pushed to the public repo for CI (pup avoids that).

### 7. `-fstrip` for corpus and matrix builds

Pass `-fstrip` (an env knob, e.g. `RIG_ZIG_FLAGS`, set by the corpus and
matrix runners only). Cold compile 1.29 -> 0.48 s.
**Saves** ~60% of whatever cold compiling remains (most valuable in CI
and pup, without 5).
**Risk: low.** Safety checks, the leak checker and the sanitizer are
unchanged; only stack-trace source lines go. The failure classifier greps
messages, not traces. On a failure, rerun that program without it.
To verify before adopting: a known use-after-free in `raw` still prints
`rig: use of freed memory` with `-fstrip`.

### 8. Equivalence: cache the base side and dump all sections in one process

(a) The base binary is fixed for a whole step; store its outputs keyed by
(base binary sha, program text sha) and reuse them on every rerun: halves
equiv. (b) A hidden `rig dump-all` that prints parse/normalize/check/
facts/sema/storage/emit in one process (7 spawns -> 1 per compiler).
**Saves:** (a) ~4.5 min per rerun; (b) most of the rest: one parse+check
per program per compiler instead of seven. Expect 9 min -> ~1.5-2 min at
-j2.
**Risk: none** (the same text is compared; caching keys on exact inputs).

### 9. Equivalence also compares the whole sanitized package (`pkg`)

A sha256 of the `RIG_SANITIZE=1` package (every module, shims, runtime).
Not a speedup by itself, but it closes the blind spot in finding 6, and
it is what makes "which programs could this change affect?" a sound
question.

### Not recommended: skipping programs (test impact analysis) in gates

The run verdict of a program is a function of its `rig check` output,
its sanitized package, Zig, and the host. Equiv as written does not cover
the package (finding 6), so selecting programs from equiv diffs is
unsound. With 9 it would be sound up to nondeterminism (addresses, ASLR,
the sanitizer's quarantine), but after 1-4 rerunning everything costs
only ~3-5 min, so the argument is not worth having. Use it in the inner
loop only: an implementer's per-commit check can run the suite plus the
programs whose `pkg` or `check` changed; the gates stay full.

### Merging equivalence and the gates

Possible (equiv already runs `rig check` on every program, so the corpus
could take its verdicts from there), but after 2-4 the corpus's own
`rig check` costs ~1 min; the coupling is not worth it. Running equiv and
the gates concurrently on different machines (equiv on the Mac, gates on
pup/CI) gives the same wall-clock win with no coupling.

## Expected result

| | today | after 1+3 | after 1-4 | after 1-6 |
|---|---|---|---|---|
| gates, first run on a new branch | ~50 min | ~48 min | ~10 min | ~5 min on pup / CI |
| gates, re-run | ~40 min | ~20 min | ~6 min | ~4 min |
| targeted `./test/run filter` | 34 s + work | ~2 s + work | ~1 s + work | same |
| CI to merge | 25 min | 25 min | ~12 min (warm only if the cache travels) | ~8-10 min |

Order: 1 and 3 today (minutes of work, zero risk); 2 next (one small
compiler change, test-first with a cli test that two directories with the
same package share a build and different packages never do); 4; then 5-7
for CI/pup.
