# Arenas in Rig: language design and prior art (2026-11-21)

The language-design expert's report. Lens: what the programmer writes, and what
other languages learned. Read only; probes in `probes-design/` (four small
`bin/rig run` files, results quoted below). No timing claims.

## The thesis in one line

**Make the arena a container, not an allocator.** Every language that made the
arena an *allocator* passed through APIs (Go, Rust's `allocator_api`, C++ pmr)
hit the same wall: it infects every signature, or it splits every type. Every
language that made it *implicit* (Odin, Jai, Go's regions) either gave up safety
or needed a runtime barrier Rig does not have. The one shape that fits Rig is the
one Rust's `typed_arena` and `bumpalo::Bump::alloc` already have: a value you own
that hands out references to what you put in it, tied to it. In Rig those
references are read views, and `from r` does what Rust's `'a` does, with no
lifetime written.

## Facts checked

- Rig's rule: "Sigils are the language's mechanics; words are its libraries"
  (README.md:54, docs/QUICK.md:7). The implicit effects listed in
  docs/DESIGN.md:55 include "the allocation a `List`, `^T`, or `String` makes";
  `^x` itself is a sigil, "one allocation" (DESIGN.md sigil table).
- "No box, List, or closure stores an allocator. Allocation failure panics."
  (docs/internals/INTERNALS.md:5797, the `defaultAllocator` row). Confirmed.
  Release builds use `src/alloc.zig`, a heap per thread; debug builds the leak
  checker; the suite the sanitizer. Confirmed.
- docs/IDEAS.md:73-75: "A region freed at once. Values made in a named region
  are views of it". Needs a CORE paragraph, a design round, and first a measure
  of Trig's share of data that dies together.
- compare/rig/benchmarksgame/binarytrees/notes.md: the fast port's pool "is not
  the tree: links are indexes the checker does not follow"; "An arena with
  `^`-like handles that drop together would let the fast port be the plain one."
- docs/design/formal-plan.md:316: "Allocators as owners: out of scope; arenas
  with IDs." Trig follows it: `core.Arena[T]` is a List with Int positions
  (trig/src/core/arena.rig:46-60), and the Ast is Lists of records linked by
  `U32` (trig/src/ast/ast.rig:193-219).
- **The closest precedent is already in std.** `shared.Map` (docs/STD.md:1242-1275,
  std/shared.rig) is grow-only, never moves a value, and hands out views that
  "last while a handle lives": `!m.ensure(k, v) -> ?V from @, k, v`. Its
  invariant is kept in trusted Zig and listed in the checker's `marked_externs`,
  run under the sanitizer while views live (std/shared.rig:28-35). It works
  because CORE sentence 9 (docs/CORE.md:847-875, 1249-1262) says a cell's write
  view "leaves its place read-only, not unusable, and many views of it may be in
  use at once", and "nothing it hands out can dangle".
- **What stops it today** (probes):
  - `p2.rig`: pushing to a `List[Tree]` while a `Tree` holds `?pool[0]` is
    rejected: "cannot change `pool` while a read view of it is still in use".
  - `p3.rig`: a builder cannot return a node viewing its children: "cannot
    return a view of `l`, which belongs to this function".
  - `p1.rig`: a tree of optional views of locals runs (prints 3), so view-linked
    trees are already legal types: `left: (?Tree)? = none`.
  - `p4.rig`: `$size(Tree)` with two optional views is 16; the fast port's
    `Node` of two `I32` is 8.
  - CORE §5 (docs/CORE.md:1683): "A value never holds a view of itself". A
    region whose values view the region is exactly that, so it needs the CORE
    paragraph IDEAS predicts.
- CORE §10 (docs/CORE.md:2313-2321): a feature fits one paragraph, its rules
  follow the value's type "never where the value came from", it desugars into
  forms CORE covers, and it answers "a line that failed in a real program, not
  parity with Rust or Zig".

## Prior art, and what each teaches Rig

| Language | What the programmer writes | What happened | Lesson for Rig |
|---|---|---|---|
| **Zig** `ArenaAllocator` | An `Allocator` passed to every function and container that allocates (`arena.allocator()`), `arena.deinit()` or `reset(.retain_capacity)` | Works well, and is why Zig is "known for arenas"; the price is that every allocating API names an allocator, which Zig accepts as its identity | Rig chose the opposite and must not undo it. Zig is the *implementation*: Rig's runtime can build a region on Zig's arena or a typed pool, behind the trusted boundary, as `shared.zig` is. |
| **Odin** `context.allocator`, `context.temp_allocator` | Nothing at most calls: an implicit `context` is passed to every procedure; `context.allocator = arena_allocator(&a)` changes it for callees; `free_all(context.temp_allocator)` | Very ergonomic; no safety: a value made under a temp allocator outlives `free_all` silently | The implicit form is what "allocation is never spoken of" invites, and it is what Rig must not ship: an effect neither seen nor checked. It is also Trig's open NEEDS 6 (implicit context parameters), which Rig has not taken. |
| **Jai** context, `push_allocator`, temporary storage | `push_allocator(a)` for a scope; `reset_temporary_storage()` once a frame | The same as Odin: games reset a frame's temporaries, unchecked | A per-frame or per-request reset is the real use; Rig gets it from scope exit, checked. |
| **Rust** `bumpalo`, `typed_arena` | `let a = Bump::new(); let x: &T = a.alloc(v);` and `bumpalo::collections::Vec<'bump, T>`; `typed_arena::Arena<T>` runs drops | The successful form: a container whose `alloc(&self)` returns `&'a T`. bumpalo does not run `Drop`; typed_arena does. Both are in the benchmarks game's fastest Rust | Design B below is this, in Rig's terms: `&self` alloc is a cell-like write; `'a` is `from r`; no lifetime written. Choose drop behavior explicitly. |
| **Rust** `allocator_api` (#32838) | `Vec<T, A>`, `Box<T, A>`: the allocator as a type parameter of every collection | Unstable since 2016; a 2026 project goal ("Allocators 1.0") still works on a subset | An allocator parameter on collections splits every type and every generic signature; ten years have not converged it. Rig should not add an allocator parameter to `List`/`^T`/`String`. |
| **C++** `std::pmr` | `std::pmr::monotonic_buffer_resource buf; std::pmr::vector<T> v{&buf};` | `pmr::vector` is a different type from `vector`; propagation rules on copy and move are subtle; virtual dispatch per allocation; a dangling resource is UB | The type split and propagation rules are the cost of carrying an allocator inside values. Rig's "no box stores an allocator" avoids both. |
| **Go** arenas (`GOEXPERIMENT=arenas`, #51317) | `a := arena.NewArena(); p := arena.New[T](a); a.Free()` | On hold since 2023-01-17 for "serious API concerns": using an arena "is going to be infectious", and hiding one in a struct does not help. Its successor, memory regions (#70257, `region.Do(func())`), is implicit and safe only because a GC write barrier "fades" escaping objects to the heap; still in discussion | Two lessons: an explicit arena threaded through APIs is infectious; an implicit one is safe only with a runtime that can rescue escapes, which Rig (no GC, by a non-goal) cannot have. Rig's views make the explicit form cheap: only builders take the region; readers take plain `?T`. |
| **Cyclone** regions (Grossman et al., PLDI 2002) | `region r { int *`r p = rnew(r) ...; }`, region names on pointer types, region polymorphism, inferred inside function bodies | Sound and fast; annotation-heavy at function boundaries; did not survive as a language | A lexical region block and pointer types that name it are the safe core; the annotation weight is what Rig's `from` inference removes. |
| **ML Kit** region inference (Tofte and Talpin) | Nothing: `letregion` inserted by the compiler | Works, but small program changes move values into long-lived regions and leak; the Kit later added a GC beside regions | Fully inferred regions are unpredictable: the cost model moves under edits. Against "the costs are where the sigils are" (DESIGN.md:250). |
| **Vale** regions | Region parameters `<r'>`, `pure` functions and `pure block`, region-prefixed calls, a planned `bump` keyword on a region | Prototyped 2023; opt-in ("one can write an entire Vale program without knowing about regions"); bump regions documented only as planned | Opt-in is right: a program that never names a region must look exactly as it does today. Vale spends syntax (a region sigil `'`) Rig would not. |
| **Verona** regions (Arvidsson et al., OOPSLA 2023) | An `iso` entry object owns a region; each region picks its strategy (tracing, counting, arena); one active region at a time; explicit enter | Research; regions are isolated units of ownership that move between threads | A region as an ownership unit that moves whole matches Rig's single owner; the per-region strategy is a library choice, not syntax. One active region is Verona's way to keep allocation unannotated; Rig keeps the region named at each `add`. |
| **Goose** data stacks and pools | No allocation syntax: growable arrays (`T[>..]`) live on compiler-assigned bump stacks freed at scope end; non-nesting data goes in `slot_pool<T>`/`slice_pool<T>` passed explicitly | Fast mostly by layout (docs/history/records/2026-11/goose/review.md: within 1.03-1.12x of an arena-with-indices C++/Rust); a stale pool slot reads another item ("a logic bug, but never memory corruption") | Data that dies together is the win, and Goose's pools are *containers passed explicitly*, not allocators. Rig can take the layout and keep its checker: a region's views cannot go stale, since the region cannot drop while one lives. |

## Three surface designs

All three are sketched on the same three programs. Code is plain text; none runs.
Helpers the sketches call that std may not have in that form (`split`, `cut`,
`render`, `parser.parse`) are illustrative.

### Design A: no syntax (inferred regions)

The compiler proves that a tree of boxes is made and dropped within one scope and
takes its boxes from a bump region freed there, skipping the drop walk.

```text
# binarytrees: the plain port, unchanged
obj Tree
  left: ^Tree? = none
  right: ^Tree? = none

fun bottom_up_tree(depth: Int) -> Tree
  return Tree() if depth == 0
  Tree(left: ^bottom_up_tree(depth - 1), right: ^bottom_up_tree(depth - 1))

fun inner(depth: Int, iterations: Int) -> String
  chk = 0
  for 0..iterations
    chk += item_check(bottom_up_tree(depth))   # inferred: this tree's boxes in a
                                               # region freed at the statement's end
  String(iterations, "\t trees of depth ", depth, "\t check: ", chk)
```

```text
# server: unchanged; every List and String the handler makes and drops is a
# candidate
fun answer(req: ?http.Request) -> http.Response
  fields = parse_query(req.query)          # List[Field], dropped at the end
  http.Response(status: 200, type: .json, body: render(?fields))
```

```text
# compiler pass: unchanged; the tree goes to a region only if nothing the pass
# keeps holds a box of it
sub check_file(prog: !Program, src: ?String)
  tree = parser.parse(src)
  checker.check(!prog, ?tree)
```

**How:** region polymorphism, as the ML Kit does: `bottom_up_tree` gets a hidden
compile-time region parameter, one instance per caller (Rig already makes an
instance per call for generics), and `long_lived = bottom_up_tree(max_depth)`
gets the heap instance.

**Verdict:** fits "no allocator ever named" perfectly and fails "effects visible"
and "the costs are where the sigils are". Storing one node in a longer-lived List
silently turns a bump region back into per-node allocation (the plain port is 4.5x
the fast Rust: notes.md), a cost moved by an edit far away, ML Kit's lesson. It
is a whole-program escape analysis in a compiler that checks modules in order. And
it does not answer the notes' real complaint, that the fast port's links are
indexes the checker cannot follow, since the plain port has no such problem.
**Not recommended.** A narrow, safe sliver (a box tree with no user `drop`,
dropped whole, freed by one walk with no per-node size lookup) is an allocator
optimization, not a language feature, and needs no design round.

### Design B: a `Region[T]` in std, and one CORE paragraph (recommended)

A region is a container you own. `!r.add(x)` moves `x` into it and gives a read
view of it there; the view lasts while `r` lives; dropping `r` frees everything
in one step. It is `shared.Map`'s contract (grow-only, nothing moves, views last)
for one owner, plus one new fact: **a value in a region may view the region**.

**The CORE paragraph** (a draft for sentence 9 or §5, within CORE §10's one
paragraph):

> **A region is a cell a local may own.** `Region[T]` changes only by its own
> calls: `!r.add(x)` moves `x` in and gives a `?T from r`, so like any cell's, a
> write view of it leaves `r` read-only, not unusable, and its views stay in use
> across later adds. Unlike other places, a value in a region may view that
> region: it is dropped only with the region, which runs every value's drop glue
> before it frees any memory. Any other view a value brings in is kept, as by
> `keeps`. A region is not a cell for tasks: it never goes to one while a view of
> it lives.

Desugaring: `!r.add(x)` is a call of `add(!@, x: T) keeps x -> ?T from @`, a
cell-like method kept in trusted Zig exactly as `shared.Map.ensure` is
(std/shared.rig:28-35, `marked_externs`). The only new checker fact is the
exception to "a value never holds a view of itself" (CORE.md:1683) for a region's
own values. Every other rule is CORE's as written: a view of `r` keeps `r` from
moving, being reassigned, or dropping (sentence 5), so a view cannot dangle.

```text
# binarytrees, the fast port written as the plain one
use std.math
use std.os
use std.par
use std.text

MIN_DEPTH = 4
RUNS = 64

obj Tree
  left: (?Tree)? = none
  right: (?Tree)? = none

# A tree of `depth`, built in `r`: its root, viewed there.
fun bottom_up_tree(r: !Region[Tree], depth: Int) -> ?Tree from r
  return !r.add(Tree()) if depth == 0
  right = bottom_up_tree(!r, depth - 1)    # `right` views r; r stays usable for adds
  left = bottom_up_tree(!r, depth - 1)
  !r.add(Tree(left: left, right: right))

fun item_check(t: ?Tree) -> Int
  if t.left as l and t.right as r
    return 1 + item_check(r) + item_check(l)
  1

fun run(depth: Int, count: Int) -> Int
  r = Region[Tree]()
  chk = 0
  for 0..count
    chk += item_check(bottom_up_tree(!r, depth))   # the root's view ends here
    r = <r.reset()                                 # empty, memory kept: needs no view alive
  chk
  # r drops here: its chunks freed in one step, no walk (Tree has no drop glue)

fun inner(depth: Int, iterations: Int) -> String
  runs = List[Int]()
  per = (iterations + RUNS - 1) / RUNS
  left = iterations
  while left > 0 : left -= per
    !runs.push(math.min(per, left))
  chk = par.map(?runs, |+depth, count| run(depth, count)).sum()
  String(iterations, "\t trees of depth ", depth, "\t check: ", chk)

sub main()!
  args = os.args()
  n = text.parse_int(args[1])! if args.len > 1 else 10
  max_depth = math.max(n, MIN_DEPTH + 2)
  stretch = max_depth + 1
  print(String("stretch tree of depth ", stretch, "\t check: ", run(stretch, 1)))

  long_lived = Region[Tree]()
  long_root = bottom_up_tree(!long_lived, max_depth)   # long_lived read-only while long_root lives
  ...
  print(String("long lived tree of depth ", max_depth, "\t check: ", item_check(long_root)))
```

What changed against the fast port: no indexes, `item_check` takes a tree, links
are views the checker follows (the notes' "hardest part" is gone), and each task
owns its region, so no region is shared. The cost: a node is 16 bytes where the
pool's is 8 (`p4.rig`), the same as bumpalo's Rust.

`reset` is `fun reset(<@) -> Region[T]`: it consumes the region, which CORE
already allows only when no view of it lives, and gives it back empty with its
memory. No new rule. (A `!r.clear()` could not exist: a cell's write view ends no
view.)

```text
# server: per-request scratch, freed when the handler returns
obj Field
  name: ?String
  value: ?String
  next: (?Field)? = none

# The query's fields, each in `r`, its text viewed in `q`.
fun parse_query(r: !Region[Field], q: ?String) -> (?Field)? from r, q
  head: (?Field)? = none
  for part in q.split("&")
    if part.cut("=") as (k, v)
      head = !r.add(Field(name: k, value: v, next: head))
  head

fun answer(req: ?http.Request) -> http.Response
  scratch = Region[Field]()
  fields = parse_query(!scratch, req.query)
  body = render(fields)                  # an owned String: it outlives scratch
  http.Response(status: 200, type: .json, body: <body)
  # scratch drops here; returning a Response that viewed it would be rejected:
  # "cannot return a view of `scratch`, which belongs to this function"
```

```text
# compiler pass: a tree that dies with the pass
enum Expr
  num(v: Int)
  name(text: ?String)
  call(callee: ?Expr, args: []?Expr)
  add(l: ?Expr, r: ?Expr)

sub check_file(prog: !Program, src: ?String)
  tree = Region[Expr]()
  root = parser.parse(!tree, src)        # ?Expr from tree, src
  facts = binder.bind(root)              # owned facts, by node order
  checker.check(!prog, root, ?facts)     # the checker may not keep a view of root:
                                         # prog outlives tree, and keeping one is rejected
  # tree drops: the file's whole tree in one step

# a run of views in the region, for a call's arguments
fun parse_args(p: !Parser, tree: !Region[Expr]) -> []?Expr from tree, p
  args = List[?Expr]()
  while not p.at(")")
    !args.push(parse_expr(!p, !tree))
  !tree.copy(?args[..])                  # one more member: a List's elements into the region
```

The pass example shows what the checker buys that Go's arenas never could: `prog`
cannot keep a view into a dead file's tree, because keeping one keeps `tree`
read-only past its drop, which is rejected at compile time. That is the guarantee
docs/TSRS.md:249 needs before Trig may free leaf files' trees ("needs per-file
regions"). Honest limits for Trig:
- Its trees are read by every checker across the program, by 4-byte `U32` ids
  (trig/src/ast/ast.rig:193-219, formal-plan.md:316 "arenas with IDs"), so a
  region does not replace its ids. The places a region fits are the data that
  does die together: the loader's per-file scratch Ast
  (`parse_source_file_into`, trig/src/parser/parser.rig:6685), the checker's
  lazy JSDoc arena (trig/docs/DIVERGENCE.md:47), and leaf files' trees in noEmit
  runs.
- Region values are read-only once added: no parent link set later. Facts
  computed later go in an owned List or Table by node order, as Trig does now.

**Members** (the whole first surface):

| Member | Signature | Note |
|---|---|---|
| `Region[T]()` | | empty; takes no memory until the first add |
| `!r.add(x)` | `sub add(!@, x: T) keeps x -> ?T from @` | moves `x` in, views it there |
| `!r.copy(?v[..])` | `fun copy(!@, xs: []T) -> []T from @` | a run of copies, for arguments lists and text |
| `<r.reset()` | `fun reset(<@) -> Region[T]` | empty, memory kept |
| `r.len` | `fun len(?@) -> Int` | values held |

Tasks: a `Region` holds no Cell a task may share, so it goes to a task only whole,
moved with no view alive (`Sends` when `T` is), like any owner. Views of its values
go to tasks as any read view does: they are only read, and no add moves a value.

### Design C: a current region for a block (word-level, implicit)

A block that makes a region current, so every allocation inside goes to it, as
Odin's `context.allocator`, Jai's `push_allocator`, and Go's `region.Do` do.

```text
fun run(depth: Int, count: Int) -> Int
  chk = 0
  for 0..count
    within Region()                              # every ^, List, String made inside
      chk += item_check(bottom_up_tree(depth))   # goes to the region
  chk

fun answer(req: ?http.Request) -> http.Response
  within Region()
    fields = parse_query(req.query)
    body = render(?fields)
  http.Response(status: 200, type: .json, body: <body)   # body escapes: rejected? copied?

sub check_file(prog: !Program, src: ?String)
  within Region()
    tree = parser.parse(src)
    checker.check(!prog, ?tree)                  # what if check pushes a String into prog?
```

**Verdict: rejected.** To be safe, a `^Tree` or `String` made inside the block
would have to be a view of the region, so the same expression would have a
different type inside the block than outside: against CORE §10's "its rules
follow the value's type, never where the value came from". Calls compound it:
`render` builds and returns a `String`, `checker.check` grows a List in `prog`,
and neither knows a region is current. Go solved that with a GC write barrier
that fades escaping objects to the heap (#70257); Odin and Jai do not solve it.
Rig has no collector, ever (DESIGN.md non-goals), so the only safe versions are a
runtime check per pointer store, which "Accept means correct" and the cost model
both refuse, or an effect system, which Rig has declined (NEEDS 6 is still open).
It is the form the owner's question invites ("allocation is never spoken of"),
which is why it should be named and set aside on the record.

## Which design fits Rig

| Principle | A: inferred | B: `Region[T]` | C: current block |
|---|---|---|---|
| Effects visible where they happen (DESIGN.md:47) | no: freeing moves invisibly | yes: `!r.add` marks the write, `?T` the view, the drop is a scope end | no: an `^` inside means something else |
| No allocator ever named | yes | yes: a region is a container like `List`; nothing takes an allocator | no: the block names one |
| Rules follow the type (CORE §10) | yes | yes: `?T from r` | no |
| Desugars to CORE forms | n/a | yes, plus one exception to CORE.md:1683 | no |
| Small surface | none | one type, five members, one paragraph | one keyword and a hidden context |
| Safe without a GC or runtime checks | yes, if the analysis is right | yes | no |
| Makes the fast port the plain one (notes.md) | no | yes | partly |

**Design B.** It is the substrate rule (DESIGN.md:91-95: "when a library cannot be
written cleanly, the language gains a general feature, never a special case"):
`shared.Map` shows a view-handing container is already a library; the general
feature the region needs is one sentence, that a region's values may view it.

## Is a new sigil justified?

**No.** A sigil earns its place by marking an effect a reader must notice locally
(DESIGN.md "Sigils rather than keywords"). Design B's effects are already marked:
the write to the region by `!` at `!r.add`, the result's tie to it by its type
`?T` and `from r`, the release by the region's scope end or `<r`. A sigil for
"box in a region" (`r^x`, `^x in r`) would save five characters at each add and
spend an eleventh sigil character on a library type, against "words are its
libraries". `Cell`, the closest relative, is a word, and so is `shared.Map`.

## Names to offer the owner

- **The type:** `Region[T]` (default): IDEAS.md:73 already says region; Cyclone,
  Vale, Verona and Go all say region; it avoids Trig's `core.Arena[T]` (a List
  port of Go's arena) and Zig's `ArenaAllocator`, whose name means an allocator.
  Alternatives: `Arena[T]`, `Bump[T]`. Not `Pool`: Goose's and most pools free
  one slot at a time.
- **Where:** in the prelude beside `List` and `Table` (default), or `std.region`.
- **Adding:** `!r.add(x)` (default; CORE already writes cell calls this way,
  `!a.add(x)`, CORE.md:1250). Alternative `!r.push(x)`, matching `Table`'s
  `!t.push(x)`, which gives a `Slot`; but `push` suggests a `pop` a region never has.
- **A run:** `!r.copy(xs)`. **Emptying:** `<r.reset()`.

## Decisions for the owner (defaults first)

1. **The shape: Design B, a `Region[T]` with the CORE paragraph; A and C set
   aside on the record.** Default: yes.
2. **When to build it:** after the measure IDEAS.md:75 asks for (Trig's share of
   time and memory in data that dies together), since binarytrees alone is
   parity with Rust, which CORE §10's last bullet does not count. Default: write
   the CORE paragraph as *(planned)* with a `rig pending` example now; build when
   the measure or a failing line in a real program asks.
3. **Values with drop glue:** a region runs every value's drop glue before it
   frees memory, newest first (typed_arena), and skips the walk when `T` has none.
   The alternative is to admit only plain values and views (bumpalo, Zig's arena).
   Default: run drops; the skip makes binarytrees pay nothing.
4. **Typed or untyped:** `Region[T]`, one type per region (default). An untyped
   region (`!r.add[T](x)`, several types, as bumpalo) waits for a program, likely
   Trig's per-file tree of nodes, lists, and texts.

## Biggest risk

Soundness of the one new fact. A value that views its own region is the
self-reference CORE forbids everywhere else (CORE.md:1683), and the paragraph's
safety rests on three things being true together: no region value moves (trusted
Zig, checked as `shared.Map`'s is), drop glue never reads freed memory (all drops
before any free), and a view a value brings in from another place outlives the
region (`keeps`). Each needs a case in the oracle and the Lean model before it is
built; by CORE §10, a second round of soundness fixes stops it for redesign. The
second risk is size: views are 8 bytes where Trig's ids are 4, so a region never
replaces "arenas with IDs" for data read across files.

## Sources

- Go arenas, on hold: https://github.com/golang/go/issues/51317 (hold note
  2023-01-17; mknyszek on infectiousness).
- Go memory regions: https://go.googlesource.com/proposal/+/HEAD/design/70257-memory-regions.md,
  https://github.com/golang/go/discussions/70257.
- Goose: https://github.com/aardappel/goose (README: data stacks, `slot_pool`,
  `slice_pool`).
- Vale: https://vale.dev/guide/regions, https://vale.dev/blog/zero-cost-borrowing-regions-overview,
  https://vale.dev/roadmap.
- Verona: Arvidsson et al., "Reference Capabilities for Flexible Memory
  Management", OOPSLA 2023, https://arxiv.org/abs/2309.02983.
- Rust `allocator_api`: https://github.com/rust-lang/rust/issues/32838,
  https://rust-lang.github.io/rust-project-goals/2026/allocators-1.0.html.
- Cyclone: Grossman, Morrisett, Jim, Hicks, Wang, Cheney, "Region-Based Memory
  Management in Cyclone", PLDI 2002 (from knowledge, not re-fetched).
- ML Kit: Tofte and Talpin, "Region-Based Memory Management", Information and
  Computation 1997; Hallenberg, Elsman, Tofte, "Combining Region Inference and
  Garbage Collection", PLDI 2002 (from knowledge, not re-fetched).
- Odin's `context`, Jai's `push_allocator`, C++ `std::pmr`, Zig's
  `ArenaAllocator`, bumpalo and typed_arena: from their documentation as known,
  not re-fetched.
