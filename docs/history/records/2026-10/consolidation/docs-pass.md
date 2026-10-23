# Track 3: the docs pass (2026-10-23)

The consolidation round's track 3 ("docs say what is true"), on branch
`consol-docs` from c77a86b07. Docs and one test case only; no change to
`src/`.

## What each doc covers

- **README:** a declared set with fields (`-> Int!Parse`,
  `bad(at: Int)`, a complete `match`, an error printed with its
  fields), unions and generic sets in a sentence; `*Frozen` and Ctrl-C
  under Tasks; closure field paths and `Table`/`Slot` under "The rest
  of the language"; `Table`, `Slot`, and `Frozen` among the built-in
  names; std.json's `load` and `JsonError`. "Not built yet" no longer
  lists errors with data; it lists std's I/O sets instead.
- **WELCOME:** rows for `T!E`, an error with data, matching it, a set as
  a parameter, `*Frozen` (Rust's `Arc`), `Table`/`Slot`, and a capture
  of one field; "What a program becomes" gives `T!E` as `E!T` with the
  hidden `rig.ErrSlot`, `Table`, `Slot`, `*Frozen`, and `main`'s status
  130 on Ctrl-C.
- **QUICK:** declared sets and fields under "Optionals and failure";
  new paragraphs on closures (captures, field paths, `?fun`, `*fun`),
  tables, and tasks (function values, `*Frozen`, Ctrl-C).
- **SPEC §19:** four rows of forms rejected as not supported yet: a
  compile-time call over an enclosing generic's parameter (`[cap[n]]T`),
  arithmetic on a compile-time parameter in a type (`[n * 2]T`), a
  compile-time function over text, a float, or an optional, and an owned
  closure called as a temporary (`(+h.f)(x)`). The last had no `fail`
  case, so `test/rig/types-closure.rig.test` gains one.
- **Learn Rig 03 (errors):** "Naming the set" (declared sets, the
  rejected `!` of an any-error call, unions, `c: Config =>`), "Errors
  that say more" (fields, printing, member tests, a failure moves its
  error), and "A set as a parameter" (generic sets).
- **Learn Rig 04 (concurrency):** "Stopping the whole program" (Ctrl-C
  and SIGTERM, with a transcript of a real run that exited 130) and
  "Functions go anywhere" (function values cross; closures do not).
  `*Frozen` was already taught there ("A value many tasks read").
- **STD:** a "Frozen" section with a frozen Map read by two tasks.
  `Table and Slot` and std.json's `JsonError`/`load` were already there.
- **ROADMAP:** removed what runs: arrays of owning values, matching on
  `?String`, `o?.len` and `print(mk().t)`, generic sets, the built SIMD
  forms, `std.json` moving in, and `--facts=sema`. The errors item is
  now "std's I/O sets", which waits for the owner's names.
- **INTERNALS:** the pipeline names resolve, typecheck, and cteval under
  sema, the files written beside the runtime, and `rig build`'s frames
  and BOLT steps; the source map gains `src/table.zig`, `src/alloc.zig`,
  `src/frames.zig`, and `src/bolt.zig`; `Pending`'s three entries are
  named; the facts table gains `isMemberTest`, `isFrozenMake`, and
  `isLocalTask`; a new section, "What crosses to a task", covers
  `Crossing`, `blockerIn`, `atomicHandle`, function values,
  `localBlocker`, `crossCheck`, `actorCall`, `crossingTypeOf`, and
  `*Frozen`; emit's error notes cover set parameters and the slot of a
  callable view; the runtime table covers `Frozen(T)` and interrupts.
  Every identifier named was checked against `src/`.

## The pending blocks

SPEC's 4 and CORE's 3 `rig pending` blocks all still fail, each for the
planned rule it shows:

| Block | Planned rule | Today |
|---|---|---|
| SPEC.md:1678 | two write views among a function's results | rejected: "at most one of a function's results is a write view" (§19) |
| SPEC.md:6964 | `-> ?String from @text`, a view of part of self | rejected: "cannot assign to `@pos` while `@` is lent" |
| SPEC.md:7915 | a generic body's `*<x` at an instance whose `T` is held is rejected | accepted, and runs clean under `RIG_SANITIZE=1` (prints 1); the block's expected error does not come |
| SPEC.md:10740 | a compile-time call over a generic's own parameter | rejected (now in §19) |
| CORE.md:947 | `?(a if c else b)`, lending a branching place | rejected with the hint to lend each branch |
| CORE.md:1034 | `for` over a made List of owners | rejected: "bind `names()` to a name first" |
| CORE.md:1599 | `(+h.on)(1)`, a temporary callee | rejected (now in §19, with its `fail` case) |

Each describes a planned rule, and each now has a ROADMAP line with its
reason; SPEC.md:7915's program runs clean under `RIG_SANITIZE=1` with no
leak. CORE is unchanged, as CORE changes need the owner.

## Found, not fixed

- `src/emit.zig:8797`: `failsWithFields`'s doc comment says "in a
  program that declares one", which no longer matches one representation
  for `error` (every `T!` function takes the slot).
- Actor calls ask `crossingBlocker` directly (`Checker.actorCall`)
  rather than through `crossCheck`. It is the same fact; a candidate for
  track 1.
- `std/text.rig:297`: `parse_int` is `-> Int!`, so a function that
  declares a set cannot pass its failure on with `!`; journey 03 catches
  it instead. ROADMAP's "std's I/O sets" item (R3-3) names it and
  std's other fallible functions.
- ROADMAP's "A frame-size guard for every function" may be built in
  part (the task guard is sized, and `rig build` warns of large frames);
  it was left as it was.
- Journeys 03 and 04 are now about 3,550 and 3,700 words, code
  included, over journeys.md's 3,000 (02, 05, 06, 07, and 09 were over
  already); journeys.md records that they are trimmed when APIs Stage 3
  rewrites journey 07.
- A program started in the background from a non-interactive shell
  ignores SIGINT (as `nohup` does), so an interrupt test sends it from
  a terminal or uses SIGTERM.

## Suite

`swarm test/rig.rip doc`: 808 jobs, none failed. `swarm test/rig.rip
all`: 9,798 jobs; the first run failed one, `oracle.docs`, which needed
journey 03's new rejection (`doc/learn-03-errors/a1bf4f2ba34f main`)
listed in `test/oracle/rejections`. Listed, the full run is green:
9,765 jobs, none failed, in 69 seconds on the Mac.
