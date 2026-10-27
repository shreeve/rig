# The ordered Map's rewrite: from zig-ordered to std/prelude.rig (2026-10-27)

Rig's built-in `Map` and `Set` (`std/prelude.rig`) take the design of
`bench/hash/ordered.zig` ([zig-ordered.md](zig-ordered.md)), so that the
Zig that Rig emits for them is within 2% of the prototype on every
bench/hash row on the Mac and pup, and Trig, whose hottest maps these
are, gets faster against tsrs. The unordered `HashMap`/`HashSet` follow
from `bench/hash/hash.zig` the same way, after this.

## What each part becomes in Rig

| Prototype | In Rig | Needs |
|---|---|---|
| Entries: `{key, value}` in first-put order, no optional for plain K and V; the hash kept in the entry for keys over 8 bytes | `es: List[Entry[K, V]]`; under `if $plain(K) and $plain(V)` the entry holds `value: V`, else `value: V?` as today | `$plain` narrowing (#701, on main) |
| Gone bits, one per entry, in the entries' own allocation | `gone: List[U64]`, made at the first take | a second allocation at the first take; the prototype's builder measured the one-allocation form as worth having, so record the cost |
| Index: groups of 16 tag bytes (15 tags and an overflow byte), and 16 `U32` entry indexes per group on a 64-byte line | `tags: List[U8]` of `16 * G`, `at: List[U32]` of `16 * G` | a List aligned to 64 bytes, or measure without |
| Group match | `ts.read[Simd[U8, 16]](16 * g) == Simd.splat(tag)`, then `for k in m.lanes()` | `m.lanes()` (#728, on main) |
| Group position `h >> shift`, triangular probe `g = (g + step) & (G - 1)` | the same, in Rig | the masked-index proof (in progress), extended to a group read: `16 * (g & (G - 1))` read 16 wide from a List of `16 * G` |
| Entry index read from `at`, then `es[j]` | the same; the `es[j]` test stays (decision 10) unless the checked variant shows it costs over 2% | — |
| Slot-line prefetch with the tag load | `at.prefetch(16 * g)` | `xs.prefetch(i)` (in progress) |
| Small maps, up to 16: a 16-byte tag vector in the Map object | a field `small: Simd[U8, 16]` | — |
| The walk past the home group out of line in a lookup, inline in a take | a `rarely` function for the walk | `rarely` in a branch as `.unlikely`: the builder measured rnd16 miss 0.50 against 0.84 without it (the panel's decision 9 keeps one word) |
| Take: clear the tag, set the gone bit, boost's anti-drift | Rig code; the key is dropped at once (decision 4) | — |
| Compaction by rank, no rehash; a drift rebuild at most 0.6 full | Rig code (decision 6) | — |
| Iteration by runs over the gone words | `Items`, `Keys`, `Values` rewritten over runs | `ctz` on a `U64` |
| Hash: one multiply for an Int key (decision 7, measured on zig-hash) | `hash_of` inside the Map | — |

Every member stays as it is, in name, signature, and ownership:
- `get`, `edit`, `put`, `replace`, `put_new`, `ensure`, `ensure_added`, `ensure_with`, `ensure_by` (#719), `take`, `has`, `len`, `reserve`, `clear`, `at`, `items`, `keys`, `values`, `update`, `retain`;
- the order: first put, a re-put keeping its place;
- printing.

`test/rig/` cases of Map and Set and every doc example must pass
unchanged.

## What the prototype's builder found Rig needs beyond the panel's list

1. The gone bits in the entries' own allocation, or the first take in
   every map costs an allocation.
2. A fixed `[32]U8` of tags inside the Map object, for small maps.
3. `rarely` in a branch emitting `.unlikely`.
4. Hot loops that call no helper able to panic: a cold panicking helper
   called from the lookup loop made LLVM reload the Map's fields every
   lookup (the checked variant's first build cost 20-31%).

## Order

1. The masked-index proof and `xs.prefetch(i)` land (in progress).
2. The group-read form of the proof, and `rarely` as `.unlikely` in a
   branch, if the owner agrees: both measured on the prototype first
   (zig-ordered against zig-ordered-checked).
3. The rewrite, in one PR:
   - built against `zig-ordered` row by row in `bench/hash` (a `rig-fast`
     variant against `zig-ordered` and `zig-ordered-checked`);
   - Trig release on pup, ts-pattern and zod3, against today's main;
   - std.json's guard.
4. `HashMap`/`HashSet` from `zig-hash`, the same way.
