# The next win against tsrs: ranked (2026-11-01, night)

Measurement and ranking only: no PR, no shared file changed. Basis: standing-6
(Trig 806e0a1 PGO, one checker, P-core wall), the session notes (`beat-tsrs-list.md` and `queue.md`, outside the
repository), the records [four-checkers/](four-checkers/) (with
`union.md` and `store-forward.md`), [head-phases.md](head-phases.md),
[load-phase.md](load-phase.md), [lazy-dts.md](lazy-dts.md),
[typed-ids-ceiling.md](typed-ids-ceiling.md),
[typed-ids-rule.md](typed-ids-rule.md), and broad-corpus PGO
([timing-audit/harness.md](../timing-audit/harness.md)), Trig PRs #238-#242, and new counts taken tonight where the
records had a hole.

## What tonight's counts add (pup E-cores 14-19, `perf stat --no-scale`, no wall clock)

Data and scripts: [next-win-ranking-data/](next-win-ranking-data/).

### 1. tsrs's lazy members are worth far more than the Go-mode bar shows (lazy.txt, lazy2.txt, lazy3.txt, lazy4.txt)

tsrs 0.18.0 as shipped, one thread, outputs identical in every arm. Base is
the standing bar (`--checkerAssignment go --noLazyMembers`). "lm" is lazy
members as shipped; "lm−L10" is lazy members with `TSRS_LAZY_UNMATCHED=0`.
Medians of 6 runs (ts-pattern, zod3, tiny-invariant) or 3-5 (the rest).

| project | lm: user cycles | lm−L10: user+kernel cycles | lm−L10: instructions | lm−L10: page faults | lm−L10: peak RSS |
|---|---:|---:|---:|---:|---:|
| ts-pattern, 1 checker | 1.6-3.2% fewer | **6.4% fewer** | 7.2% fewer | 19.5% fewer | **20.5% lower** |
| ts-pattern, 4 checkers | | **6.7% fewer** | 7.3% fewer | | **20.1% lower** |
| zod3, 1 checker | 6.2-6.6% fewer | **8.1% fewer** | 9.4% fewer | 16.6% fewer | **13.7% lower** |
| zod3, 4 checkers | | **10.2% fewer** | 13.7% fewer | | **19.3% lower** |
| superstruct, 1 | 2.0-2.7% fewer | 2.3% fewer (user) | 4.2% fewer | | level |
| tiny-invariant, 1 | 9.7-10.7% MORE | **5.0% more** | 0.8% more | level | level |
| mitt, neverthrow, 1 | level | (not run) | | | level |

- L10 (lazy `getUnmatchedProperties`) costs tsrs itself on these projects;
  without it the gain roughly doubles on ts-pattern.
- L1 (tuple references lazy too) carries most of the memory: with L1 off,
  ts-pattern's RSS falls only 5.8% instead of 22%, and cycles 6.5% (3 runs).
- **Trig's ceiling in progress (`~/Data/Code/worktrees/trig/lazy-members-ceil`,
  4c931d9 + uncommitted) leaves L1 out**: `get_ready_lazy_member_table_worker`
  returns 0 for `OBJECT_FLAGS_TUPLE` (lazymembers.rig:103), as upstream #64475
  does. Measured as is, it will undersell the lead.

### 2. Training breadth is worth about one point, not seven (stat1.txt)

PGO against a plain build of the same source, one checker, cycles:

| project | in Trig's training? | PGO: cycles fewer | instructions fewer |
|---|---|---:|---:|
| zod3 | yes | 13.3% | 13.5% |
| mitt | yes | 11.2% | 14.3% |
| neverthrow | yes | 9.8% | 13.7% |
| superstruct | yes | 5.8% | 11.5% |
| ts-pattern | **no** | 12.3% | 11.7% |
| tiny-invariant | **no** | 12.3% | 11.7% |

Held-out projects gain as much as trained ones. pgo.md (2026-10-25) agrees:
ts-pattern trained on itself 13.5% fewer cycles, on zod3 10.7%, wall 11.3%
against 10.5% faster. Broad training was 2.2-3.4% slower (pgo-broad). So
checker0.md's "about 7% from the build" is not recoverable by a training set.

### 3. Where shipped tsrs's lead comes from, one checker (stat2.txt, td.sh)

| project | Trig plain / tsrs local (code) | tsrs's build takes off | Trig's PGO takes off | Trig PGO / tsrs shipped |
|---|---:|---:|---:|---:|
| ts-pattern | 1.090 | 16.8% | 12.3% | 1.150 |
| zod3 | 1.138 | 20.6% | 13.3% | 1.243 |
| tiny-invariant | 1.149 | 18.8% | 12.3% | 1.240 |
| mitt | 1.257 | 15.3% | 11.2% | 1.318 |

Top-down slots on ts-pattern (Trig PGO against tsrs shipped): retiring 10%
more (instructions), frontend 19% more (icache 46% more, iTLB 2× tsrs's;
together 2.9% of Trig's slots), backend 24% more (about 6% of Trig's cycles:
memory), bad speculation level. The largest piece is the backend, memory.

## Ranking: large projects (check time)

Gap at one checker (standing-6): ts-pattern 92 ms (13.5%), zod3 30 ms (25%).
At four: ts-pattern 70 ms, zod3 30 ms. Since then #238, #239, #240, #856 took
roughly 5-10 ms off each at four and 2-8 ms at one (their PRs' numbers).

| rank | lead | reach, 1 checker | reach, 4 checkers | RSS | confidence | cost and risk | owner |
|---|---|---|---|---|---|---|---|
| **1** | **Lazy members as tsrs ships them, without L10:** #64475 + #64526 (the ceiling), plus L1 (tuples), slot layout | ts-pattern about 6% (40-50 ms, half the gap); zod3 about 8% (about 12 ms, 40% of it); superstruct about 2%; mitt, neverthrow level | ts-pattern about 6.7% (15-20 ms); zod3 about 10% (8-10 ms) | **ts-pattern 20% lower, zod3 14-19% lower**: the largest memory lever known | medium: measured in tsrs, same algorithm; Trig's 10-21 port of #64475 alone was 0.7% slower on ts-pattern (no #64526, no L1, map tables) | about 680 lines already written as the ceiling, plus L1 (a condition and tuple base members); risk: tiny-invariant (tsrs 5% slower), exactness past the typescript-go pin, owner removed it once | Trig (Rig - Rust); owner decides the restore |
| 2 | Store-forward B (Map key by address) + C (Relaters in place) | 0.9-2.4% ts-pattern (estimates; ceilings being built) | similar | none | low-medium: #816 (rt-by-value) was 1.1-1.7% slower | small to medium; B Rig std, C Trig | Rig, Trig |
| 3 | Huge pages / faults (another agent) | records: Table gate open, ts-pattern 3.1% at 1, 2.3% at 4 | | +14% (owner: no) | measured, but the RSS form is refused | alloc.zig | Rig |
| 4 | Build: CSPGO, BOLT trained on large non-benchmark code, text on huge pages | 1-2% (frontend excess 2.9% of slots; training about 1 point; BOLT on PGO 0-1.5% twice) | same | text pages: +2-6 MB, bad for small projects | low | few lines, 20-minute builds per try | Rig (pgo.zig, bolt.zig), Trig tools |
| 5 | Typed table ids, the rest (phase B or the language rule) | at most 1.5-2% (ceiling 2.7% / 3.3% with phase A's share inside) | | level | ceiling measured; remainder not | CORE review, language, proofs; blocked since #858 | Rig |
| 6 | Per-call checker: relation cache as a packed slot, intersection intern probe | at most 1.7% of checker 0; 0.6% | | | low | Trig + Map layout | Trig |
| — | Union front cache (trig#242) | 0.6% instructions, no time | | | measured | close, or stack with 2 | Trig |
| — | Tighter cache keys (trig#241) | cycles level | | **2.2% lower** | Mac measured | done: pup timing and light gate only | Trig: land it |

## Ranking: small projects (start-up)

Gap at one checker (standing-6): mitt 4.2 ms, neverthrow 5.5, superstruct 8,
tiny-invariant 14. Since then #238 (1.5-1.8% at one), #240, #856 and the
harness bias correction (1-2 ms of Trig's small one-checker numbers) shrank
mitt's and neverthrow's to roughly 2-3 ms. tiny-invariant behaves like a
large project (check-bound, no gain from start-up work).

| rank | lead | reach, 1 checker | reach, 4 checkers | RSS | confidence | cost and risk | owner |
|---|---|---|---|---|---|---|---|
| **1** | **Lazy .d.ts binding, as tsrs ships it by default** | mitt, neverthrow about 1.5-2.5 ms (7-11%, most of the gap left); zod3 about 1.7 ms (1%); ts-pattern 0.2%; superstruct, tiny-invariant about 0 (tsrs shows none) | lib.dom's bind is the longest bind task: about 1.5-2 ms on mitt, neverthrow | tsrs loses 24-25% RSS on mitt and neverthrow without it (zod3 7%); Trig's RSS on mitt is 78% over tsrs's | medium: tsrs measured tonight; Trig's bind bound 1.7-1.9 ms (Mac) | 300-500 lines (bind a list on the checker's first ask, atom order kept for parallel bind's merge) | Trig; **owner said "no prototype for now"** |
| 2 | Parse to tsrs's speed (lexer scan 1.6×, parser 1.24×) | gap about 2.5 ms P-core per run with lib.dom; next pass realistically 0.5-1 ms (2-4% of mitt) | same, on the critical path | none | measured gap, pass yield uncertain | in flight (Rust, pass 4) | Trig |
| 3 | Loader: walk past unfinished libs, project files in tasks | nothing | zod3, ts-pattern 3.5-5 ms (zod3 about 4%); small about 0 | none | estimate from loader-ts timestamps | moderate (file order kept) | Trig (Merges, worktree walk-ahead) |
| 4 | Multi-checker start-up for small projects (pick the count by size) | | mitt Trig4 28.7 against Trig1 22.9 ms | lower | measured | small | Trig |

## The single next win

**Lazy members with L1 and without L10.** It reaches about half of
ts-pattern's one-checker gap and 40% of zod3's, at one and at four checkers,
and cuts peak RSS 14-20% on the large projects, which the owner values above
speed. The code is mostly written. The owner's test ("ts-pattern ≥2%
faster") is the wrong yardstick by itself: tsrs as shipped gets only 1.6-3.2%
on ts-pattern because L10 costs it, while zod3 and memory carry most of the
value.

**First step:** in the ceiling worktree, add L1 (drop the
`OBJECT_FLAGS_TUPLE` exclusion, as tsrs's bd93422 does, with tuple base
members built lazily), keep L10 out, then `time-ab.sh` on pup: main, A/A,
ceiling, ceiling+L1; 1 and 4 checkers; six projects; 60 rounds on the small
ones; peak RSS from tmpfs; outputs identical. Report time, RSS and
tiny-invariant to the owner with the line count.

**What would change my mind:**
- ceiling+L1 under 2% on ts-pattern and zod3 *and* under 10% lower RSS:
  Trig's tables then cost more than tsrs's, and lazy .d.ts binding (small
  projects) or store-forward B+C go next;
- tiny-invariant more than 2% slower with no fix;
- the owner holding the pin rule (no restore until typescript-go passes
  #64475/#64526).

## Not measured, and why

- Wall time: no wall-clock timing on pup tonight; the tsrs figures are E-core
  cycles, and P-core wall usually follows (kernel cycles fall too).
- Trig's own lazy-members gain: needs the ceiling's build, which is Rig -
  Rust's and in progress.
- CSPGO and BOLT on new training: needs release builds (not allowed on pup
  tonight).

## Addendum after cross-review of huge-pages.md (Table heads in one STLB set)

- **The next win becomes Table coloring** (reserveTable offsets each Table by
  a distinct page count). It costs a few lines in Rig, no owner decision, and
  no RSS. Expected about 2-4% on E-cores. Lazy members stays first by reach
  (about 6-8% and 14-20% less RSS) but costs about 700 lines and an owner
  decision. New order: coloring (next), lazy members, lazy .d.ts binding.
- **Order for clean measurements:** land coloring, and decide whether to drop
  the Table huge-page advice (step 2, which removes the 10.7 MiB RSS
  bimodality), before timing the lazy-members ceiling. Build both of that
  ceiling's arms with the colored Rig. Lazy members does not change how many
  Tables exist (head count), only their sizes and how many pages they touch,
  so the overlap should be small. Measured on an uncolored base, though, part
  of its gain would be TLB work that coloring already removes.
- **Doubts:** the 14x walk excess and the 3.8-4.5% stall share are E-core
  numbers; P-cores, where wall time is judged, show 3.3x (earlier records),
  so their STLB may index or associate differently, and the P-core gain may
  be nearer 1-2%. Run the E-core walk counters and the P-core time-ab.sh on
  the same builds. The micro's 2.1x is the mechanism at full strength, not a
  forecast. My topdown backend excess (about 6% of Trig's cycles on
  ts-pattern) has room for the 2.5-3% that removing two thirds of the stalls
  would give. Coloring mod 128 still puts about 1.6 heads per set at four
  checkers (about 200 heads), which is fine below about 16 ways.
