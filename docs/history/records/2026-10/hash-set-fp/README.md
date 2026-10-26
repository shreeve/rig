# A hash given whole, and frame pointers in release builds (2026-10-25)

Two owner-approved experiments (map-stage decision 7b, committee B1's
decision 10), built and measured in #682. The owner then dropped the
first and took the second.

## `Hasher.set`: built, measured, dropped

**Question.** Trig's `CacheKey {lo, hi}` was taken to be a 128-bit
hash already, which Map hashes again with four multiplies. Would
`!h.set(w)`, a word given whole as the hash, pay?

**Built.** `sub set(!@, w: U64)` on the built-in Hasher. `set`
replaced what was added before it, and a later `add` mixed into the
word. There was no finishing mix. Tests covered a set key in a Map
and a Set, 100 keys whose words collide, both orders of `set` and
`add`, and misuse.

**bench/hash.** Two-word keys whose words are hashes, hashed by their
fields (`wide`) against `!h.set(@lo)` (`prehashed`), ns/op, fastest
of interleaved runs:

| | Mac safe | Mac fast | pup safe | pup fast |
|---|---|---|---|---|
| insert | 21.97 → 20.01 | 21.71 → 19.06 | 31.71 → 28.89 | 31.33 → 28.24 |
| hit | 8.22 → 6.40 | 7.73 → 6.12 | 13.25 → 13.81 | 12.83 → 13.01 |
| miss | 12.41 → 9.77 | 11.93 → 9.33 | 16.59 → 13.25 | 16.45 → 12.72 |

**Trig** (676760a in a scratch copy, pup core 6, `--singleThreaded`,
fastest of 15 interleaved):

| `CacheKey.hash_into` | ts-pattern | instructions | zod3 | instructions |
|---|---|---|---|---|
| none (by its fields) | 1190.5 ms | 10.840G | 222.3 ms | 1.966G |
| `!h.set(@lo)` | 35,238 ms | 660.6G | 1,209 ms | 20.6G |
| `set` on hashed keys; packed keys `add(lo)`, `add(hi)` | 1202.9 ms | 10.856G | 221.7 ms | 1.969G |
| `set` on hashed keys; packed keys one `add` | 1186.8 ms | 10.826G | 225.4 ms | 1.966G |

**Why it was dropped.** Most of Trig's hot keys are not hashes. They
are packed type ids (`keys.rig`'s `packed_types_key`, the relation
key in `relater.rig`): `lo = source << 32 | target`. Given unmixed,
their slot bits and tag bits barely vary, so every key crowds into a
few slots, and ts-pattern ran 30 times slower. With a branch that
gives only the hashed keys whole, the result is within noise (at best
0.1% fewer instructions). No gain on Trig, and a 30-times trap for
any key that is not a good hash.

## Frame pointers: omitted in release builds, taken

**Built.** `--release` and `--release=fast` pass
`-fomit-frame-pointer`; debug keeps them; `RIG_FRAME_POINTERS=1` at
build time keeps them in release.

**Trig** (frame pointers kept → omitted; pup core 8, then core 6, two
sessions):

| | task-clock | cycles | instructions |
|---|---|---|---|
| ts-pattern, 1 | 1198.6 → 1189.4 ms | 4.876 → 4.786G | 11.134 → 10.837G |
| ts-pattern, 2 | 1217.5 → 1190.5 ms | 4.800 → 4.790G | 11.141 → 10.840G |
| zod3, 1 | 241.3 → 234.4 ms | 0.872 → 0.861G | 2.015 → 1.963G |
| zod3, 2 | 225.8 → 222.3 ms | 0.877 → 0.869G | 2.016 → 1.966G |

That is 2.5-2.9% fewer instructions, and 1-2% faster.

**bench/tasks** (rig-fast). pup: spawn, chain, fanout and yield are
within 1% at their fastest, and hog is equal (2.27 against 2.28 ms).
hog is bimodal while other builds run. Mac, under load from other
sessions: chain, fanout and yield are within 2% or faster, and spawn
and hog swing 10-26% either way between passes.

**std.json** (rig-safe and rig-fast, six files). Ten of twelve are
within noise or faster on both machines. gsoc-2018 is 0.2-1.8% slower
on pup (three passes of four) and 0.7% (fast) and 1.5% (safe) slower
on the Mac. On pup it runs 0.4-1.4% fewer instructions but 0.8-2.3%
more cycles: a code-layout effect. The owner accepted it, to be
looked at during the std.json work.

**Profiling.** A release panic prints no trace, as before, and Zig's
unwinder reads the unwind tables, which stay. `perf record -g` on
ts-pattern sees 72 user frames a sample with frame pointers and 2.9
without. `perf record --call-graph dwarf` (perf 7.0.14 on pup)
recovers no user frames from any Zig executable, plain Zig included,
with frame pointers or without, so a profile with callers needs
`RIG_FRAME_POINTERS=1`.
