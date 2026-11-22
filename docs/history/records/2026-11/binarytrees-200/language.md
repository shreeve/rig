# binarytrees in 200 ms: the language and ownership view

Panelist: language and ownership. Read only in every repo. Probes and their timing scripts are in
`probes-language/` beside this file. Rig at local main `5cd726a84` (bin/rig 0.3.0); the arena
record and CORE's planned "Arenas" paragraph read from `origin/main` (`c3a5753b3`), where they
landed after the local checkout.

Every number is marked **measured** (this panel, Mac M5, `tools/mac-claim`, fastest of 7
interleaved rounds, `/usr/bin/time -l`, 10 ms resolution, every output md5
`baf0dcbc307297f68bd9459833db9f73`) or **estimate**.

## 1. What the measurements say first

Three probes that change one thing each in the ports that build today
(`probes-language/times.txt`, measured):

| Probe | What changed | Wall | CPU | Peak |
|---|---|---:|---:|---:|
| `plain` | today's plain port (`^Tree` boxes, a task per depth) | 0.82 s | 5.72 s | 174 MB |
| `plainsplit` | plain boxes, the fast port's 64-run `par.map` split | 0.80 s | 6.43 s | 565 MB |
| `fast` | today's fast port (`List[Node]` pool, I32 links, reused) | 0.21 s | 1.79 s | 346 MB |
| `fastdepth` | fast, **no split**: a task per depth, as the plain port | 0.21 s | 1.57 s | 92 MB |
| `fresh` | fast, **a new exact-capacity pool per tree**, no reuse | 0.21 s | 1.71 s | 249 MB |
| `wide` | fast with `Int` links: a **16-byte node** | 0.25 s | 2.01 s | 453 MB |

And a pure-Zig model of the plain port's shape with the approved arena's code shape (a thread
per depth, an arena per tree, nodes added after their subtrees as `!a.add(Node(left: l, right:
r))` does, an inlined bump, nothing walked at drop, a dropped arena's memory reused;
`probes-language/model.zig`, `times2.txt`, measured):

| Model | Link | Node | Wall (median) | CPU | Peak |
|---|---|---:|---:|---:|---:|
| `ptr16` | 8-byte pointer, the approved `(?Node)?` | 16 B | 0.25 s (0.26) | 1.82 s | 172 MB |
| `rel32` | 4-byte offset from the node itself (Goose) | 8 B | 0.24 s (0.25) | 1.77 s | 87 MB |
| `idx32` | 4-byte index from the arena's base (the pool) | 8 B | 0.24 s (0.24) | 1.75 s | 87 MB |
| Rig `fast`, same rounds | | 8 B | 0.22 s (0.23) | 1.78 s | 323 MB |

Node order, in the same model with 16-byte nodes (`times3.txt` to `times5.txt`, measured; each
row's numbers are from its own rounds, so compare within a round):

| Model | Order | Wall (median) | CPU, mean |
|---|---|---:|---:|
| `ptr16` | node added after its subtrees, walked left first (the approved arena's code) | 0.26 s (0.27) | 1.83 s |
| `ptr16down` | the same, the arena bumping downward (bumpalo's direction) | 0.25 s (0.25) | 1.82 s |
| `ptr16rev` | the same, walked right first (descending, in order) | 0.24 s (0.25) | 1.76 s |
| `ptr16pre` | **the node's place taken before its subtrees**, filled after (rust-5's order) | 0.22 s (0.23) | 1.58 s |
| `rel32pre` | place first, and 4-byte self-relative links | 0.21 s (0.22) | 1.58 s |
| Rig `fast`, same rounds | the pool, place first (binarytrees-fast.rig:22-27) | 0.21 s (0.22) | 1.75 s |

Conclusions:

1. **The program's shape is not the gap.** The 64-way split buys nothing on the Mac
   (`fastdepth` = `fast`), and it does not help boxes (`plainsplit` = `plain`). The plain port's
   task per depth is fine. (runtime.md section 5 attributed the fast port's edge to the split;
   on the Mac it is not.)
2. **Reuse is not the gap.** A fresh pool per tree costs nothing (`fresh` = `fast`): Rig's
   allocator hands the freed block back. So the approved "no reset" (SYNTHESIS.md:45-47) costs
   no speed, provided a dropped arena's chunks go back to the per-thread heap and come out warm.
3. **The whole gap is the cost per node.** 5.72 s against 1.6-1.8 s of CPU for about 616 M
   nodes: about 9 ns a node against 3. The approved arena removes the allocator call and the drop
   walk; the model says that alone, with 16-byte pointer nodes, lands at about 250 ms.
4. **Order is worth more than width.** Taking a node's place before its subtrees, so the walk
   reads memory ascending, buys 30-40 ms and 0.25 s of CPU with pointer nodes. The approved
   arena's natural code adds each node after its subtrees, the slow order.
5. **Compact links are worth 10 to 20 ms**, not 40-50: `wide` against `fast` (+40 ms best,
   +50 ms median) also pays i64 index arithmetic and bounds checks; between pointer and offset
   nodes in the same model the difference is 10-20 ms of wall and 0.05 s of CPU, and half the
   memory. With place-first order and compact links the model equals the fast port.

## 2. The baseline: the approved Arena, written as the plain port

```text
use std.arena

obj Tree
  left: (?Tree)? = none                       # was ^Tree?
  right: (?Tree)? = none

fun bottom_up_tree(a: !*arena.Arena[Tree], depth: Int) -> ?Tree from a
  return !a.add(Tree()) if depth == 0
  !a.add(Tree(left: bottom_up_tree(!a, depth - 1), right: bottom_up_tree(!a, depth - 1)))

fun item_check(t: ?Tree) -> Int               # unchanged
  if t.left as l and t.right as r
    return 1 + item_check(l) + item_check(r)
  1

fun inner(depth: Int, iterations: Int) -> String
  chk = 0
  for 0..iterations
    a = arena.Arena[Tree].new()               # one arena per tree, dropped each turn
    chk += item_check(bottom_up_tree(!a, depth))
  String(iterations, "\t trees of depth ", depth, "\t check: ", chk)
# main: the same, with an arena for the stretch tree and one for the long-lived tree
```

Against the plain port (binarytrees.rig:11-28) it changes two field types, one parameter, `^x`
to `!a.add(x)`, and adds one line per tree. That is as close to the plain port as Rust's
typed-arena port is to a `Box` one. CORE says nothing new for it beyond the planned paragraph
(CORE.md:924-940 on origin/main) and the self-view exception (CORE.md:1737-1739).

What it must do at run time to reach the model's ~250 ms, which the record did not pin down:

- **`add` inlined in the emitted Zig**: the bump (`cur + size <= end`, store, advance) in the
  caller, the new-chunk path a call. runtime.md's 0.35-0.45 s estimate (runtime.md section 5)
  assumed "one noinline bump call" because its M1 routing had to live inside alloc.zig behind a
  thread-local. An explicit arena needs no thread-local: its window is in the value. This is
  the single largest number in this report. Estimate: 0.82 s to 0.25-0.30 s with inlining,
  0.35-0.45 s without.
- **No walk at drop** (`T` copies, so dropping the last handle frees chunks; already decided).
- **A dropped arena's chunks back to the thread's heap, warm**, so a new arena per tree costs
  what `fresh` costs.

Rig-specific costs the model does not have, for the compiler panelist: `rig.tickCall()` in every
call (fast.zig emit, line 25), and the `!*Arena` parameter is a pointer to a handle to a counted
box, one load more per add than the model. Estimate: 10-30 ms together.

## 3. The four mechanisms asked about

### 3.1 Compact arena links

**Form.** A type that lives only in an arena, whose views of its own kind are 4 bytes:

```text
arena obj Tree                     # lives only in an Arena[Tree]
  left: (?Tree)? = none            # 4 bytes: where the Tree is, relative to this field
  right: (?Tree)? = none
# everything else exactly as in section 2
```

**How it is read without the base.** Goose's answer (goose/review.md:30-33): the link is an
offset from the field's own address, so `t.left` is `&t.left + off`, one add, and gives an
ordinary `?Tree`. A base-relative index works too if each arena is one reservation aligned to
4 GiB (`base = addr & ~(4 GiB - 1)`), but it caps live arenas by address space; the
self-relative form does not. Both measured the same (`rel32`, `idx32`).

**Why it must be a type of its own.** A `?Tree` field inside an ordinary `Tree` can't be
compact: the same `Tree` value is built on the stack and moved into `add`, copied out by
`x = t`, and viewed outside any arena, and an offset means something only at its final address.
So the representation must follow the type (CORE §10: rules follow the type), which needs
the type to live only in an arena, as a frozen value lives only behind `*` (CORE.md:864-866):
never a local, parameter, element or field by value, never copied out (only its fields are
read), and `Tree(...)` written only as `add`'s argument, **built in place** there (section 3.4),
since the offsets need the node's address.

**What CORE must say (one paragraph):** "An arena type, `arena obj T`, lives only in an
`Arena[T]`: never by value in a local, parameter, element, or field, and `T(...)` is written only
as `add`'s argument, where it is built. It is read through views only. A field of it that views
a `T` holds a view of the same arena's values; it is stored as where that value is relative to
the field. No rule about views changes." The checker treats the field as `(?T)?` in every rule;
the representation is §9's per-type "how a read view is represented" (CORE.md:2349).

**Soundness.** The views are real and followed as today, so accept-means-correct holds if
(a) the same-arena rule is checked: a view stored in the field must carry a loan of the arena
being added to (loans already name places, CORE §9 "per expression"), and (b) the runtime keeps
one arena's memory within 2 GiB of itself (one reservation per arena, recycled; `add` panics
past it, a resource limit like running out of memory). Without (a), a view of another arena
could be out of range: a range test at `add` would keep it safe but turns a valid program into a
panic, so (a) is the default.

**Set aside within it:** a `Slot`-like typed index read as `a[r]`. It needs the arena at hand,
and Rig has no way to brand an index with one arena, so `a[r]` with `r` from another arena reads
the wrong node: memory-safe, but a wrong program accepted, the logic error goose/review.md:59-63
holds against Goose.

**Gain.** Measured in the model: 10-20 ms wall, 0.05 s CPU, half the memory (172 to 87 MB).
**Cost:** high: a new kind of type, its by-value refusals, the same-arena check, a reservation
per arena in the runtime, and field reads and writes in the emitter. Worth it for memory before
speed; Trig's 4-byte ids (SYNTHESIS.md:118-119) are the second customer.

### 3.2 Boxes placed in an arena

```text
obj Tree
  left: ^Tree? = none
  right: ^Tree? = none
fun bottom_up_tree(a: !*arena.Arena[Tree], depth: Int) -> Tree
  Tree(left: a^bottom_up_tree(!a, depth - 1), ...)     # or ^x in a
```

**What breaks under CORE.** A `^T` is owning: one owner, moved by `<b`, dropped once, and a
heap `Tree` may hold it (CORE.md:102-104). A box from an arena must not outlive the arena, so it
carries a loan a heap box does not: the same type `^Tree` would then have two sets of rules
depending on where it came from, which §10 forbids. A heap `Tree` whose `left` is an arena box
dangles once the arena drops. Making it sound needs a second type, an owning-looking `^Tree
from a`, which is `?Tree from a` under another spelling with drop glue that must do nothing.
The design panel already weighed the spelling (`r^x`, `^x in r`) and set it aside: it saves five
characters at each add for an eleventh sigil use on a library type (design.md:369-375).
**Gain over the arena: 0 ms.** **Recommendation: no.** The plain port's shape survives anyway:
`^Tree?` becomes `(?Tree)?`.

### 3.3 The arena from context

The record set aside a block that makes an arena current (SYNTHESIS.md:66-70): anything
allocated in its dynamic extent, an outer `List` grown inside it, lands in memory freed after
it, and the same `List` means different things inside and outside (CORE §10).

**Sound narrower forms, and what they buy:**

- *Arena types only*: `^Tree(...)` of an `arena obj` goes to the arena in scope. This is 3.2
  with an implicit `a`; it is sound only if that type can never be allocated elsewhere, which
  3.1's rules already give, and then `add` is no longer written. It hides the one `!` that marks
  the write.
- *An implicit parameter*, desugared: `fun make(d: Int) -> ?Tree from a  given a: !*Arena[Tree]`,
  callers passing their own `a` by name. Sound (it is an argument), but `!a` disappears from
  every call, against "the costs are where the sigils are" (DESIGN.md:250). It is Trig's open
  NEEDS 6 (design.md:69).

**Gain: 0 ms**; the price today is `!a` at three call sites and one parameter. **Recommendation:
no**, for both forms.

### 3.4 Anything else

- **`add` takes its place before its argument is evaluated (the best find here).** In
  `!a.add(Tree(left: bottom_up_tree(!a, d - 1), right: bottom_up_tree(!a, d - 1)))` the emitter
  bumps the arena for this node first, evaluates the argument (whose calls add the subtrees
  after it), then builds the `Tree` straight into the place. The source is unchanged from
  section 2; the layout becomes rust-5's (rust/fast/src/main.rs, `bottom_up_tree`), and the
  plain port's left-first walk reads memory ascending. Measured in the model: 0.26 s to 0.22 s,
  1.83 s to 1.58 s of CPU (`ptr16` against `ptr16pre`).
  - **CORE:** nothing. Rig gives views no address or identity (SPEC.md:2203, 5729), so where an
    arena puts a value is unobservable, and this is an optimization that changes no rule (§10).
    If the argument fails or panics, the place stays unused: bytes wasted in an arena that is
    freed whole, with no view of them and no drop.
  - **Soundness condition:** the arena must outlive the argument's evaluation, so the emitter
    takes the place first only when the argument cannot move, reassign or drop the arena's
    handle (it takes only `!a`, read views and plain values); otherwise it adds after, as
    today. This rests on CORE §6's evaluation order (CORE.md:1981) and needs a checker test
    both ways.
  - It is also IDEAS.md:73's "a result built where it lands", and it is what 3.1 needs anyway:
    a self-relative offset is computed at the final address.
  - The alternative with no compiler work, walking right first in `item_check`, buys only half
    (`ptr16rev`), and a downward-bumping arena buys nothing (`ptr16down`).
  - An explicit form (`at = !a.reserve()` ... `!a.fill(<at, Tree(...))`, a move-only
    reservation) is sound too but moves the code away from the plain port; not needed.
- **A tree type in std.** binarytrees is the only program it would serve; nothing it does is
  out of reach of `Arena[T]`. 0 ms. No.
- **Struct of arrays.** Both links are read together on every visit; splitting them doubles the
  lines touched. 0 ms or worse. No.
- **"Dies with the statement."** `item_check(bottom_up_tree(depth))` makes a temporary tree that
  dies at the statement's end, so the compiler could put its boxes in a statement arena and the
  plain port would run unchanged at about arena speed. It is inferred regions under another
  name (SYNTHESIS.md:62-65): the boxes are made in callees, so it needs the dynamic routing
  rejected above; a statement whose callee loops would keep every dropped value until the
  statement ends, turning steady memory into growth; and a callee's signature change far away
  turns it off silently. No.

## 4. Ranking (milliseconds from today's plain 0.82 s, against the cost to build)

| # | Mechanism | Gain | Cost | Verdict |
|---|---|---|---|---|
| 1 | Approved `Arena[T]`, `add` inlined, no drop walk, chunks reused warm | 0.82 s to ~0.26-0.30 s (estimate, from the model's 0.26 s) | already approved; inlining is a design point to fix now | build first |
| 2 | `add` takes its place before its argument (place-first order) | 30-40 ms, 0.25 s CPU (measured in the model) | low: the emitter and one checker condition; no CORE rule | build with 1 |
| 3 | Rig overheads per call (`tickCall`, the handle's extra load) | 10-30 ms (estimate) | compiler panel | measure after 1-2 |
| 4 | Compact links (`arena obj`, 4-byte self-relative) | 10-20 ms, half the memory (measured in the model) | high: a type kind, a CORE paragraph, runtime, emitter | only if short after 1-3 |
| 5 | Boxes in an arena | 0 | a second box type | no |
| 6 | Arena from context | 0 | hides `!` | no |
| 7 | Statement temporaries, std tree, SoA | 0 or unsound | | no |

## 5. Recommended path to ~200 ms

1. Build the approved arena with `add` emitted inline, taking its place before its argument,
   and dropped chunks reused per thread. Port `binarytrees.rig` as in section 2 (about eight
   lines change), keeping the task per depth.
2. Measure it on the Mac against `fast`. Expected 0.22-0.26 s (estimate: the model's 0.22 s
   plus Rig's per-call costs).
3. Close what is left in the emitter (the per-call tick, the handle's extra load), the compiler
   panel's ground.
4. Only if still short, compact links (3.1): 10-20 ms more and half the memory; with them the
   model equals the fast port (0.21 s).

## 6. Decisions for the owner (defaults)

1. `add` is emitted inline, its slow path a call; std.arena's bump window lives in the value,
   not behind alloc.zig's thread-local. **Default: yes.**
2. `add` takes its place before evaluating its argument when the argument cannot touch the
   arena's handle; no CORE rule, a SPEC note and a test both ways. **Default: yes.**
3. No reset stays; a dropped arena's chunks return warm to its thread's heap. **Default: yes**
   (measured: a fresh pool per tree costs nothing).
4. The plain port keeps its task per depth. **Default: yes** (measured: the split buys nothing).
5. Compact links as an `arena obj` type. **Default: defer** until step 2 is measured; not
   rejected.
6. Boxes in an arena, an arena from context, statement temporaries. **Default: set aside.**

## 7. Biggest risk

The model is not Rig. It has no per-call preemption tick, no counted handle, OS threads instead
of tasks, and a bump that never needs a new chunk (one block per thread, rewound). If Rig's
arena port lands at 0.27 s instead of 0.23 s, the rest is emitter and runtime work, not a rule
CORE can add; compact links buy only 10-20 ms of it, at a high price. A second risk is the
place-first condition: if the checker lets an argument move or drop the arena's handle, a
place taken first dangles, so the condition must be checked, not assumed.
