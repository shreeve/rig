# Walk an iterator with `for`

Branch `for-iter`, head see git log, on main a2398d67. No PR opened.

## What it does

`for x in it`, where the type of `it` declares `next(!self) -> T?`, is
the loop `while (!it).next() as x`. The loop variable is what `as`
binds over `T?`; `else`, `break` values, labels and loop values are a
`while`'s. No pass has a form of its own for it: typecheck finds the
loop, the tree is rewritten into the `while`, and the module is checked
again, so the ownership checker walks and emit writes an ordinary
`while … as`.

## The decider (one place)

`Checker.iteratorShape` (src/typecheck.zig): the source's type past
views is a user or std struct/enum (not Vec, array, slice, String, range,
Text, a handle) that declares `next`; the shape must be receiver `!self`,
no other parameter, an optional result. A `next` of another shape is
reported at the loop with why (takes `?self`, takes more than `self`,
does not give an optional, takes no `self`). `std.random`'s
`next(!self) -> U64` is therefore rejected as a `for` source, with that
reason.

## Source sigils (defined by the desugaring)

| Source | Loop |
|---|---|
| `it`, `!it` (name or field path) | `while (!it).next() as x` |
| `mk()` (made) | `{ h = mk(); while (!h).next() as x }` |
| `<it` (name or field path) | `{ h = <it; while (!h).next() as x }` |
| `?it`, `xs[i]`, branching, part of a made value, `!mk()` | rejected |

`it` must be writable because `(!it).next()` is a write lend: a `?T`
parameter, a by-value parameter and a `const` are rejected by the
existing lend rules, at the source. A place is a name or fields from one,
because the desugaring evaluates it for every `next`; an element whose
index the body may change is bound first. `h` lives in a block around the
`while`, so a held iterator is dropped after the `else` and by `break`,
`return` and failure. Index bindings (`for x, i in it`) are rejected.

Decisions for the owner:
1. Made sources and `<it` need a hidden binding (IDEAS 0.3 wrote
   `it2 = it`). `for p in text.split(s, ",")` is the point of the
   feature, so they are in.
2. A bare place is advanced in place (the task's desugaring), so a
   `break` leaves the rest to resume. That is a visible mutation behind
   the `for` keyword, not a copy.

## Mechanism

- `sema.zig`: `SemContext.iter_loops` (node id, how the source is walked).
- `typecheck.zig`: `iterLoop` records the loop and gives the variable no
  type; the old "calls no method" hint is gone.
- `rig.zig`: `Parser.desugarIterLoops` rewrites each recorded `for`; the
  `while` keeps the `for`'s node id and span.
- `modules.zig`: a module with recorded loops is rewritten and checked
  again; the first check is discarded.

Review 1 found that appending the names to the source put hidden leaves
past the end of the file; ownership orders by leaf positions (`extent`),
so the block's extent swallowed the code after it and a view kept past
`break` was missed. Now the nodes are IR nodes spanning the loop's source;
`next` and the hidden binding are leaves at positions inside the `for`
keyword, named through `rig.leafText` (`for iterator`, unwritable, declared
with `new`, quoted in Zig). Review probes are in test/corpus
(`review-for-iter-1-*`); `reject/ownership/for_iterator_kept_view` and
`behavior/ownership/for_iterator_hidden_name` are new. The pending owner
decision is the const `bare_place_advances` in typecheck.zig.

## Tests

Behavior (all `# release`): syntax/for_iterator, std/for_over_iterators,
ownership/for_iterator_views (an iterator yielding `(?Item)?` views,
owned drops), ownership/for_iterator_exits (drops on end, `break`,
`return`, failure, closure, generic, nested),
modules/for_iterator_across_modules.
Reject: syntax/for_iterator_signature, syntax/for_iterator_source,
ownership/for_iterator_not_writable, ownership/for_iterator_view_loan.
`test/matrix.py` family `iter.<source>.<context>` (60 cells, debug and
`--release`, exact traces). Two old reject tests changed wording
(`for_over_int`) or lost their iterator line (`text_push_bytes`, renamed).
SPEC (for), SYNTAX, STD, INTERNALS ("Loops over an iterator"), ROADMAP
and IDEAS updated; the STD example and `std/text.rig` use `for`.

## Gates

- `./test/run`: 3154 passed, 0 failed, 3 pending (the pending are
  existing doc examples). Parser check passes with the local Nexus.
- corpus: 9725 passed. `zig build test`: green. matrix: 6478 programs,
  0 failed (60 are the new family).
- equiv against a2398d67 (12279 programs): 24 differ, all in
  `check --facts` output, none in `emit` or `pkg`. They are: the 5 new
  behavior tests and 4 new reject tests, which the old compiler rejects;
  `for_over_int` (changed message); 11 corpus programs rejected before
  and now, whose message lists "an iterator" as a source (e.g.
  `*Cell[Vec[Int]]`, `Bag`); the SPEC and STD doc blocks rewritten to
  `for`. No program both versions accept emits different Zig. The STD
  example, written both ways, emits byte-identical Zig; a made source
  differs from its `while` only by the `var __rig_iterN` block.
- Not run: the deep gate (linux, `--release` grids), and the independent
  review that the fast gate calls for. pup-gates.sh was not on this
  machine; cpuq was used directly (no waiters).
