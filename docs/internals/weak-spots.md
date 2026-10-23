# Weak spots

Where the compiler's soundness work is not finished: areas reviewers keep
finding problems in, items held for a prerequisite, and questions for the
design owner. Change these areas carefully, and run the suite after. The
restructuring that removed most earlier bugs is in
[the consolidation](../history/consolidation.md). The ownership rules are
in [CORE](../CORE.md), and [HANDOFF](../../HANDOFF.md) says where the work
stands.

## Areas that need care

Reviewers keep finding problems in these areas. Change them carefully,
and run the suite after.

- **Statement temporaries** (Core §3). A header whose subject makes a
  temporary and reaches a place outside it binds the place's own: emit
  points at it (`storage.headerPoints`, the storage fact `header_value`
  held by pointer). One that reaches no place copies a value made in the
  header (`copiesHeader`, the storage fact `header_copy`) and is
  rejected, unless it takes its subject or binds plain data of a value
  made there. Tests: the cases `header points through temporary`,
  `header temporary points`, `header branch points`, and
  `header temporary rejected` of `test/rig/ownership-header.rig.test`.
  - *Resolved:* a place inside a view of a value the header
    makes (`id(?mk()).e`, `(?mk()).e`, `idh(?mkh()).xs`) lives in the
    header's own temporary, so the header copies it and stays rejected;
    pointing there would read the temporary after the header drops it.
    Tests: the `sema` unit test "storage: a header points at a place its
    temporaries reach, never into one" and the case
    `header place inside temporary` of `test/rig/ownership-header.rig.test`.
- **Payload views.** A read match's binding that is no plain data views
  the subject where emit matches it (`storage.matchesInPlace`: a place,
  a held part, a view a call returns, a value branching over views,
  through temporaries or a guard), so a view of it carries the subject's
  loan past the arm. Where a read match matches a copy, such a binding
  is usable within its arm only (`SymbolFlags.arm_view`); every such
  subject with a header temporary is also rejected (`rejectHeaderCopy`).
  Tests: the cases `match payload view outlives arm` and
  `match payload view escapes` of `test/rig/ownership-match.rig.test`.
  - *Resolved:* a generic read view a field or an element holds
    on the subject's path (`match w.r`, `match arr[1]`) is reached in
    place, `rig.viewedPtr(T, &w.r).*`, never through a `rig.viewed`
    copy whose payload a pointer would outlive. Tests:
    `test/cli/emit_shapes.sh` (no `&rig.viewed(` and no switch on a
    `rig.viewed(` copy), the cases `generic view field subject` and
    `generic view field guard` of `test/rig/emit-generic.rig.test`, and the
    escape, `generic view field escape` of `test/rig/ownership-generic.rig.test`.
- **Addresses of Zig rvalues.** `emitLeafPtr`'s `&@as(T, value)` and a
  temporary array lent to a call are the storage fact `zig_temp`. Emit
  still takes the address of two kinds of Zig rvalue no fact names: a
  `?@` method on a made value no slot keeps, or on a branching value
  with a made leaf, and labeled value blocks' yields (docs/internals/INTERNALS.md,
  Emit, "Addresses of Zig temporaries"). They are latent: the checker
  keeps each view within its statement, and Zig keeps the rvalue's slot
  today. Next: make the chokepoint structural, so every `&` and `|*x|`
  targets a place, a slot, or fact-named storage whose `life` the
  chokepoint checks.
- **What a view could hold:** `carry` and `sema.viewReach`, and `?String`
  values in Cells, generics, and closures.
- **What a `^T` does not yet forward:** a box reaches its value's fields
  and methods, and lends its views, but `xs[i]`, `?xs[a..b]`, `for x in
  xs`, `==`, and arithmetic on a boxed array, List, or number name the
  box and are rejected; a box has an `unbox` of its own that hides a
  value's method of that name. A generic body cannot reach through a
  `^T` of a handle either (it cannot call a method of `T`), so the box
  and handle stacking rule is checked at generic instances only in
  fields and signatures.
- **Evaluation order versus what is emitted:** call arguments, and
  `print` and `String(...)` arguments. Assignments share one recorded
  order (`storage.SetOrder`).
- **`defer`/`errdefer` at exits,** owners behind `Cell`, `^T`, and
  `*T`, and generic instances.
- **Statement-long loans the Core does not need** (compiler-stricter,
  listed in `test/oracle/differences`): a call's result's read loans,
  and a write lend the call stores or whose result is a write view, last
  until the statement ends, not until their last use in it. So
  `match find(!v)` cannot write `v` in an arm after the payload's last
  use, `print(firstw(!v).n, v.len)` is rejected, and so is reading `v`
  after `keep(!v, !h, ?x)` in its statement though `h` is used no more.
  The Core allows all three, and the oracle accepts them. A later round
  ends these loans at their last use within the statement. Likewise a
  generic callee's argument write lend lasts to the statement's end,
  since its origins come from its signature, where a `T` could hold
  anything (`print(gfirst(!v).n, v.len)` is rejected); per-instance
  origins are a later refinement.
- **Review findings not fixed:**
  - Over-rejections of the reviews (the cases
    `review-b4b-2-p22`, `p24`, `p25`, and `p43` of
    test/rig/probes-18.rig.test): a payload
    view pushed into a List inside a `for` stays rooted on the loop
    binding; a view returned from a `match` nested on an outer payload
    binding (`match r.i` in `.a(r)`) is rooted on that binding; and a
    write-view local a payload view came through cannot be re-pointed
    while the view lives.
  - An operator, generic inference, and a binding with no type read a
    read view of a scalar as the value (`readsAsValue`), but keep a read
    view of a plain object, array, or optional as the view: copying
    those out there would change the type of accepted programs
    (`x = r` with `r: ?Point` binds a `?Point`). Where a type is
    expected, every value that copies is copied out (`sema.copies`).
  - The oracle accepts two shapes the Core rejects (the compiler
    rejects both): a `?@` result reaching an owned field beside a
    held view (`x77`), and re-pointing a write view a closure has lent
    (`x68`). Add them as `# oracle:` tests when the oracle learns them.
  - Whether an expression is a view is not one fact yet (CORE §9,
    *planned*): a loop over a call's returned view of a List of owners is
    rejected as if the List were made there.
  - `bin/rig-oracle` in a worktree goes stale; `test/rig.rip` rebuilds it,
    so rebuild before using it by hand.

## Held, each waiting on the change named

- **Whole-program parameter summaries** (CORE §9, *planned*): a generic
  `Holder[?String]` built from literals is still rejected.
- **Field-precise re-pointing:** its own round (decision 1d): what a
  var holds is still per var, so re-pointing `p.v` keeps the old view's
  loans while `p` lives.
- **Std search taking `x: ?T`:** it would reject
  `slices.contains(?v[..], ?t[4..5])`; decide whether implicit lends
  extend to branching values.
- **`into` for stores, function-type `from`, and path tokens:** Core
  changes, each its own reviewed change.

## Also open

- A header that copies a value made in it: what the header temporaries
  rule leaves.
- The structural address chokepoint (see "Addresses of Zig rvalues").
- The per-expression "is a view" fact.
- The held items, as their prerequisites land.

## Open questions

These belong to the design owner.

- **The kind of an object of `?String` values:** CORE calls it a view, SPEC plain
  data; the compiler treats it as CORE's read-view kind.
- **A branching self:** a pointer per leaf (built) or a rejection?
- **Clone limits:** are the missing clones of a type from another
  module, or one holding a `Signal`, rules or gaps?

Settled and built: field-disjoint loans (CORE sentence 5 and §5, "A field
is a place of its own"). The other three rules the Core left open are
decided and built (CORE sentences 1, 6, and 7): a call's result that
holds no write view keeps a write argument lent to read, and that
argument's write lend ends as the call returns; dropping a container of
views uses them only through a `drop` body; a bare name or place only
reads, so `x = h.w`, like `x = w`, of a `!Int` copies the Int.
Field-precise re-pointing waits for its own round.
