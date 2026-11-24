# Map sizing: Trig's real map streams replayed against hashbrown and indexmap (2026-11-24)

Measurement only; nothing landed. Trig d78aa3f3, read only. The harness, `bench/hash/replay/`, is
patches/rig-replay.patch (14 commits on a local scratch branch, base 91b4381b5); the trace's walks, `at` and creation
sites are patches/rig-trace.patch (2 commits on 383a1b2b5, Trig's pin, which built the traced Trig). Traces and their per-project summaries: data/trace.md,
data/summary-*.md. Timings: data/pup-agg.txt (pup E-core 18, 10 rounds), data/pup-a.txt and pup-b.txt (the synthetic
specs), data/compact3.txt, data/mac-*.txt; Trig's c1 walls on the same core: data/pup-walls.txt (5 runs, interleaved).

## Verdict

A std Map as fast as hashbrown would not make Trig faster. On pup E-core 18, replaying each project's top maps and
sites, switching all of them to hashbrown+Fx (tsrs's setup) is slower on three of four projects; picking the best
table per map gains at most 0.57%. indexmap, the like-for-like ordered table, is slower than Rig's Map on every stream.

| Project (b1r c1 wall, E-core 18, 5 runs) | Ops covered | All to hashbrown+Fx | Best table per map | indexmap+Fx |
|---|---:|---:|---:|---:|
| Compiler-Unions (409 ms) | 79% | +0.42% (+0.53% scaled to all ops) | +0.57% | −0.93% |
| typeorm (1268 ms) | 49% | −0.38% | +0.02% | −0.72% |
| webpack (1886 ms) | 51% | −0.61% | 0.00% | −1.28% |
| supabase-studio (7112 ms) | 58% | −0.69% | +0.06% | −1.74% |

Plus = Trig faster, as a share of its c1 wall on the same core. A second run reproduced these within about 0.1 point.
A/A noise: median 0.7% per stream. Caveat: each replay runs one map alone with a warm cache, unlike Trig's run.

- hashbrown wins on mid-sized maps probed hard on hits and never walked (`remove_subtypes .key_types` 0.72x Rig's time,
  `big_branch` 0.77-0.87x, the supabase caches 0.86-0.96x): one probe for a miss and its insert, the key in the probed group.
- It loses on maps made and dropped by the thousand, the 559k-entry `.instantiations` (1.5-1.8x), and walks.
- Synthetic specs: Rig's Map takes 0.76x hashbrown's time on (a) without walks and 0.72x on (b); checksums agree on both machines.

## Inline size (the owner: under 64 bytes, and free to pick a different structure)

Rig `Map`/`Set` 64 B, `HashMap`/`HashSet` 56 B, hashbrown 32 B, indexmap 56 B. Prototype `zig-compact`
(`bench/hash/replay/compact.zig` in the patch, checked against a model over 1M random ops): 8 B, an ordered table behind one
pointer, empty map allocates nothing. It costs 0.05-0.40% of Trig's wall against today's Map (0.97x hashbrown).
No faster design here needs more than 64 B. Not prototyped: a 16 B inline variant; an unordered path for never-walked maps.

## Arms

rig-map, rig-hash (built-ins); hb-fx (hashbrown 0.17.1 + rustc-hash 2.1.3, tsrs's); hb-fold (foldhash 0.2.0);
std-fx (std HashMap + Fx, tsrs's FxHashMap); idx-fx, idx-fold (indexmap 2.14.2, `shift_remove`); zig-ordered
(bench/hash/ordered.zig, 128 B, clear = drop and rebuild); zig-compact. Rig and Zig arms on Rig's allocator, Rust on
glibc malloc. Builds: Rig/Zig on burst `-mcpu=meteorlake` (no AVX-512); Rust on pup E-cores 12-15 (approved, 10.8 s /
210 MB, then 17 s / 218 MB); on the Mac foldhash 0.2.0 built from the cached source. Nine arms agree on every checksum,
including all 40 of Trig's streams (imported exactly, 0 hit/miss mismatches).

## Per stream on pup (ns/op for Rig's Map; others as a multiple of it)

| Stream | walks / `at` | Map | hb+Fx | indexmap | compact |
|---|---|---:|---:|---:|---:|
| CU `big_branch` | 64 / 68k | 5.48 | 0.89x | 1.19x | 1.09x |
| CU `.key_types` | 0 / 0 | 4.80 | 0.72x | 1.11x | 1.03x |
| CU Binding locals | 0 / 0 | 8.46 | 1.00x | 1.17x | 0.97x |
| CU `.named` | 0 / 0 | 8.22 | 1.40x | 1.56x | 1.42x |
| supabase caches | 0 / 0 | 6.29 | 0.96x | 1.12x | 1.10x |
| supabase `big_branch` | 5418 / 5.0M | 7.63 | 1.17x | 1.57x | 1.12x |
| supabase `.instantiations` | 0 / 0 | 20.7 | 1.62x | 2.02x | 1.16x |
| supabase `grow_table` | 0 / 1.5M | 12.6 | 1.73x | 2.66x | 1.18x |
| webpack `.instantiations` | 0 / 0 | 18.8 | 1.63x | 1.68x | 1.24x |

## Design notes and limits

- The caches are 30% of replayed ops. Clear is already cheap once it zeroes only 16 tag bytes; an O(1) generation clear is not worth it.
- `big_branch` and `grow_table` use `at` heavily, so they must stay ordered.
- Replay leaves out `at` and `grow`, replays `iter` as a full walk, and uses synthetic Int values.
- Possible checker bug: a generic body needed `keeps owned` even with `K: Owned`.

## Decision

Rig: no std Map change for speed. The 8 B compact Map goes to the owner only with a census of how many Maps and
Sets in Trig's long-lived records are empty or small at peak, and the bytes 8 B would save.

## Addendum: the empty-Map census (2026-11-24)

Whether an 8 B Map would save memory: Maps and Sets alive by length in Trig at c4 (data/census.md; counters under
`RIG_MAP_CENSUS=PATH` in a traced build, the third commit in patches/rig-trace.patch). A Map is counted at its first
write or clone and at every drop, named by type and field; a Map never written is seen only at its drop, so at peak RSS
it is bounded: low, those dropped at teardown; high, every one dropped after the peak (short-lived locals included).

| | supabase-studio | webpack |
|---|---|---|
| Maps alive at peak RSS, low bound (0 / 1-4 / 5-16 / >16 entries) | 2,521 / 14,573 / 49,140 / 17,758 | 600 / 1,580 / 11,141 / 4,341 |
| Peak RSS, plain build | 1,930 MiB | 684 MiB |
| Net saving at 8 B, low bound | 0.8 MiB (0.04%) | 0.2 MiB (0.02%) |
| Net saving at 8 B, high bound | 10.3 MiB (0.53%) | 6.0 MiB (0.87%) |

The saving is 56 B for each live Map or Set less 48 B out of line for each non-empty one (compact.zig's header and
tags). Long-lived Maps are rarely empty; the long-lived empty ones are almost all `ast.Binding.node_fields` and
`.local_tables` (Map[U32, U32]); the high bound is mostly locals never written, which churn rather than stay alive.

**Decision (Rig):** keep the 64 B Map. The 8 B Map is measured and not worth it: at most 0.9% of peak memory, at the
low bound nothing, for 0.05-0.40% of the wall. Lazy Binding tables are Trig's call (sent to it as a finding).
