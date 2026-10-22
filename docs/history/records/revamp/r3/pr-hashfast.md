std.hash speed round (proposal-hashfast, the owner's decisions of 2026-10-15). The new Map API (`put_new`, `ensure`, `ensure_with`, `retain`, `?K` keys) follows in `hashapi`.

- Each entry's whole 64-bit hash is stored beside it, so no key is hashed twice, not when the table grows nor when an entry is taken. A slot is picked by the hash's low bits and the tag is its top seven, so the two never overlap at any table size.
- Small maps: up to 8 entries there is no table, and a lookup compares the stored hashes in turn.
- `reserve(n)` and `new(capacity: n)` on Map and Set.
- `hash.Symbols` (`Symbols()`, `intern`, `id`, `text`, `len`, `reserve`): dense `U32` ids for strings, whose text lives in one String.
- Layout (option A): insertion order kept for Map and Set; a Map entry holds its key plainly and only its value as an optional (a `U32` and a `U32?` for `U32 → U32`), and its 8-byte hash sits in a List beside the entries. Taking an entry empties its value in place; the next growth drops the entry. Map, Set and Symbols share one `Table`. A Set compacts in its own Lists, so room `reserve` made survives.
- `find` takes the whole hash; growth is `rarely`, out of line.

Timing (bench/hash, Mac, quiet window, interleaved, best of 7, ns per op). The Int and string hit, insert and miss rows are from the run with growth out of line, against main; the small, iterate and intern rows and the Zig column are from the run just before it, which differed only in that:

| row | this branch | main | Zig ReleaseSafe | vs main |
|---|---|---|---|---|
| int hit | 5.63 | 6.97 | 9.14 | 23.8% faster |
| int insert | 19.45 | 19.59 | 29.34 | 0.8% faster |
| int iterate | 0.73 | 0.98 | 4.49 | 33.4% faster |
| int miss | 8.48 | 8.29 | 9.87 | 2.3% slower |
| small 4 | 2.19 | 2.97 | 1.78 | 35% faster |
| small 8 | 2.87 | 3.15 | 1.88 | 10% faster |
| string hit | 23.50 | 23.93 | 39.35 | 1.8% faster |
| string insert | 36.79 | 36.88 | 78.57 | 0.2% faster |
| string intern | 11.30 | – | 11.75 | |
| string iterate | 0.73 | 0.93 | 4.51 | 27% faster |
| string miss | 15.05 | 15.02 | 14.73 | 0.2% slower |

`find`'s miss loop is instruction for instruction main's, with a shorter prologue; the Int miss gap is in the bench's caller, which rematerializes the hash constants on every iteration. std.json does not use std.hash.

Not done here: SIMD tag probing (2 against 3 allocations). A one-allocation table of 8-byte slots ran fewer instructions but was much slower (Int miss 36% slower), because 1-byte tags stay in cache.

Review: the reviewer's probes are kept as `test/corpus/rev236-*.rig`, shrunk to run in a second or two.

The owner accepted the Int miss gap for this round; it is fixed in `hashapi`.

Gates: suite (3850 passed, 0 failed) and corpus (10128 passed, 0 failed) on burst; vocab, style and unit on the Mac.
