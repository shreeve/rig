# Map replay

Replays one stream of map operations on Rig's `Map` and `HashMap` and on
hashbrown, to answer how much faster a program would run with a std map
as fast as hashbrown. The stream comes from a spec (synthetic) or from
the records a program built with `RIG_MAP_TRACE=1` wrote (real). Every
arm replays the same trace and prints the same checks.

| Arm | Table | Hash | Built from |
|---|---|---|---|
| `rig-map` | the built-in ordered `Map` | Rig's | `replay.rig`, `rig build --release` |
| `rig-hash` | the built-in unordered `HashMap` | Rig's | `replay.rig` with each `Map[` made `HashMap[` |
| `hb-fx` | hashbrown 0.17.1 | rustc-hash 2.1.3's FxHasher, as tsrs hashes | `rust/`, `--features fx` |
| `hb-fold` | hashbrown 0.17.1 | foldhash 0.2.0 (`fast::FixedState`) | `rust/` |
| `std-fx` | std's `HashMap` (hashbrown as std vendors it) | FxHasher: tsrs's `FxHashMap` | `rust/`, `--features std,fx` |

```sh
R=bench/hash/replay/replay
$R gen bench/hash/replay/specs/a-large-u32.spec -o a.rpl
$R import rig-map-trace.bin --types '^Pair$' --top 5 -o real.rpl
$R build --out D                 # --cpu meteorlake: Zig and Rust for that CPU
$R time --out D --aa hb-fx a.rpl real.rpl
```

`build` needs `bin/rig` (or `$RIG`) and `cargo`, which builds offline
from the crates `rust/Cargo.lock` pins. `time` runs every arm once per
round, the arms in an order that rotates each round, for 11 rounds
(`--rounds`), and prints each kind's median ns per op, its ratio to
`hb-fx` (`--base`), and the checks, which must agree or it stops.
`--aa ARM` adds ARM again as a second arm: the gap between the two is
the noise.

## Specs

A spec is one map's shape, one setting a line, `#` to the end of a line
a comment:

| Setting | Means | Default |
|---|---|---|
| `key K` | `u32`, `int`, `pair` (two Ints), `triple` (three), or `text MIN-MAX` (bytes of `[a-z0-9_]`) | `int` |
| `ids dense\|random` | ids drawn from `0..U`, U `universe` times the keys put (for a pair or triple, each part from a range that size's square or cube root), or random 32- or 64-bit numbers | `dense` |
| `universe X` | the ratio above | 2 |
| `value B` | the value's bytes, held as 1, 2, 4 or 8 Ints (the fewest that hold B) | 8 |
| `instances N` | how many maps | 1 |
| `size N` or `MIN-MAX` | the keys put into each map, uniform in the range | 1000 |
| `mix kind=pct ...` | the share of ops of each kind: `insert`, `overwrite`, `hit`, `miss`, `remove`, `iterate`, `clear`; the inserts (the sizes' sum) set the number of ops | `insert=100` |
| `order interleaved\|build` | segments of every kind shuffled together, inserts spread over the maps at random; or each map's inserts in turn, then the rest shuffled | `interleaved` |
| `block N` | ops a segment, the unit timed | 256 |
| `drop yes\|no` | drop every map at the end, timed as `drop` | `yes` |
| `seed N` | the generator's seed | 1 |

A hit, an overwrite and a remove name a key the chosen map holds (a map
chosen uniformly among those holding any); a miss names one it does not
hold; an iterate walks a map chosen uniformly, all of it.

## Real traces

`import` reads `rig-map-trace.bin` and `.types` beside it
(docs/internals/INTERNALS.md, "The Map trace"), keeps the maps chosen
(`--ids`, `--types REGEX` on the key type, `--top N` busiest), and
writes their records as one trace: a `get` is a lookup, a `put` a put
(`insert` or `overwrite` by whether the map held the key), a `remove` a
take, `new`, `drop` and `clear` themselves; `grow` (the table's own) and
`retain` (whose test the trace does not hold) are left out, and counted.
A run of one kind at least `--run` (64) long is timed as that kind, and
the ops between such runs, in their order, as `mixed`.

The keys are rebuilt from each record's width, hash and first 24 bytes:
a key of up to 24 bytes is exact; a wider text keeps its first 24 bytes
and its length, with the hash's hex after them, so keys equal in the
trace are equal here and keys distinct there stay distinct unless both
their hashes and their first 24 bytes agree. `import` replays each map
as it goes and says how many lookups found or missed their key other
than the trace says (0 when the keys are faithful). The key kind is the
one that holds the widest key: up to 4 bytes `u32`, 8 `int`, 16 `pair`,
24 `triple`, and text for text. A replay holds keys of one type, so the
maps chosen must share theirs.

## The trace

Little-endian. A header of nine `u32`: the magic `RPL1`, the key kind
(0 `u32`, 1 `int`, 2 `pair`, 3 `triple`, 4 text), the value's Ints, the
maps, the keys, the ops, the segments, the text's bytes, and the offset
of the ops. Then the keys: each as 1 to 3 `u64` words (a `u32` in the
low half of one), or for text `keys + 1` `u32` offsets and the bytes,
padded to 4. Then the ops as three arrays, `u8` op codes (0 put, 1 get,
2 take, 3 walk, 4 new, 5 drop, 6 clear) padded to 4, `u32` maps and
`u32` keys; then the segments, each `u32` kind (0 insert, 1 overwrite,
2 hit, 3 miss, 4 remove, 5 iterate, 6 new, 7 drop, 8 clear, 15 mixed),
first op, and count.

A put at op `j` writes the value `j, j + 1, ...`; the keys each put
moves in are made before the clock starts, apart from the keys lookups
use, so a text compare reads two strings. Each segment's loop is a
function of its own that reads the clock around it; a kind's check
sums what its ops found: the length after each put, `v[0] + 1` for a
lookup that finds `v`, `v[last] + 1` for a take, each walked value's
`v[0]` and the length for a walk, the length plus one for `new`, `drop`
and `clear`.
