# Length invariant and Map/Set checks: notes

Rig origin/main b37e08158; Trig 86618f1a5 (the safety report's). pup, Trig
release builds through Trig's slot locks; timing on core 6, core 7 idle,
fastest of 10 interleaved (`stage/timeit.py`, `stage/summ.py`), output
byte-identical in every run.

## Item 1: the List length invariant (PR #538, branch len-invariant)

Where a length enters, and why each is at most `max_len = 2^62 - 1`:

| source | how it holds |
|---|---|
| List, element >= 1 byte | `len <= buf.len`; `buf` from `allocSlice`/`reallocSlice`, which now panic above `max_len` (and no allocator gives 2^62 bytes anyway); inline room is a small constant |
| List, zero-bit element | `grow` sets the buffer to `max_len` (was `maxInt(usize)`) and panics when `want > max_len`; `filled`, `initCapacity` go through `allocSlice`/`reserve` |
| String | its bytes are in memory (u8); grown by `String.grow` (reallocSlice) or by std's ArrayList in shims (std.file, std.http, net) - real memory |
| slice, element >= 1 byte | views of Lists/Strings/arrays, subslices (<= the source), shim results: all in memory |
| slice, zero-bit element | not bounded by memory: `lenOf` keeps `len`'s test (comptime choice) |
| array | constant length: `lenOf` keeps `len`, which folds |
| `Cell(List)` | `listLen` is `lenOf` |
| par.map's out List | `initCapacity(xs.len)`, `out.len = xs.len`: bounded by the input slice |

Emit: both `rig.len(x.len)` sites (`emitMemberNamed`) now write `rig.lenOf(x)`.
Trig's emitted Zig: 2,646 `rig.len(` -> 2,646 `rig.lenOf(`, 0 `rig.len(`.
Calls to `lenPanic` in the binary (objdump): base 1,879, plain 362, mask 285.

Variants of `heldLen` measured (Trig, pup):

| project | variant | instr | cycles | time |
|---|---|---|---|---|
| ts-pattern | plain (landed) | -1.81% | -1.19% | -1.40% |
| ts-pattern | mask `n & max_len` | -1.35% | -0.63% | -0.67% |
| zod3 | plain | -1.64% | -0.75% | -2.87% |
| zod3 | mask | -1.27% | -0.79% | -5.54% |
| tiny-invariant | plain | -1.11% | -0.63% | -2.32% |
| tiny-invariant | mask | -1.37% | -0.25% | -7.17% |

(time on the small projects is noisier than cycles.) `assume` (`@setRuntimeSafety(false); if (n > max_len) unreachable`) measured below if pup allowed.

bench/hash on the Mac (base, plain, mask, assume): per-operation swings of
+-20% between two runs of the same binaries; no conclusion possible from it.

`rig check --time` on Trig (Mac, tools/low, fastest of 5): base 3760 ms,
len 3638 ms.

Suite: `swarm test/rig.rip all -q` green on the Mac (9,549 jobs).

## pup incidents

- 23:14: pup ran out of memory while my two release builds ran beside
  Trig's (my slot.sh copy used Trig's lock names, but my Rig `zig build`s
  ran beside them). Afterwards: one build at a time, through
  /zfs/trig-pup/trial/slot.sh, gated on free memory (build3.sh/build4.sh).
- The coordinator stopped the assume build when pup had 0 GB free; it
  reruns gated on 12 GB available and at most one other release build.

## Item 2: Map/Set internal checks

Measuring switch: `scripts/map-switch.py` (throwaway; RIG_MEASURE_MAP=1):
in the module std/__rig_builtin.rig only, every Int index is written
proven both ways and every function starts with
`@setRuntimeSafety(false)` (54 of 62 Zig fns: the rest are type
functions).

### Item 1, second run (data/t2.tsv on pup), base / plain / assume

| project | plain instr | cycles | time | assume instr | cycles | time |
|---|---|---|---|---|---|---|
| ts-pattern | -1.81% | -0.87% | -1.80% | -2.58% | -2.02% | -1.66% |
| zod3 | -1.64% | +0.11% | -1.91% | -2.46% | -0.95% | -1.54% |
| tiny-invariant | -1.11% | +0.21% | -0.79% | -2.37% | -0.52% | -0.25% |

Plain landed (PR #538, merged 2026-10-22 06:24 UTC in the coordinator's
combined gate). assume left as a one-line option in `heldLen`.

## Item 2 measurements (pup, Trig 86618f1a5)

t4 (15 rounds, rows with core 7 busy dropped), change against base:

| project | plain (item 1) time | map (main + switch) instr | cycles | time |
|---|---|---|---|---|
| ts-pattern | -2.15% | -1.52% | -1.26% | -1.71% |
| zod3 | -0.75% | -1.15% | -0.98% | -0.57% |
| tiny-invariant | -0.20% | -1.15% | -0.13% | +0.65% |

t3 (core 7 70% busy overall, rows over 2% dropped): ts-pattern map -0.62% time, -2.02% cycles.

The map variant includes the Map's own length reads, which item 1 already
removes. Its increment over item 1 is measured by plainmap (item 1 + switch)
against plain.
