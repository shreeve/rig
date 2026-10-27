# map-inline cross-check (Trig (fork), 2026-10-26)

## Builds

| Side | Rig | Trig |
|---|---|---|
| base | main 5a79e02f2 | c75127e, `tools/trig/main.rig` |
| map-inline | 392701712 (code at eaf158092) | the same |

- **Rig** was built with `zig build -Dnexus=…` in fresh clones.
- **Trig** was built as release packs on each Rig, plain (`--release`) and PGO (`--release --pgo`, trained by `tools/trig/bolt-train`), all on release slots.
- **Output:** all four builds print the same bytes on ts-pattern and zod3.

## Method

- **Machine:** pup, quiet after the 20:00 cron. A first run overlapped that cron and was thrown away.
- **Cores:** one checker on core 3 with `--singleThreaded`; four checkers on cores 0–11 with `--checkers 4`.
- **Warm runs:** interleaved, each as it comes.
- **Cold runs:** right after my own 64 MiB writer, run on each core used, so the run starts with the last-level cache flushed.
- **Reported:** the fastest wall time; the fastest run's user cycles and instructions; the median RSS and page faults.
- **Rounds:** 10 rounds of all four builds. The two PGO builds then ran again for 25 rounds, with RSS in KB.

## PGO: map-inline against base (25 rounds)

| Project | Checkers | Run | Wall | Cycles | Instructions | RSS |
|---|---|---|---:|---:|---:|---:|
| ts-pattern | 1 | warm | 0.4% faster | 0.8% fewer | 1.8% fewer | +300 KB (0.10%) |
| ts-pattern | 1 | cold | 0.9% faster | 0.7% fewer | 1.4% fewer | +300 KB |
| ts-pattern | 4 | warm | 1.4% slower (medians equal) | 0.7% fewer | 1.5% fewer | +192 KB |
| ts-pattern | 4 | cold | 0.2% faster | 0.5% more | 1.5% fewer | +236 KB |
| zod3 | 1 | warm | 1.6% faster | 0.7% more | 1.8% fewer | +292 KB (0.32%) |
| zod3 | 1 | cold | 2.7% faster | 1.3% fewer | 0.7% fewer | +292 KB |
| zod3 | 4 | warm | 1.4% faster | 2.7% fewer | 1.7% fewer | +224 KB |
| zod3 | 4 | cold | 0.9% slower (medians equal) | 2.8% more | 1.6% fewer | +248 KB |

The 10-round run agrees:

- **Time:** ts-pattern is 0.7–1.0% faster in all four configurations. zod3 at four checkers was −4% to +2% across both runs, which is noise at 125 ms over four tasks.
- **Instructions:** 1.0–1.9% fewer everywhere.

## Plain release: map-inline against base (10 rounds)

| Project | Wall | Instructions |
|---|---|---|
| ts-pattern | 0.9–2.5% faster | 3.4–3.6% fewer |
| zod3 | 1.2% slower to 2.1% faster | 3.0–3.6% fewer |

## Map spills (ts-pattern, one checker, PGO)

- **Profiles:** 30 runs per build, `cpu_core/instructions/u` and `cpu_core/cycles/u`, summed.
- **Attribution:** each instruction goes to its innermost source line, so Map code inlined into its callers still counts as Map/Set.
- **Units:** millions per run.

| Pattern | base instructions | map-inline instructions | base cycles | map-inline cycles |
|---|---:|---:|---:|---:|
| **Map/Set** | 960 | **747** (22% fewer) | 479 | **420** (12% fewer) |
| Map/Set spills and reloads | 377 (205 reloads, 172 spills) | **38** (26, 12) | 129 | 25 |
| Map/Set callee saves and restores | 48 | 4 | 18 | 3 |
| Checker code | 3,302 | 3,316 | 1,348 | 1,339 |
| Checker code spills and reloads | 323 | 352 (+29) | 145 | 140 |
| `hashMix` / `hashWord` | 171 | 192 (+21) | 64 | 78 |
| Yield checks | 225 | 255 (+30) | 112 | 110 |
| List operations | 873 | 836 | 331 | 321 |
| **Whole program** | **8,670** | **8,527** (1.6% fewer) | **3,718** | **3,695** (0.6% fewer) |

## Verdict against the bar

The bar: more than 2% faster on PGO, or at least 1% fewer instructions with time no worse, and RSS no higher.

| Part | Result |
|---|---|
| Instructions | Passes, nearly everywhere: 1.4–1.8% fewer in seven of the eight PGO configurations. zod3 at one checker, cold, had 0.7% fewer in the 25-round run and 1.9% fewer in the 10-round run |
| Time | Passes in effect: no worse anywhere that matters, but never more than 2% faster except zod3 one checker cold (2.7%) |
| RSS | Misses, strictly: 0.1–0.3% higher (200–300 KB). It's file-backed text from the larger binary, the same as Rig's agent found; page faults are the same |

This agrees with Rig's agent's quiet re-time on instructions (1.44–1.65%), RSS (+0.1–0.3%) and direction. My wall-time gains are smaller: 0.4–2.7%, against its 0.6–6.9%.

**What inlining did:** the Map's spills and reloads fell by 90%, and Map/Set cycles by 12%. Callers paid part of it back: 29M more checker spills, and more `hashMix` and yield-check instructions inlined into them. The net is 0.6% fewer cycles at one checker.

## Files

The builds and raw profiles were in `/zfs/trig-pup/trial/mi/` and have been cleaned up. This report is on pup at `/zfs/trig-pup/trial/map-inline-crosscheck.md`.
