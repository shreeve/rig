# v0.4.0-rc1 against revamp-base: the cleanup round, before and after (2026-11-28)

Rig (OG), with the owner's approval ("run the full before/after report against revamp-base after the verdict").
This reruns the measurements of [revamp-base](../revamp-base/README.md) (645996606, the before state) on the tag
`v0.4.0-rc1` (0764e091f, the after state), the same way and on the same machines. No code changed for it.

**Every timed number has its before measured again beside it, alternating base and rc1 in the same session**
(all but pup's Trig release build, below), since
the record's own conditions (load, cores) cannot be repeated. The record's figures stay in each table as a third
column, for reference. Commands are in `data/cmds/` (the record's scripts, unchanged, and the chains that drove
them), raw logs in `data/logs/`. Large outputs are outside git, in `~/Data/Code/Claude/rig/rig/rc1-report/` on the
Mac and `/zfs/trig-pup/rc1-report/` on pup.

## Summary

| section | before (revamp-base) | after (v0.4.0-rc1) | change |
|---|---|---|---|
| 1. build, Mac / pup | 107 s / 162 s | 126 s / 171 s | 18% / 6% slower; `bin/rig` 3.5% / 4.8% larger |
| 2. `rig check` of Trig, Mac | 2,333 ms, 674 MB | 1,128 ms, 407 MB | **2.07x faster, 40% less memory** |
| 2. `rig check` of Trig, pup | 3,180 ms, 609 MB | 1,649 ms, 390 MB | **1.93x faster, 36% less memory** |
| 3. Trig's release build, Mac | 879-924 s | 934-1,277 s | 6% slower best to best (23% in the mean); binary 2.4% larger |
| 3. Trig's release build, pup | 1,174 s | not measured | pup's line went to the 64-of-64 races |
| 4. check guard, instructions | 2.20 G | 1.69 G | 23% fewer |
| 4. json, hash, text guards | | | level (within 0.6%); `HashMap` rows 4-32% fewer |
| 5. concurrency benches | | | level; http p99 on pup to watch |
| 6. compiler lines (code) | 102,736 (74,380) | 107,966 (78,064) | 5% more |
| 7. Trig / tsrs, pup, wall c1/c2/c4/c8 | 0.889 / 0.923 / 0.933 / 0.917 | 0.875 / 0.892 / 0.897 / 0.895 | lead 1.6-3.9% larger; 4 lost cells to none |
| 7. Trig / tsrs, pup, memory | 0.994 / 0.965 / 0.967 / 0.940 | 1.006 / 0.978 / 0.981 / 0.957 | 1.2-1.8% more against tsrs |

**What got slower:** building Rig (18% on the Mac, 6% on pup); building Trig in release on the Mac (Zig takes
longer on rc1's emitted Zig, which is about the same size); two `rig check` passes, lex and parse (3-5%) and proofs
(level to 3%); Trig's peak memory against tsrs (1.2-1.8%, now just above tsrs at c1); and possibly http's p99 on pup.

## Conditions

| | Mac (pop) | pup |
|---|---|---|
| machine | Apple M5, 10 cores | Core Ultra 9 185H, x86-64 Linux |
| Zig | 0.17.0 (first on PATH) | 0.17.0 |
| Nexus | 2.4.0 (the record: 2.3.1) | 2.4.0 |
| timing | `cpuq drain -c 2` (`-c 8` for builds and the concurrency benches); macOS sets no affinity, so other sessions' work shares the cores (load 6 to 24) | `cpuq drain -c 2 --prefer fast` (`-c 8` for builds and benches), pinned to `$CPUQ_CPUS` |
| base rig | `tools/baseline 645996606` | built in `/zfs/trig-pup/rc1-report/base` |
| Trig source | the record's `trig-prog` (Trig 950f14b3 with its generated `libtrees` and `buildinfo`) | the same, copied |

- **Nexus 2.4.0** generates a different `src/parser.zig` from 2.3.1 (sha256 d978f6b7… at revamp-base, against the
  record's 732d20a8…), and revamp-base's `bin/rig` comes out 16,176 bytes larger on the Mac (11,617,648 against
  11,601,472) and 25,232 on pup. Both sides here use 2.4.0.
- **pup's CPUs:** an emdb drain held CPUs 8-11 for most of the session, so the 8-CPU drains got P-cores 0, 1, 3, 6,
  8, 10 and E-cores 12-13 (the record used P-cores 0-11), and the 2-CPU drains P-cores 1 and 3. The CPU list of each
  drain is in `data/logs/pup-cpus.log` and the build logs.
- **The Mac** was shared with another session's core suite throughout; read the Mac's absolute times as loaded, and
  compare base and rc1 within this report, not with the record.

## 1. Build

`data/cmds/build-time.sh 1`, four times per machine: base, rc1, base, rc1 (ReleaseSafe, `.zig-cache`, `zig-out` and
`bin/rig` removed, the global Zig cache kept). No warnings on either side.

| | record (base) | base, now | rc1, now | change |
|---|---:|---:|---:|---|
| Mac, build time | 86.3, 85.9 s | 102.1, 111.8 s | 128.3, 123.3 s | 18% slower (1.18x the time) |
| Mac, `bin/rig` | 11,601,472 bytes | 11,617,648 bytes | 12,018,768 bytes | 3.5% larger |
| pup, build time | 156.6, 156.2 s | 162.5, 160.5 s | 167.5, 174.4 s | 6% slower |
| pup, `bin/rig` | 46,911,280 bytes | 46,936,512 bytes | 49,168,376 bytes | 4.8% larger |

The compiler takes Zig longer to build and comes out larger: it has 5% more lines (section 6), in 57 files rather
than 29.

## 2. `rig check --time` on Trig, by pass

`data/cmds/trig-check.sh RIG trig-prog 1`, alternating base and rc1 for 7 rounds, two sets each; `check-best.py`
takes each pass's best of 7. The base reruns and the record are within the same few percent on pup (3,180 against
3,116 ms) and 12% apart on the loaded Mac (2,333 against 2,084 ms). The best of the two sets is shown; each set's
own figures are in `data/logs/check-best.txt`.

rc1's `lower` pass replaced revamp-base's `storage` and does more than storage did (it builds each body's LIR, which
emit and the ownership checker read), so the two rows are not one for one.

**Mac** (ms):

| pass | record (base) | base, now | rc1, now | change |
|---|---:|---:|---:|---|
| lex and parse | 146.2 | 157.3 | 162.4 | 3% slower |
| resolve | 149.0 | 163.3 | 87.4 | 1.87x faster |
| typecheck | 705.1 | 793.2 | 349.9 | 2.27x faster |
| storage → lower | 655.4 | 735.2 | 194.3 | 3.78x faster |
| ownership | 246.8 | 286.5 | 167.4 | 1.71x faster |
| proofs | 59.8 | 66.4 | 66.7 | level (0.5% slower) |
| inlining | 74.3 | 76.0 | 74.1 | 3% faster |
| other | 37.3 | 40.7 | 23.0 | 1.77x faster |
| **total** | 2,083.7 | 2,333.2 | 1,127.5 | **2.07x faster** (52% less time) |
| wall | 2.1 s | 2.4 s | 1.1 s | |
| peak RSS | 673.6 MB | 673.7 MB | 407.0 MB | **40% less memory** |

**pup** (ms):

| pass | record (base) | base, now | rc1, now | change |
|---|---:|---:|---:|---|
| lex and parse | 271.6 | 274.6 | 288.0 | 5% slower |
| resolve | 208.0 | 213.5 | 119.8 | 1.78x faster |
| typecheck | 1,037.2 | 1,065.6 | 494.0 | 2.16x faster |
| storage → lower | 929.7 | 940.7 | 278.4 | 3.38x faster |
| ownership | 378.6 | 387.9 | 239.5 | 1.62x faster |
| proofs | 90.9 | 94.3 | 97.4 | 3% slower |
| inlining | 109.5 | 114.7 | 99.8 | 1.15x faster |
| other | 74.5 | 78.4 | 31.9 | 2.46x faster |
| **total** | 3,115.9 | 3,180.3 | 1,649.2 | **1.93x faster** (48% less time) |
| wall | 3.2 s | 3.2 s | 1.7 s | |
| peak RSS | 610.1 MB | 609.3 MB | 390.3 MB | **36% less memory** |

(RSS is `check-best.py`'s, in MiB; the headline in `cleanup/base-vs-rc1-check.md` quoted the same Mac runs' bytes,
427 MB.) Two passes got slower on both machines: **lex and parse** (3% on the Mac, 5% on pup) and **proofs** (level
on the Mac, 3% on pup). Every other pass is faster.

## 3. Trig's release build

`data/cmds/trig-build.sh RIG trig-prog 1 OUT` (`rig build --release -o trig main.rig` into a fresh `RIG_OUT_DIR`,
Zig's calls timed through `zigtime`), one build per drain, under `cpuq drain -c 2` (the release build is one Zig
job, a single unit).

**Mac**, in the order run (the Mac's load at each start in brackets):

| | record (base) | base, now | rc1, now | change |
|---|---:|---:|---:|---|
| total | 668.1, 549.3 s | 878.9 s [11.9], 924.1 s [15.5] | 1,277.4 s [20.2], 933.5 s [10.8] | 6% slower best to best; 23% slower in the mean |
| of which Zig | 661.7, 543.1 s | 868.9, 915.2 s | 1,267.0, 925.6 s | Rig's own part is 8-10 s on both |
| Trig binary | 29,709,424 bytes | 29,709,424 bytes | 30,409,856 bytes | 2.4% larger |
| frame warnings | 34 | 34 | 43 | 9 more |

The Mac ran at a load of 11 to 20 from other sessions, so its four builds are a range, not a point: rc1's two are
37% apart. Best to best, rc1's Trig takes Zig 7% longer; no build of rc1 came in under either base build. The
emitted Zig is about the same size (83 files and 243,054 lines against 81 and 241,767, 0.5% more), so the extra
time is in what Zig and LLVM do with it, not in how much there is. The 9 new frame warnings are functions whose
frame passes a page with what rc1 inlines into them (`data/logs/mac-trig-build-warnings-*.log`). A first rc1 build
was cut at 26.8 minutes by its drain's 20-minute limit, which counts the drain's wait
(`data/logs/mac-trig-build-rc1-1-cut.log`); the build above under that name is its rerun.

**pup:** only revamp-base was measured: 1,173.6 s on P-cores 1 and 3 (the record: 1,053.4 and 1,038.6 s on P-cores
0-11), a 166,216,440-byte binary (the record: 166,216,800 and 166,216,808). rc1's builds did not run. The first was
queued and got E-cores 12 and 14, and was stopped, since base had run on P-cores. A pair of builds side by side on
E-cores 12-15 was then stopped when pup's line was needed for the 64-of-64 measurements. A pup Trig build takes about
20 minutes on two P-cores, past the 20-minute limit a pup drain now has, so the row waits for a quiet pup and a
longer slot. The cut logs are kept.

## 4. The instruction guards (Mac)

Each guard twice at rc1 against rc1's `guard.txt`, and its before figures from the record (two runs at
revamp-base). The json, hash and text guards ran under `cpuq run` (instruction counts, not times); the check guard
under `cpuq drain -c 2`. The Mac's load was 7-8, which the guards count; the record's was 4.

**json** (instructions per byte, mean of two runs):

| file | before | rc1 | change | rc1 against its guard.txt |
|---|---:|---:|---|---|
| twitter | 6.2310 | 6.2325 | level | level |
| twitterescaped | 7.4065 | 7.4307 | 0.3% more | 0.3% above |
| canada | 14.7853 | 14.8018 | 0.1% more | 0.1% above |
| citm_catalog | 6.0385 | 6.0454 | 0.1% more | 0.1% above |
| gsoc-2018 | 2.8978 | 2.9133 | 0.5% more | 0.6% above |
| github_events | 5.2543 | 5.2715 | 0.3% more | 0.3% above |

**hash** (instructions per operation, mean of two runs): every `map` row is within 0.6% of its before (0.1-0.6%
more; `text-churn` 0.6% more) and within 0.9% of rc1's `guard.txt`. `HashMap` got its rows' gains (rc1's
`guard.txt` was moved to hold them, aa60783fa):

| row | before | rc1 | change |
|---|---:|---:|---|
| hashmap int-hit | 36.18 | 25.25 | 30% fewer |
| hashmap int-churn | 190.28 | 154.70 | 19% fewer |
| hashmap int-iterate | 19.26 | 16.29 | 15% fewer |
| hashmap text-hit | 90.91 | 73.11 | 20% fewer |
| hashmap text-churn | 928.62 | 888.26 | 4% fewer |
| hashmap pair-hit | 42.97 | 34.04 | 21% fewer |
| hashmap small-hit | 37.01 | 25.02 | 32% fewer |
| hashmap int-miss, text-miss | 20.28, 55.94 | 20.23, 55.81 | level |

**text**: every row within 0.1% of its before and of rc1's `guard.txt`.

**check** (`bench/check/guard.py --rig`, the same `gen.py` workload at both tags, fewest of 7): run at rc1 alone
(load 7.8) and then alternating base and rc1, two each (load 23-24).

| | before (record, load 4.1) | base, now | rc1, now | change |
|---|---:|---:|---:|---|
| instructions | 2,187,498,651; 2,196,579,644 | 2,195,055,983; 2,196,986,358 | 1,689,985,565; 1,689,863,406 | 23% fewer (1.30x fewer) |
| against rc1's `guard.txt` (1,780,353,622) | | | 5.1% below | passes |
| scaling exponents | 1.00-1.02 | | 1.00-1.02 | the same (limit 1.15) |
| pass times | 107.7, 109.7 ms total | | skipped by the guard at a load of 5 or more | |

rc1's `guard.txt` was moved four times in the round (cc8c9c8e1, af91cc1a0, 6e6d0d8e5 for check; aa60783fa for
hash), each recorded with its reason in its PR.

All four guards pass their 2% gate at rc1. No json, hash or text row got more than 0.6% more instructions.

## 5. The concurrency benches

rig-safe, each bench built once per tag (base's builds are the record's on the Mac, rebuilt on pup with the base
tag's scripts), then `--time-only` alternating base and rc1 inside one drain per bench: six rounds each on the Mac;
on pup six for tasks, actors and net, and two for http (its last four rounds were withdrawn with the pup drains).
http ran with 5,000 idle connections on the Mac and 10,000 on pup, as the record did. Best of the rounds (lowest
time, most requests), then the median:

**Mac** (`cpuq drain -c 8`; load 8-24 from other sessions, no affinity):

| bench | row | record (base) | base, best / median | rc1, best / median | change, best |
|---|---|---|---|---|---|
| tasks | spawn | 85-154 ns | 74 / 86.5 ns | 68 / 85.5 ns | 8% faster |
| | chain | 25 ns | 27 / 32.5 ns | 27 / 28.5 ns | same |
| | fanout | 68.8-71.1 ms | 73.2 / 75.6 ms | 74.0 / 79.6 ms | 1% slower |
| | yield | 6-7 ns | 7 / 8.5 ns | 7 / 8 ns | same |
| | hog | 96-118 ns | 92 / 104 ns | 95 / 120 ns | 3% slower |
| | produce | 5.2 ms | 5.3 / 5.5 ms | 5.3 / 5.6 ms | same |
| | memory | 16.6 KiB | 16.5 KiB | 16.5 KiB | same |
| actors | solo | 5.1 ns | 5.6 / 6.2 ns | 5.5 / 6.2 ns | 2% faster |
| | contend | 14-15 ns | 7.8 / 21 ns | 6.5 / 18 ns | 17% faster |
| | spread | 0.8-0.9 ns | 1.1 / 1.25 ns | 1.0 / 1.5 ns | 9% faster |
| net | pingpong | 16.55-16.63 us | 16.22 / 19.14 us | 16.40 / 19.38 us | 1% slower |
| | echo | 5.85-5.93 us | 6.06 / 6.50 us | 6.05 / 6.47 us | same |
| | connect | 49.5-51.0 us | 57.9 / 71.2 us | 52.1 / 67.0 us | 10% faster |
| http | req/s | 154,076-154,366 | 171,368 / 158,026 | 168,440 / 157,280 | 1.7% fewer |
| | p50 | 397-399 us | 356 / 373 us | 358 / 374 us | level |
| | p99 | 668-688 us | 762 / 999 us | 763 / 1,161 us | level (median 16% slower) |
| | per idle connection | 16.7 KiB | 16.7 KiB | 16.7 KiB | same |

**pup** (`cpuq drain -c 8 --prefer fast`, pinned: P-cores 0, 1, 3, 6, 8, 10 and E-cores 12-13 for most rounds):

| bench | row | record (base) | base, best / median | rc1, best / median | change, best |
|---|---|---|---|---|---|
| tasks | spawn | 105-112 ns | 99 / 106.5 ns | 96 / 110.5 ns | 3% faster |
| | chain | 47-48 ns | 47 / 50 ns | 46 / 50 ns | 2% faster |
| | fanout | 59.6 ms | 85.3 / 91.0 ms | 81.9 / 91.6 ms | 4% faster |
| | yield | 6 ns | 7 / 8 ns | 8 / 8 ns | 1 ns slower |
| | hog | 160-166 ns | 159 / 181.5 ns | 151 / 164 ns | 5% faster |
| | produce | 5.1-5.4 ms | 5.1 / 5.4 ms | 5.1 / 5.5 ms | same |
| | memory | 4.6 KiB | 4.6 KiB | 4.6 KiB | same |
| actors | solo | 11-12 ns | 11 / 12 ns | 11 / 12 ns | same |
| | contend | 19 ns | 14 / 15.5 ns | 15 / 15 ns | 1 ns slower |
| | spread | 1.8-1.9 ns | 1.9 / 2.15 ns | 1.8 / 2.0 ns | 5% faster |
| net | pingpong | 4.89-4.95 us | 4.74 / 5.03 us | 4.78 / 5.13 us | 1% slower |
| | echo | 936-969 ns | 1.15 / 1.23 us | 1.18 / 1.23 us | 3% slower |
| | connect | 25.8-26.2 us | 25.09 / 26.05 us | 25.26 / 26.21 us | 1% slower |
| http | req/s | 953,866-964,151 | 747,274 / 746,809 | 757,669 / 728,237 | 1.4% more (two rounds) |
| | p50 | 52 us | 64 / 67.5 us | 66 / 68 us | 3% slower |
| | p99 | 228-241 us | 311 / 367 us | 371 / 410 us | **19% slower** (two rounds) |
| | per idle connection | 4.8 KiB | 4.8 KiB | 4.8 KiB | same |

The concurrency benches are level: no row is slower on both machines beyond the rounds' spread, and memory per
task and per idle connection is the same. **One row to watch:** http's p99 on pup, 19% slower best to best and 12%
in the median, from only two rounds each; the Mac's p99 is level best to best but 16% slower in the median, on a
Mac at a load of 20 or more. pup's fanout and http absolute figures are below the record's because the drains held
8 CPUs, two of them E-cores, against the record's 12 P-cores; base and rc1 ran on the same CPUs.

## 6. Structure

`data/cmds/structure.py` at each tag (it reproduces the record's table at revamp-base exactly). Lines, with code
lines (no blank or comment-only lines) after the slash:

| area | language | before | rc1 | change |
|---|---|---:|---:|---|
| compiler (src/) | Zig | 29 files, 102,736 / 74,380 | 57 files, 107,966 / 78,064 | 5% more lines, 5% more code |
| | grammar | 1,466 / 935 | 1,470 / 936 | level |
| runtime | Zig | 37,342 / 25,506 | 38,153 / 26,006 | 2% more |
| std/ | Rig | 12,767 / 8,277 | 12,779 / 8,277 | level |
| | Zig | 10,361 / 8,973 | 10,401 / 8,995 | level |
| tests (test/) | Rig tests | 197 files, 1,340,943 | 199 files, 1,343,941 | 0.2% more |
| | shell, Zig, Python | 18,088, 8,246, 7,043 | 18,104, 8,278, 7,043 | level |
| docs (root and docs/) | Markdown | 55 files, 62,550 | 59 files, 64,445 | 3% more |
| docs/history/ | Markdown | 1,265 files, 217,291 | 1,272 files, 220,585 | 1.5% more |
| tools/ | Python | 14,639 | 14,691 | level |
| formal/ | Lean | 9,372 | 9,372 | same |
| bench/ | all | 217 files, 25,443 | 219 files, 25,890 | 2% more |

Where the compiler's lines moved: `src/typecheck.zig` (26,390 lines) is now 3,740, beside `src/check/` (12 files,
23,010); `src/ownership.zig` (9,768) is now 568, beside `src/ownership/` (10 files, 10,945); `src/storage.zig`
(2,774) is gone, and `src/lower.zig` (4,406) and `src/lir.zig` (1,282) build the LIR that emit and the ownership
checker read. The largest compiler file is `src/sema.zig`, 18,827 lines (19,539 before). Both tables are in
`data/logs/structure-*.md`.

## 7. The headline board: Trig against tsrs, then and now

Quoted from the races, not rerun. Trig / tsrs 0.23.0 exact, summed over the 16 large projects (mui-docs apart), on
pup's P-cores; lower is better.

- **Then:** race 761 (2026-11-24, slot 761 under `cpuq --exclusive`), Trig `trig-revamp-base` f876e4b2 on Rig
  revamp-base 645996606, PGO+BOLT, 11 rounds (Trig's docs/RESULTS.md and research 34; race 760 before it was void).
- **Now:** slot 773 (2026-11-27), arm R, the milestone build: Trig main fccbb650 on Rig 55341aefc, PGO+BOLT, 12 rounds
  in four parts (`races/s773.txt` in Trig's session notes). rc1 is 55341aefc plus release notes and one lowering cleanup (4a524ba9d, 16 lines in `src/lower.zig` and `src/lir.zig`).

| Trig / tsrs, summed | race 761 (before) | slot 773 (now) | change in Trig's lead |
|---|---:|---:|---|
| wall, c1 | 0.889 | 0.875 | 1.6% less time against tsrs |
| wall, c2 | 0.923 | 0.892 | 3.4% less |
| wall, c4 | 0.933 | 0.897 | 3.9% less |
| wall, c8 | 0.917 | 0.895 | 2.4% less |
| peak memory, c1 | 0.994 | 1.006 | 1.2% more memory against tsrs |
| peak memory, c2 | 0.965 | 0.978 | 1.3% more |
| peak memory, c4 | 0.967 | 0.981 | 1.4% more |
| peak memory, c8 | 0.940 | 0.957 | 1.8% more |
| cells | 4 of 64 lost (nuxt c4 1.055, webpack c4 1.049, nuxt c8 1.043, webpack c8 1.042) | 59 WIN, 5 level, 0 lost | |

Summed memory got slightly worse against tsrs at every count, and at c1 it is now just above tsrs's (1.006). In the
same slot, R's peak memory is 0.9-1.7% above arm M's (Trig c6f31277 on Rig 159c24459), so most of the rise came with
the last batch of Trig and Rig changes before the milestone.

**The Mac:** no Mac board was run at revamp-base, so there is no before. Now: the milestone's Mac board
(`mac-fccbb650-r2.runs`, the same Trig on the same Rig, PGO, 40 rounds, 15 for ts-pattern; its first run,
`mac-fccbb650.runs`, is void by tsrs's own speed under load) scores 56 of 56 exact cells WIN, 0 level, 0 lost (also
after Benjamini-Hochberg), on 7 libraries at 1-8 checkers. Trig / tsrs is 0.754 as a geometric mean of the 56 cells
(0.542-0.923), 0.840 summed. The fast cells (Trig balanced against tsrs `--fast`, neither tsc-exact): 5 WIN, 1 level
(ts-pattern 0.961), 1 lost (zod3, 1.075, 3.3 ms; a fix is in progress in Trig).

## Rerunning

From the Mac, with Zig 0.17.0 first on PATH: `data/cmds/mac-t.sh` (builds, `rig check`, the check guard, the
benches, Trig's release builds) and `data/cmds/mac-g.sh` (the rc1 rig, bench builds, json, hash and text guards,
structure) side by side, then `mac-more.sh` for the further bench rounds and the check guard of both tags. On pup,
`data/cmds/pup-chain.sh` from a folder holding `base/` and `rc1/` checkouts and `trig-prog`, one timing round per
drain of at most 20 minutes. `sumlogs.py DIR PREFIX` tabulates the bench logs; `check-best.py` the check logs.
`mac-trig.sh`, `mac-trig2.sh`, `pup-trig.sh` and `pup-trig2.sh` are the reruns this session's limits forced, kept
so the logs can be read.

