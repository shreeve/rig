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

### The share after item 1 (data/t5.tsv)

plainmap (item 1 + switch) against plain (item 1), ts-pattern: 3.3% fewer
instructions (12,863 -> 12,440 Mi), 2.9% fewer cycles, 1.3% less time;
zod3 2.7% fewer instructions. t6/t7 (core 7 idle 0.02%) put plainmap at
2.0-2.2% fewer cycles and 1.3-1.9% less time than main. So the share is
over the 1% bar, and building was tried.

### What was built (branch map-checks, never pushed; patches in map-checks-patches/)

1. Probes bound their index by both table Lists (`i < ts.len and i < ats.len`),
   so `ts[i]`, `ats[i]` are proven in Map.find, Set.find, Table.place (which
   now probes itself; `free_slot` gone) and std.text's Interner; the small
   scans bound by the entries too; the four iterators walk a slice under
   `0 <= j and j < es.len`; `@len +%= 1` in insert/add_new.
   test/cli/std_proofs.sh: every index by i/j in find/place/next proven but
   `@es[j]`/`@ks[j]` (fails on main: `@tags[i]` in place).
2. `home_of(h, n) = Int(h & 0x3FFF_FFFF_FFFF_FFFF) & (n -% 1)`: the home
   slot with no checked conversion (x86 asm: lea/and/movabs/and, no branch;
   the old form had jo + js).
   Full suite green on the Mac (9,624 jobs) for (1).

### Result (data/t7.tsv, 15 rounds, core 7 idle), change against main2 (main 86af3b982)

| project | mapfix (1) instr | cycles | time | mapfix2 (1+2) instr | cycles | time |
|---|---|---|---|---|---|---|
| ts-pattern | +0.07% | +0.28% | +0.29% | +0.07% | +0.22% | +0.20% |
| zod3 | 0.00% | 0.00% | -0.09% | 0.00% | +0.10% | 0.00% |
| tiny-invariant | -0.08% | -0.24% | -0.61% | -0.08% | -0.73% | -0.91% |

Branches drop (ts-pattern 2,574 -> 2,532 Mi) but instructions do not: the
removed tests are replaced by the second guard compare and the mask. No gain
on Trig, so no PR (a speed feature pays for its lines).

bench/hash on pup core 6 (main2 vs mapfix, two runs, 21 and 31 reps): mixed,
within the bench's own noise (one run had string iterate 47.6% slower, the
next 6.4% faster); Mac runs at load 5-9 were noisier still.

### Where the rest of the ceiling is

`@setRuntimeSafety(false)` does not reach inline callees (asm/s.zig: an
inline callee's @intCast keeps its test under a caller's safety-off), so the
ceiling is the builtin module's own checks. What the switch removed and the
restructure did not: the entry index from a slot or from find, tested again
in each public method (`?@es[j].value` in get/edit/replace/ensure after
find; `@es[j].key` in find's hit; `@hs[j]` in hash_at during rebuild),
`U32(j)` in place, and the growth arithmetic (`(@es.len + 1) * 5 >
@table.tags.len * 4`, `@es.len - 1`, `table_size`'s `n *= 2`). Those are
indexes valid by construction (class c/d in the report): no fact shows
them. Taking them needs either a typed entry index the Map makes and only
it can use (panel B decision 5, default no) or find handing back the entry
view rather than its index, which the ownership checker's "return a write
view bound by `if !@slots[j]`" limit (HANDOFF, Next 3) blocks for `edit`
and `ensure`. Both are owner-level choices.
