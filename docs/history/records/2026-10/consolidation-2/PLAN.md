# Consolidation round 2: plan (2026-10-24)

The brief for the round after APIs Stages 3 to 5, under Rig (OG)'s
supervision. Start here, then read HANDOFF.md, AGENTS.md, and the first
round's [PLAN.md](../consolidation/PLAN.md) and
[round-report.md](../consolidation/round-report.md), whose shape this
one follows.

## Why, and when it starts

In two days Rig gained a program's own APIs (Stage 3), `from @field`,
API objects (Stage 4), and shared and crossing objects (Stage 5). Each
phase had an adversarial review, and each review parked what was not
its phase's. The owner: "Just land everything first and make it's all
running." So the round starts when Stage 5 phase 2 (#622) has landed,
main has a green full run, and Trig's full suites are green on it.

## Rules for the round

- **No new language features.** Fixes, docs, proofs, measurement, and
  release prep only.
- **Each change is a small PR:** a failing case first; Rig's full
  suite; Trig's light gate (`tools/light`) for compiler, runtime, and
  std changes. PRs that touch apart may share one gate.
- **At most three agents at a time.** A top model for tracks 1 to 3 and
  5; Sonnet only for mechanical work.
- **pup:** every release build through `/zfs/trig-pup/trial/slot.sh`,
  with at least 12 GB free; never cores 3 and 4.
- **Records:** every review and measurement goes in
  `docs/history/records/2026-10/consolidation-2/`, with an INDEX.md line.

## Track 1: one classifier per fact, for Stages 3 to 5

Sweep the new machinery for a fact decided in more than one place:

1. **What crosses to a task:** the crossing walk (`blockerIn`,
   `Checker.crossingTypeOf`), `Requirement.task` and `no_task`,
   `holdsTask`, `atomicHandle`, `frozenObject`. Stage 5 review 1
   parked an owned closure over a task-holding `T` that is refused by
   the loan rule, not by `holdsTask`.
2. **What an object meets:** `objectBounds`, `lacks`, `objectMeets`,
   `objectUnowned`, `Requirement.meets`, `reachOf` (`Owned`),
   `deepCloneable` (`Clone`).
3. **The erasure:** `LendStep.erase`, `eraseBox`, `eraseShared`,
   `handleThroughView`. A function's last expression is not erased into
   `(^{Shape})!` (Stage 5 review 2): a second path.
4. **Witnesses and dispatch:** `provides`, `witnessFor`, `witnessName`,
   `ownerWitnesses`, the dispatch fact, `calleeTakesSlot`; the shorthand
   `c.area()` that a box's own methods pass and an API's do not.
5. **`from @field` paths:** the checker's path, the oracle's carry, an
   alias of self (`whole = ?@`) with no path, an `add` method called
   directly taking its API's `from @`, a `^{Job + Owned}` result that
   must say `from @`.
6. **`iterItem`** against `rig.IterItem` in Zig and the `[I: Iter]`
   instance rule.
7. **Older, same class:** `sema.copiedByReadView` against the runtime's
   `ReadView` (the backlog's generic `?T` of an optional view, which
   fails in Zig); `arg_types` keyed by node (round 1's leftover).

**Done when** each fact has one function, every caller goes through it,
and each merge has a case two paths would have split on.

## Track 2: every parked defect

Each item gets a failing case, then a fix, a ROADMAP line with its
reason, or an owner question. Check each on main first. Sources: S3/S4/S5
pN are the stage reviews (S5 p2 is #622's), FF from-field/review.md, BL
docs/internals/backlog.md.

| # | Item | Source | Class |
|---|---|---|---|
| 1 | `for i in 0..f.len` of a `*Frozen[List[T]]` fails in Zig | S4 p2 | done (#613) |
| 2 | an object prints its hidden text quoted (`"x"`, not `x`) | S4 p3 | done (#628) |
| 3 | a generic `?T` of an optional view fails in Zig (track 1.7) | BL | fixed by 742d05cd7; its sibling, an error with fields, #630 |
| 4 | a release build of a nested-by-value chain grows past 20 minutes | BL | #650 ([nested-build.md](nested-build.md)) |
| 5 | a `(^{Shape})!` or `(*{Shape})!` result does not erase its tail | S5 p2 | done (#631) |
| 6 | `[T: Clone]` refuses `+x` of `x: ?T` | S3 p34 | #636 |
| 7 | `if ?o as v` of a `?T?` under an API bound asks `Copy` | S3 p2 | #638 |
| 8 | inference does not see through a handle (`f(?fz)`, `first(?bx)`) | S3 p2, BL | #640 |
| 9 | a `^{Job + Owned}` result must say `from @` | S5 p1 | #641 |
| 10 | an owned closure over a task-holding `T` refused by the wrong rule | S5 p1 | fix (track 1.1) |
| 11 | an `add` method called directly takes its API's `from @` | FF | ROADMAP: no change, by the owner (an `add` method follows its API's clauses) |
| 12 | object messages: `+s` of `?{Shape}`, `[T: {Shape}]`, `?{Shape}?` and `?{Shape}!E` with no fix, braces across lines | S4 p1, p2 | #648 |
| 13 | an empty `api Marker`; two defaults across modules at a call | S3 p1 | no, by the owner ("Empty api marker shouldn't be allowed. Serves no purpose"); cases in #643 |
| 14 | a set without fields lent where a union with fields goes | BL | #644 |
| 15 | a type only named in a generic method expanded as an instance | BL | #645 |
| 16 | `lib.List` as an expression and as a type disagree | BL | #646 |
| 17 | messages about instances reached through an API (#609) | BL | #647 |
| 18 | `whole = ?@; whole.text` reported as a view of `@` | FF | ROADMAP (#651) |
| 19 | `Hold[I: Iter]{inner: I}` refused (rule 4) | FF | ROADMAP (#651) |
| 20 | a `?String` of a `String` with `add String: Shape` is no `?{Shape}` | S4 p2 | ROADMAP (#651) |
| 21 | `area_of(s)&` of a `?{Shape}`, and `make()&` giving an object, refused as local tasks | S4 p2, p3 | ROADMAP (#651) |
| 22 | `fun me(?@) -> ?{Shape} from @` cannot leave (H12) | S4 p2 | ROADMAP (#651) |
| 23 | `swap(!h.g, v)` of a `^{Shape}` refused | S4 p3 | ROADMAP (#651) |
| 24 | `+s` of a `*{A}` result keeps its argument lent | S5 p2 | ROADMAP, open questions: CORE's rule (#651) |
| 25 | `hold(!@, c: ?Cursor)` keeps `c` lent | BL | ROADMAP (#651) |
| 26 | copies out of a view and holding a held `T` in generic bodies | BL | ROADMAP (#651) |
| 27 | compiler memory: 10,000 bindings, chained generics | BL | ROADMAP (#651) |
| 28 | an addition built on another module's API (Rust's rule) | S3 p1 | ROADMAP, open questions (#651) |
| 29 | a value of `S.Item` that may view its base: instance rule or body tracking (`iter.count` refused where safe) | S3 p34 | owner: per instance (#662) |
| 30 | the shorthand `c.area()` through a box | S3 p2, BL | owner |
| 31 | a discarded result passes silently | BL, round 1 | owner |
| 32 | a handle parameter lent by a capture | BL, round 1 | owner |
| 33 | a `NetError` member for "no local port free" | round 1 | owner |
| 34 | faulting memory in ahead (the third form) | BL | owner |
| 35 | the compiler treats a `fun` field directly in what a write view sees as able to hold any view (stricter than CORE §7); probe s7_fun_reach.rig, in #627's oracle-fun.md | #627 | #649 |
| 36 | `print` of a `Map` or `Set` writes its internal fields (`Map(len: 1, es: [...], hs: [...], ...)`); proposed: entries in insertion order, `{"a": 1, "b": 2}` for a Map and `{1, 2}` for a Set, `{}` when empty, quoted as a List quotes its elements | #628 | owner chose that form (Rust's); fixed (branch `map-print`) |
| 37 | a `pub` generic prints an unbounded `T` by passing it to a private generic that prints it (`pub sub show[T](x: ?T)` calling `helper(x)`); every instance without `Print` was still rejected at `helper`'s instance or printed as `print` does, but a generic printing a `[]T` or `List[T]` took `T = []U8` and printed bytes as text (`["Hi"]`) | lead | fixed (branch `print-forward`): the forwarding walk asks `Print` of a `T` checked by its bounds, and printing walks a `T` where `print` looks |
| 38 | the same forwarding bypass for `==`, ordering, hashing, arithmetic, and copying: `pub fun eq[T]` calling a private `same(a, b)` that does `a == b` is accepted; harmless today (rejected at the callee's instance, under its name), so low priority | #664 | fix, through the one `checkStatedForwards` walk |
| 39 | `tools/emit-diff BASE`: diff the emitted Zig of examples, benches, std and Trig against a base commit, so a change whose emit is identical skips the timing round | errors track (R2.5) | tool |
| 40 | the suite writes `examples/json_tour.rig.debug/` into the tree (a program whose sets carry fields is built alone, beside its source, since R4); give it a temp dir | errors track | hygiene, first |
| 41 | `tools/baseline SHA`: a cached `rig` build at a commit, so an emit diff never runs a stale `bin/rig` | errors track | tool |
| 42 | a unit test that every runtime call of a Rig function value goes through `argsWithSlot`, like the `@constCast` test; R2.5's review found `select` missing it, and main had the same bug for arms that fail with any error | errors track (R2.5 review) | bug class, first |
| 43 | a message calls the result "argument 0" when type arguments conflict with the expected result type | errors track | message |
| 44 | a bracketed generic call (`id[Int](n)!`) is named `` `expression` `` in messages | errors track | message |
| 45 | a generic mismatch names the inner types ("expected `Int!E`, got `Int`") while the non-generic message names the whole function types; make them one form | errors track | message |

Stage 4's associated types in braces (`^{Source[Item: Int]}`) wait for
a program that needs them: a ROADMAP line.

**Done when** no case is `known: true`, and every row is fixed, on the
ROADMAP with its reason, or answered by the owner.

## Track 3: the oracle

In this order (~/Data/Code/Claude/rig/rig/oracle-abstain.md):

1. **Classify Trig's 6 disagreements** (compiler accepts, oracle
   rejects): `core.or_else` and `core.coalesce` (C2), `CopyOnWriteMap.get`
   and `MultiMap.get` (C6), `Parser.parse_jsx_element_or_...` (C1, use
   after move), `TextWriter.write_line_raw` (C9). Each is an oracle
   imprecision or a compiler hole; a hole goes to track 2 as high.
2. **A plain `fun` value is plain data** (`kinds.zig`, CORE §7): Trig
   +4,294 functions decided (47.5% abstained to 3.9%), and 44 new
   disagreements, 33 of one shape (a path through a read-view field
   lends what the view views, not `@`). That shape needs a ruling.
3. **Read a method's `from @`** in sentence 7, then **Map and Set by
   their signatures** (suite +42, Trig +145).
4. The oracle stricter than the compiler: `swap[H: Holder, H.Item:
   Copy]` (S3 p34); a closure literal to a `?fun`, and
   `task.isolate(|| mk())!` of a `^{Shape}` or `*{Shape}` (S4 p3, S5 p2).
5. Its check of an API's conformance clauses (S3 p2, decision 12), and
   memory linear in a `match` arm's exits (BL).
6. **Tasks and actors last** (BL; suite up to +167).

**Done when** each disagreement is classified, steps 1 to 3 are on
main, and the floors in `test/oracle/coverage` are raised to the counts
(only ever raised; `tests` is 6 below today's).

## Track 4: docs say what is true

- README, WELCOME, and QUICK name APIs, API objects, `Sends` and
  `Syncs`, and `from @field`.
- Learn Rig: 07 (generics and APIs) for Stages 3 to 5, and 04
  (concurrency) for crossing objects, within journeys.md's limits:
  1,500 to 3,000 words, so 03 (3,553) and 04 (3,711) are trimmed and
  07 (3,386) is split or trimmed.
- SPEC and CORE status markers after #622 (`*{A}` and `~{A}` still
  *planned* in CORE §1, §4, and the paragraphs); STD: `iter.count`,
  `iter.sum`, and how a `<chan>` and an `<actor>` print; INTERNALS for
  the new passes; ROADMAP's APIs line pruned to what is left.

**Done when** the doc tests are green and a reader of README, WELCOME,
and QUICK meets every feature that is built.

## Track 5: speed

- **The census:** main against f55fe3d9a (round 1's close, before
  Stage 3) and against ace79d579, interleaved, on both machines:
  std.json safe and fast, Trig's ts-pattern and zod3, and bench tasks,
  actors, net, and http. Bisect anything slower beyond 2% before more
  lands. Canada's 2.4-4% after #538's candidate A is accepted.
- **Candidates, each measured:** the one-word table for a `?{A}` call
  (Stage 4 review 2: the 2.5% on pup is the entry's dependent load;
  about 40 lines); #538's candidate B (faster than the reference on
  every pup safe build, 3.4-7.7% slower on four Mac safe builds), tried
  again on main; owned closures as objects of one method (Stage 5
  phase 4), only if faster.

## Track 6: the Lean proofs (non-gating)

Stage 4's packing lemma (erasing a type keeps its loans; a box's drop
reads them) and Stage 5's crossing obligations over
`formal/LambdaRig/Tasks.lean`, or obligations in
`docs/design/formal-plan.md` where λRig lacks the model.

## Track 7: release prep for v0.3.0 (the owner tags it)

- **One migration guide** from every rename: `tools/migrate-0.3.py`,
  `migrate-builtin-map.py`, `rename-interner.py`, `rarely-body.py`,
  `state-bounds.py`; `Moves`/`Shares` to `Sends`/`Syncs` (rejected with
  the new names; no script); std.json's `JsonError` (no script in
  `tools/`; the guide gives the rewrite).
- **Release notes** listing every form v0.2.9 accepted that is now
  rejected, from CHANGELOG.
- Trig's note and scripts first.

## Owner-only

Naming; any CORE change (and the read-view-field ruling, if it is
one); newly rejected programs beyond CHANGELOG's; any slowdown beyond
2%; rows 29 to 34; the tag.

## Order

1. Track 3's triage (step 1) and track 2's highs (rows 1 to 3), with
   track 1's crossing sweep (1.1).
2. The rest of tracks 1 and 2; track 3's steps 2 and 3.
3. Tracks 4 and 5 beside them throughout; track 6 beside, gating
   nothing.
4. Track 7 last, then a round report beside round 1's.
