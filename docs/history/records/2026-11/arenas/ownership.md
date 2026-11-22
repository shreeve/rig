# Arenas in Rig: the ownership and soundness view

Panel member: ownership and soundness. Read only; probes in
`~/Data/Code/Claude/rig/rig/arenas-panel/probes-ownership/` (run with
`bin/rig run`, the risky ones also with `RIG_SANITIZE=1`).

## Recommendation in one paragraph

A region should be an explicit std value, `r = *Region()`, built exactly
as `std.shared.Map` is built today: a cell behind `*` whose marked call
`!r.put(x)` moves `x` into memory that never moves and hands back a read
view `?T from @`. Everything about escape then falls out of sentences 5
to 7 with no new kind of value, no lifetime, and no allocator named. Only
values that copy (`T: Copy`: plain data and read views, so nothing with a
`drop`, no owner, no handle) go in, so dropping the region frees it in one
step with no drop glue. Region inference and any "allocate everything in
this block from r" scoping should be refused: the first breaks CORE §10
("rules follow the value's type, never where the value came from") and
the second is unsound with Rig's runtime as it is.

## Verified facts

- Free finds a block's heap by address, not by a stored allocator:
  `free` reads `segmentOf(memory.ptr).heap` (src/alloc.zig:2657-2670,
  2687-2692). So a region's memory could be its own segments without any
  box, List, or closure storing an allocator (INTERNALS.md:5797, the
  `defaultAllocator` row, ends "No box, List, or closure stores an
  allocator. Allocation failure panics.").
- `std.shared.Map` is already a region in all but name: entries "never
  changed, moved, or freed until the map drops", lookups are views tied to
  the handle, `ensure(!@, k, v) -> ?V from @, k, v` (std/shared.rig:1-60),
  and the Zig behind it is trusted only through `Checker.marked_externs`
  (src/typecheck.zig:591-625). CORE §4 (CORE.md:1253-1258) states the
  obligation: a cell's views last while it lives, "which each such type
  ... meets by its declaration".
- A write view of a cell leaves its place read-only, not unusable, so
  many results of marked calls coexist (CORE.md:847-854, 1249-1279).
- Sentence 6: a drop uses the views a value holds only when a `drop` body
  could read them (CORE.md:430-435). Sentence 7: results view only what
  was passed as views; `from`, `keeps` (CORE.md:482-523).
- §10 (CORE.md:2313-2321): one paragraph, no exception list, rules follow
  the type, a desugaring into forms CORE covers.

## Probes (shared.Map standing in for a Region)

| File | What | Result |
|---|---|---|
| p1.rig | three `ensure` results alive; one through `fun put(m: !shared.Map[..]) -> ?Int from m` | accepted, `10 20 30` |
| p5.rig | return a view of a local map | rejected: "cannot return a view of `m`, which belongs to this function" |
| p3.rig / q2.rig | keep a region view in an outer `List[?String]`, then drop the map | rejected: "cannot drop `m` while a write view of it is still in use" |
| q3.rig | a task reads a region view (`size(?a)&`) while main puts more | accepted, sanitizer clean, `2 abc` |
| p8.rig | reassign the map while a `?String` result lives | rejected |
| p2.rig, p7.rig | reassign or drop the map while a `?Int` result lives | accepted and clean: a `?Int` is represented as a copy (CORE §9 "how a read view is represented"), so it limits nothing; correct, but the note matters for a region of small plain values |
| q1.rig | `obj Node` with `left: (?Node)?` fields, linked by read views | accepted, `3` |

Two wording nits seen: q2's message calls the `ensure` result a "write
view" although sentence 7 makes it a read view; p3/p4 ask for `?a` where
`a` is already a view.

Not probeable without compiler work: a region keeping a view of itself
(below, "the self-view").

## 1. Escape

With `put(!@, v: T) -> ?T from @ keeps v`, region values are views of the
place `r`. What the checker does, by existing rules:

- **Returning one:** only `from r` where `r` is a parameter (sentence 7);
  a local region's view is rejected (p5). A function that builds a tree
  takes the region: `fun make(r: !Region, d: Int) -> ?Node from r`.
- **Storing into an outer owner:** allowed when the owner's type can hold
  a view (`List[?Node]`), and the region stays read-only while the owner
  is used; an owner that outlives the region's scope is rejected at the
  region's drop (q2). A `List[^Node]` cannot take a `?Node` at all: a type
  error, not an ownership rule.
- **Sending to a task:** a read view goes to a task when its value syncs,
  and the task keeps the region read-only until `>t` (SPEC §18; q3). The
  `*Region` handle counts non-atomically, so it goes to no task, and a
  write view of a cell goes to another task only for a word-Cell object
  (CORE.md:855-862): no task puts into another's region.
- **Behind `*T`:** `*T` "limits whatever the value it holds limits"
  (CORE.md:871-872), so `*<n` of a view-holding value is accepted and
  limited. `*Frozen`, `Cell`, `Signal` and owned closures hold no view
  (CORE.md:865-871, 2132-2135), so region data never enters them.
- **Copying out:** `+v` of a `?Node` copies the Node, whose fields still
  view the region: it does not escape. Text escapes as today, `+t` of a
  `?String` is a new `String` (sentence 2). A deep copy into an owned
  twin type (`^OwnedNode`) is written by hand. This is honest and needs no
  rule, but it is the cost a reader will notice.

**Does it fit the loan machinery?** Yes, with one addition: the
self-view. `!r.put(Node(left: l, right: rt))` stores `l` and `rt`, views
of `r`, inside `r`; with `keeps v` the region now keeps views of itself.
By sentence 7 a kept view keeps its place limited while the holder is
used, and here the holder is the place. Read-only is harmless for a cell
(more puts are marked calls, allowed), and sentence 6 already says the
views end at the holder's last use when no drop body reads them. So the
rule needed is narrow: *a view a region keeps of itself limits the region
only as read-only, and ends at its last use.* The checker has no such
case today (CORE's only self-reference is `from @path`), and this is the
part to build and test first.

`keeps v` is not optional. A `Copy` value may hold views of places
outside the region, e.g. `Tok(text: ?src[..3])`; without `keeps v`,
`!src.add(";")` after the put would leave a dangling view inside the
region. Since `put` is an extern, the checker trusts its signature
(marked_externs), so the signature is the soundness argument and must be
reviewed as one.

**No new kind of value.** A region-made value is a view (`?T`); a region
is a cell behind a handle. Both are kinds CORE has.

## 2. What lives inside a region

The bulk free is sound only if nothing in the region needs cleanup. CORE
§9 already keeps that fact per type ("needs cleanup"), and the bound that
expresses it is `Copy`: a type copies when its parts are plain or read
views, and "a `unique` type or one with a `drop` body has none" `+`
(sentence 2). So:

| In a region | Rule | Why |
|---|---|---|
| plain data, objects of plain parts and read views | allowed | need no cleanup |
| `List`, `String`, `^T` inside a put value | refused by `T: Copy` | their buffers are heap blocks the bulk free would leak |
| text or an array's elements | `!r.text(?s) -> ?String from @`, `!r.slice(?xs[..]) -> []T from @` copy them into the region | a frozen buffer, not a growable one |
| `*T`, `~T` | refused | a count must be released |
| `error` | refused | owning (CORE.md:170-172) |
| closures | refused | `?fun` is never stored; `*fun` is a handle |
| a type with a `drop` body | refused | not `Copy`; and running drops would make the region a walk again |

"Dropping the region frees them all" then means: no drop glue at all, one
release of the region's segments. A growable `List` inside a region is
left out on purpose: its buffer would have to come from the region and
each growth would strand the old one. Build in a heap `List`, then freeze
it with `!r.slice`.

A later widening, any `T` with its drop glue run when the region drops
(typed-arena semantics; `shared.Map` already frees "every key and value
it holds"), is sound but gives up the one-step free. I would not start
there.

**Mutation is the real limit.** Region values are read views, and a write
view is never stored (CORE §5, "Write views are not stored"), so a region
holds an immutable graph: values are finished before `put`, children
before parents. That fits binarytrees, a parse tree built bottom up, and
interned text; it does not fit data that dies together but changes
(a per-file cache). For that, `List[T]`/`Table[T, n]` pools with index
links (src/table.zig) remain the tool, and they already drop in one step
for plain `T`.

## 3. Inference

Could the compiler put allocations in a region with no syntax?

- **What would be sound:** a value made in a function, never moved out,
  whose drop point is that function's end. That is stack allocation of a
  box, and it does not help binarytrees, where trees are built in callees
  and returned.
- **Where it stops:** a tree returned from `make` needs the caller's
  region, so `make` needs a hidden region parameter (ML Kit's region
  polymorphism): a hidden argument and a second instance of every
  function that makes values, invisible in the source. In a loop, a
  region that outlives one iteration turns frees that today reuse memory
  into bump allocation that only grows: an O(1)-memory loop becomes O(n)
  with no change in the text. The ML Kit hit both (it added storage-mode
  analysis and, later, a garbage collector beside regions).
- **Against CORE:** inference decides by where a value came from and
  where it goes, which §10 forbids, and it makes a value's representation
  depend on code elsewhere, which CORE avoids even for `error`
  (CORE.md:170-172).
- **A dynamic "allocate from r in this block" is unsound** at run time:
  an outer `List` whose first `push` happens in the block, or a callee
  that builds a `String` and stores it in an outer owner, would get region
  memory and dangle after the block. Address-dispatched `free` makes the
  free harmless but not the lifetime. It would also have to answer which
  heap a task spawned inside the block uses.

Readers would be surprised by a program whose memory profile changed
because a value started escaping somewhere else. Rig's rule is that
effects are visible; where memory comes from is not one of the listed
effects (DESIGN.md:55-57 leaves allocation implicit), but *how much*
stays live is part of "the cost model of Zig and C". I recommend no
inference, and stating that in the CORE paragraph.

## 4. Tasks

With an explicit region nothing about tasks changes:

- A task that reads region data (`f(?n)&`) keeps the region read-only
  until `>t`; puts may go on meanwhile, since bump memory is never moved
  or rewritten (q3 shows the checker's side; the runtime's side is the
  region's invariant). The region cannot be dropped or reassigned before
  `>t`.
- A task never puts into a region it was not made in: the handle and the
  write view go to no task.
- Allocation by tasks while a region is open is unaffected: release heaps
  stay per thread, and the region is not a scope over them.
- Parallel work with regions: each task makes its own `*Region()` and
  returns a summary, e.g. `par.map` over binarytrees' depths. A task
  cannot return views of a region local to it (p5's rule).
- Region data shared by many tasks as a frozen whole is not offered:
  `*Frozen` holds no view.

## 5. Draft CORE paragraph (planned)

Placed after sentence 9, as its own paragraph:

> **Regions.** *(planned)* A `Region` holds values that die together.
> It is a cell (sentence 9), so it lives behind `*`: `r = *Region()`.
> `!r.put(x)` moves `x` into the region and gives a read view of it
> there, `?T from r`; `x` must copy (§1), so nothing in a region needs a
> drop, and dropping the region frees all of it in one step. A region
> never moves or changes what it holds, so any number of its views may
> be in use at once, and more may be put while they are. A value put
> there may hold views, of the region's own values or of places outside
> it; the region keeps them (sentence 7), so places outside stay
> read-only while the region is used, and a view the region keeps of
> itself ends at the region's last use, since no drop body reads it.
> The rest is sentences 5 to 7: a region is dropped or reassigned only
> after its views' last use, a function returns them only `from` a
> region passed to it, an owner that keeps one keeps the region limited,
> and a task given one keeps it limited until `>t`. No call empties a
> region, and no allocation goes to one but by `put`: the compiler never
> chooses a region.

```text
use std.region

obj Node
  left: (?Node)?
  right: (?Node)?

fun make(r: !Region, d: Int) -> ?Node from r
  if d == 0
    return !r.put(Node(left: none, right: none))
  l = make(!r, d - 1)
  rt = make(!r, d - 1)
  !r.put(Node(left: l, right: rt))

fun check(n: ?Node) -> Int
  c = 1
  if n.left as l
    c += check(l)
  if n.right as rt
    c += check(rt)
  c

sub main()
  total = 0
  for d in 4..=20
    r = *Region()
    total += check(make(!r, d))
  print(total)
```

Each iteration's `r` drops at the iteration's end, freeing its tree in
one step. Rejections it implies, each by an existing message: returning
`make`'s result from a function that made `r` itself; `r = *Region()`
while a node from the old `r` is still used; keeping a node in a `List`
declared outside the loop.

## Soundness traps, each checked against "accept means correct"

1. **A `reset` call would be unsound.** Any marked call on a cell is
   accepted while its views live (CORE.md:1249-1263). A region is
   emptied only by `<r` or reassigning `r`, which sentence 5 already
   refuses while views live.
2. **`keeps v` on `put`.** Without it a stored view of an outside place
   dangles. The checker trusts extern signatures, so the signature is
   the proof obligation; list `put` in `marked_externs` with a sanitizer
   test that changes outside places while region views live, as
   std-shared's test does.
3. **The self-view.** If the checker treats a region keeping a view of
   itself as "limited while used" and its drop as a use, no linked
   structure can ever be dropped (useless); if it lets a self-view end
   early while the region moves to a place that outlives the views'
   source, a view dangles. The narrow rule above (read-only, ends at last
   use, region is not returned since its own values view it) is sound;
   it needs tests both ways.
4. **Copy-represented views.** A `?Int` result limits nothing (p2, p7),
   which is right only because the value was copied out. A region's
   `put` must give a pointer-represented view for every `T`, or say that
   small plain `T` comes back by value.
5. **The heap and the region stay apart.** The region's segments must be
   no thread heap's, so a stray `free` of region memory (there should be
   none, as nothing in it needs cleanup) can never put a region block on
   a heap's list. An assert in debug builds, and the sanitizer build
   giving each region block its own pages, keep this checked.
6. **Recursion through `!r`.** `make(!r, d - 1)` passes on a held write
   view of a cell while `l` views `r`: allowed because the write view of
   a cell leaves read-only (sentence 9). This is the same path as p1;
   test it with recursion explicitly.

## Decisions for the owner

1. **Explicit region value, no inference, no block scoping.** Default:
   yes, `*Region()` and `!r.put(x) -> ?T from r`, a std type in the
   pattern of `shared.Map`.
2. **What goes in.** Default: `T: Copy` only, plus `text` and `slice`
   copies; no drop glue, one-step free. Widening to drop-run values
   later, if a measured program needs it.
3. **The self-view rule in CORE.** Default: a CORE paragraph (above) as
   its own reviewed Core change (North Star 5), scoped to regions rather
   than a general rule about values keeping views of themselves.
4. **Order.** Default: first the IDEAS measure (Trig's share of
   immutable data that dies together), since a region serves only
   immutable graphs; binarytrees alone does not earn the feature under
   §10's last line.

## Biggest risk

The self-view: a region keeping views of its own values is a case the
checker has never seen, and it sits exactly on the edge between "every
linked structure is rejected" and "a dangling view is accepted". It is
also the part a second round of soundness fixes would land on, which §10
says stops a feature for redesign. Build it first, behind tests in both
directions, before any std surface.
