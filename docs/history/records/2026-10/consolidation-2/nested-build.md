# A release build of a chain of objects nested by value

Consolidation round 2, track 2, row 4. Measured 2026-10-24 on the Mac,
each build through `tools/low`, one at a time, nothing else running.

The program: `n` objects, `O0` holding an `Int` and a `String`, each
`Ok` holding `O(k-1)` by value and an `Int`; `make(k)` calling
`make(k-1)`; `main` makes the last, clones it, compares, and hashes
(`rig build --release`, Zig's safe mode).

## Where the time goes

At 200 links, built with each operation alone (main, a4806b8b7):

| `main` does | release build |
|---|---|
| make the chain, print a field | 3.4 s |
| the same, every `make` marked `called` | 3.4 s |
| and `+a` | 8.6 s |
| and `a == a` | 6.6 s |
| and `a.hash()` | 8.8 s |

Making and dropping the chain is linear; the runtime's reflective
`rig.eql` (`eqlAs`), `rig.hash` (`hashAs`), and `rig.cloneValue` grow
faster. Each recurses into an object's fields with an `inline for`, and
LLVM inlines each level's call into the one above, so the body of
level `k` holds every level below it: the bodies sum to the square of
the chain before LLVM's passes run over them. A debug build (no
inlining) of 1000 links takes 2 s.

## The fix and its measure

`==`, hashing, and cloning reach a field through a call of its own
(`@call(.never_inline, ...)`) when the field nests objects more than
eight deep (`outOfLine`, `nestingDepth`); anything shallower is reached
inline, as before.

| links | main | the fix |
|---|---|---|
| 100 | 5.8 s | 3.8 s |
| 200 | 21.1 s | 3.9 s |
| 400 | 210.7 s | 4.9 s |
| 1000 | past 20 min (the backlog) | 11.2 s |

Every call out of line at any size, the first try, built the same
chain as fast, but a hot loop comparing and hashing an object holding
a 160-byte object went from 0.01 s to 0.28 s (20 million passes,
`--release=fast`): inlined, LLVM hoists the whole compare. A threshold
by size (128 bytes) kept that loop out of line too. By depth it is
inlined as before, 0.01 s, so no program whose objects nest eight or
fewer deep is compiled differently.

The case `objects nested by value deeper than inlining compare, hash,
and clone` (test/rig/ownership-clone.rig.test, `release: true`) runs
twelve levels through the out-of-line path.
