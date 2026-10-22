std.hash's Map write API, the follow-up to #236. Keys are owned `K` until generic deep clone lands (TODO.md).

- Int miss: the gap to the old std.hash was in the bench's own code, not in `find`, whose miss loop is main's, instruction for instruction. With every group inlined into `main`, the hash constants were rebuilt on each iteration. Each bench group is now `called`, a function of its own, on both sides of the comparison: Int miss then measured 1.3% faster than the pre-#236 std.hash (off-window, load 3.2; to be confirmed in a quiet window).
- `put_new(k, v) -> Bool`, `ensure(k, v) -> !V from self, k, v`, `ensure_with(k, make: ?fun(?K) -> V) -> !V from self, k`, and `retain(f)` on Map and Set. A rejected entry drops when `retain` rejects it; a Set's and a Map's Lists keep their room.
- Tests: hash_writes, hash_write_drops, hash_ensure_with, hash_ensure_chain, hash_compound_keys, the churn test over the new methods; reject tests that the views keep the Map lent and that `retain`'s and `ensure_with`'s closures cannot reach the Map, and that a lookup takes the Map's own key type.
- The `!(!b).m(...)` hint, where the call's value is used, now says to remove the outer `!`; statement forms behave as on main.
- STD.md: the new rows, `ensure_with` as the way to make a value only for a new key, edit-then-put as the fallback, compound keys.
- The adversarial review's probes are kept as `test/corpus/rev240-*.rig`; the two the reference checker rejects are listed in test/oracle/rejections.

Timing against main (bench/hash with the `called` groups on both sides; Mac at load 3.1, interleaved, best of 15, ns per op):

| row | this branch | main | vs main |
|---|---|---|---|
| int hit | 5.45 | 5.36 | 1.7% slower |
| int insert | 19.66 | 19.85 | 1.0% faster |
| int iterate | 0.76 | 0.76 | 0.4% slower |
| int miss | 8.32 | 8.28 | 0.4% slower |
| small 4 | 2.20 | 2.22 | 1.1% faster |
| small 8 | 2.96 | 2.94 | 0.6% slower |
| string hit | 26.62 | 26.97 | 1.3% faster |
| string insert | 53.75 | 54.95 | 2.2% faster |
| string intern | 12.48 | 13.23 | 6.0% faster |
| string iterate | 0.74 | 0.74 | 0.5% faster |
| string miss | 16.98 | 17.03 | 0.3% faster |

`find`, `get`, `put` and `Symbols` emit the same Zig as main's; the spread is the Mac's noise (two earlier runs at load 4 to 5 swung single rows up to 9% either way on unchanged code).

Speed of `ensure_with` against edit-then-put (Int keys, 1M ops, off-window): miss 0.2% slower, hit 31% slower. LLVM keeps `ensure_with` out of line (a generic member is never emitted `inline`), so a hit pays a call frame and the hash constants that edit-then-put, inlined, keeps in registers. `ensure` on a hit: 39% slower than edit-then-put; on a miss 6% faster.

The owner decided to land it and fix the hit cost in the inline round (TODO.md, "Inlining a generic type's small methods"). STD.md makes no speed claim for either.

Gates: suite on burst after #243, with the JSON data: PASS; corpus on burst: PASS; vocab, style, unit on the Mac.
