# Spans and false-edge proofs, built and measured (2026-10-25)

Two of [checks.md](checks.md)'s owner-approved steps (§7 decisions 1-3),
built, measured on real Trig, and closed by the owner because neither made
Trig faster. The branches stay on GitHub for reference: `span-type`
(PR #686) and `proof-edges` (PR #687).

## What each built

**`Span[n]`** (branch `span-type`, checks.md 9a, §4.1). A std type beside
`Table[T, n]` and `Slot[n]`: a start and a count with `start + count <= n`,
made only by `(!t).append(xs)`, `sp.sub(a, b)`, and `Span[n]()`. `?t[sp]`
and `!t[sp]` are slices of any table of `n`'s slots, taken with no
compare, typed, lent, and emitted as `?xs[a..b]` of a List is; the type
checker records each span index once and every later pass asks
`sema.isSliceIndex`. A span is plain data (copies, compares, hashes, keys
a Map, defaults to `Span()` in a reserved record). On a target that
commits a table as it is written, a read view of another table's span
past what this one wrote panics. Full suite green; SPEC, CORE, STD, and
oracle updated on the branch.

**Proven offsets with no assumption, and guard facts on the false edge**
(branch `proof-edges`, checks.md 9b and 9c). `provenOffset` converts a
tested or proven `Int` with `@bitCast` and `@truncate` instead of
`@intCast` under safety off, so no `llvm.assume` is left. In
`src/proofs.zig`, a failed comparison shows the one it negates
(`i >= s.len` as `i < s.len`, an `or` as each operand), an `else` starts
from it, and so does what follows an `if` with no `else` whose `then`
always leaves (`return 0 if i >= s.len`). Trig gains 111 proven tests
(2,367 to 2,478). Full suite green.

## Trig numbers

Trig main 676760a, one checker, outputs byte-identical on the six cli
projects. pup: core 6 with core 7 idle for time, fastest of 20,
interleaved; instructions on core 8, best of 5.

| change | ts-pattern | zod3 |
|---|---|---|
| `Span[n]`, Trig's eight `*_lists` and `TypeList`-like spans moved onto it (scratch copy) | 0.69% slower; 0.25% more instructions | 0.59% faster; 0.25% more instructions |
| 9b, proven offset by bit cast, against main | 0.01-0.13% faster | 0.23-0.73% slower |
| 9b and 9c against main, time | 0.16-0.18% faster | 0.53-0.54% slower |
| 9b and 9c against main, instructions | 11,124,129,345 to 11,125,535,954 (0.013% more) | 2,008,655,289 to 2,009,070,329 (0.021% more) |

Mac (arm64), at load 4-17: every difference within 1.5%, both
directions, except one 3.5% reading on a loaded run. Neither change
clears the speed bar (more than 2% faster, or 1% fewer instructions).

## Why they do not pay

The index tests they remove are predicted. A bounds test that never fails
is a compare and a branch the core predicts perfectly and runs beside the
load it guards, so taking it away saves almost no time; the stand-in
builds that removed every such test at once (checks.md §4.1, 1.3% and
3.8%) measured the ceiling of all of them together, not what a type or a
proof can reach.

- A span removes the overflow test on `start + k` and the reload of the
  list's length, but keeps `k < count`: Trig reads each element through
  `type_at(list, k)`, from loops that also call `!@` methods, so no loop
  holds the span's view, and LLVM cannot fold that test. What it removed
  was cheap; the packed first version cost 0.17-0.22% more instructions
  in field shifts, and even as plain fields it runs 0.25% more.
- The false edges prove 111 more tests, nearly all on cold paths, and the
  bit cast changes no instruction LLVM keeps. ROADMAP had measured these
  shapes at about 0.1%; Trig shows none of it.

So proving away predicted index tests is not where Trig's time is; the
time is in the work itself (checks.md §1's 7.4% ceiling is every check
at once, mostly lookups by stored ids, whose cost is the load).
