# Review of PR #109 (rename, 2fbed81c vs 369f1230)

Verdict: no soundness findings. Minor items only.

## 1. Accepting `^` forms
About 25 probes, run in debug and `--release` under RIG_SANITIZE=1. All gave correct output with no leaks or use of freed memory:
- `^Node(...)` recursive list and `^Expr` enum tree (`match ?e`, `if o as b`)
- `^x`, `^<x`, `+b` (deep copy, mutating the copy leaves the original unchanged)
- `<b`, then use of `b` is rejected
- `^?String`, `W[^Int]`, `List[^P]`, `List[List[^P]]`, `^P?`, `?^P` / `!^P` parameters
- `^String`, `<b.unbox()`, `@name(^Int)`
- a program's own `Box` or `Vec` struct works
- `^x` of an owner is rejected with a hint (`<x` or `+x`)
- `<b` while `?b` is live is rejected

## 2. Rejections and hints
Rejected, including through `type` aliases, generic struct fields, and generic signatures: `^^T`, `^*T`, `*^T`, `^~T`, `[]^*T`, `[2]^^T`, `^B` where `B = *Int`, and `^x` where `x` is already `*Int`.
- `**T` is rejected as "not a Rig operator".
- `^fun` and `^none` are rejected, each with a clear message.
- `Box`, `Vec` and `Text` give useful 0.3.0 hints.
- `!?String` is rejected.

Minor:
- `~^T`, `~~T`, `*~T` and `~B` where `B = *Int` are accepted as written types. The PR table lists only `^~T` and `*^T`.
  - They are uninhabited: `~b` of a box is rejected, and so was `~Box` on main.
  - The class is incomplete but not unsound. Consider rejecting them in type resolution, or documenting why they are allowed.
- The comment at rig.grammar:880 still says `Vec[Int]`.

## 3. Migration tool
I ran it on a copy of main's examples/, std/, and test/behavior/{types,runtime}: 375 files, 158 rewritten.
- I compared 364 runnable programs, old compiler on the original against new compiler on the migrated copy. 355 gave identical stdout and exit code.
- The 9 differences are all intended:
  - 8 now fail to compile because the program stacked holdings (`Box[*T]`, `Box[Box]`, `Box[~T]`) or used an alias constructor `IB(6)`. These match the PR table.
  - 1 is `static_reads_as_string`, where `@name` now prints `?String`.
- Std `.rig` files migrate to identical code. Only the comments in `text.rig` differ.
- A second run changes nothing, and all files report "already migrated".
- `MANUAL` lines are reported for `Box[P](...)` and `!String`, both on first run and on rerun. The corpus itself produced none.
- `Box(<b)` of a box becomes `^<b`, which the compiler then rejects. This is correct but the tool does not warn.

## 4. Grammar
- rig.grammar has no `@conflicts` block, and INTERNALS says "no conflicts". They agree.
- I regenerated with nexus 2.2.0 and got no conflict error.
- The generated file differs from src/parser.zig only in a doc-comment and an assert (nexus version difference). I did not check whether that is pre-existing.
