# Backlog

Engineering work that is decided and not started: the probe cases that
found each item, measurements, and the change that would fix it. The
direction is in [ROADMAP](../ROADMAP.md), where the work stands in
[HANDOFF](../../HANDOFF.md), and the areas that need care in
[weak-spots](weak-spots.md).

- A known over-strict rejection: what a call stores from a view reached
  through a lent read view should carry that view's loans, not a loan
  on the holder (Core sentence 7). `hold(!@, c: ?Cursor)` storing
  `c.items` must say `keeps c`, and then keeps `c` itself lent while the
  holder is used, though only `c.items`' loans need to last. Narrowing
  it needs a new reach fact (what a lent parameter's own view target is,
  apart from what it reaches through the views it holds) and a call rule
  that stores the argument's held loans instead of its lend. Probes:
  the cases `corekeeps-p4 store through view` and `corekeeps-p4b keeps
  through view` of test/rig/probes-08.rig.test.
- Several results, after v1 (SPEC "Several results"):
  - small results in registers: pack results of up to two words of
    integers, `Bool`s, and pointers into a `u128`, which Zig's default
    calling convention returns in registers where it returns a tuple
    or an object through memory; it serves objects too, and lands only
    if it passes the speed rule;
  - write lends ended per argument: while a result holds a write view,
    the lends of the arguments its origins leave out could end at the
    return, as they do when no result holds one;
  - `from` per result, so a write view and a read view may come from
    different parameters whose types could both hold either, and
    several write views a function proves disjoint (sentence 5);
  - a `catch` or `??` fallback that gives every result (`catch 0, 0`);
  - `for k, v in it` over an iterator whose `next` gives several
    results, decided with iterators as values;
  - `ResultBound` per result, so a proven bound on a result reaches the
    name that takes it (`src/proofs.zig`).
- bench/hash after inlining a generic type's small members (#246), on
  the Mac (aarch64), pooled medians of 8 layouts x 21 runs against main:
  - `int hit` is 2-6% slower, and `small 4` and `small 8` 2-3% slower:
    LLVM spills registers differently in a function that holds several
    loops once more is inlined into it. The code of `int hit`'s loop is
    the same as main's, and x86 shows no difference. Needs a study.
  - `int edit_put-hit` is 3.0% slower (95% interval -3.8% to +9.6%):
    inside the noise, but worth measuring again.
  - Judge memory-bound bench/hash rows by medians with intervals and an
    unchanged control row, not by the fastest of N runs, which swung
    single rows several percent either way on unchanged code.
- Every copy out of a view in a generic body takes the per-instance
  `copies` requirement, as `Cell.get` and a `??` through a view of an
  optional do: today a view read where its `T` is expected (`p` in
  `fun copy[T](p: ?T) -> T`, `v` of `if m.get(k) as v`) and
  `m.get(k) ?? d` are rejected outright, as `T` may not copy in every
  instance.
- A generic body's own holding of a `T` (`h = *<x`, `List[*T]`, a call
  passing `<x` to `*T`) at an instance whose `T` is held (`T = ~U`
  makes `*~U`): rejected per instance, with the generic per-instance
  requirements round (option (b)). [SPEC](../../SPEC.md#boxes-t) shows it as pending.
- Destination-passing for values over about 64 KiB: emit passes,
  returns, and copies none by value through a Zig temporary, and lowers
  a `defer` or inlined body that declares one to a single call. A
  frame's real size is then bounded by construction; today it is a
  measured bound, `sema.reach_factor` (4) times its reach, which
  `test/cli/frame_reach.sh` checks, and a form Zig copies that reach
  does not model could exceed it. Two did in #230's review, both fixed:
  a payload part a `match <e` arm drops, passed by value at each exit
  (the case `rev230-discard-exits` of test/rig/probes-16.rig.test); and the same at 12,000
  exits, whose 48 GB frame made Zig's aarch64 build fail with `fixup
  value out of range` (`test/cli/discard_build.sh`; a frame over 4 GiB
  draws Zig's warning, and one that large fails to build).
  With it, build debug programs for x86_64 with `-fllvm`, as aarch64's
  are.
- The reference checker (`bin/rig-oracle`) models no tasks: a wait's
  failure (`>t!`, `>t catch`) and the loans a task keeps while it runs
  have no second opinion beside the compiler's. Teach it CORE's rules
  for them, as it learned "A failure moves its error" (#601).
- The reference checker (`bin/rig-oracle`) takes memory quadratic in
  the exits of one `match` arm. For an arm `.one(_, n)` of `match <e`
  with that many `return ... if ...` lines, its peak resident memory:

  | Exits | Peak memory |
  |---|---|
  | 50 | 6.7 MB |
  | 100 | 10 MB |
  | 200 | 24 MB |
  | 400 | 74 MB |
  | 12,000 | 52 GiB (measured on Linux) |

  At 12,000 exits it took down a 7 GB CI runner, so that program is a
  CLI test (`test/cli/discard_build.sh`), which the checker never sees,
  rather than a case of test/rig. Make it linear, then the program can
  become a case.
- `text.ByteSet`, a byte set built once when the program runs and
  searched with `set.find(s, at)`: the run-time sibling of
  `text.find_any[set]`. Built when a port needs a set known only at run
  time; none does yet.
- Big integers in the standard library, to replace Trig's own: arbitrary
  precision, enough for JavaScript number and BigInt work (Trig's jsnum
  uses them in 3 places). Trig's version passes all 32,076 of its test
  cases; the std one must pass the same cases and be as fast before Trig
  swaps.
- Map and Set with 4-byte stored hashes (an entry's hash takes 8 bytes
  today): the tag from the stored bits up to 2^25 slots, and from the
  top of the whole hash, recomputed from the keys, past that. It
  matched the 8-byte version's speed; it saves 4 bytes an entry.
- Faulting memory in ahead, measured; the third form below is built.
  Trig's ts-pattern takes about 115,000 page faults on pup.
  Asking for huge pages (`MADV_HUGEPAGE`) made it 13% slower, as pup's
  fragmented memory made each advised fault try a compaction that
  failed. Faulting in with one `MADV_POPULATE_WRITE` per stretch rather
  than a trap per page was measured on pup (Trig: core 3, fastest of 10,
  interleaved; Rig's benches: 3 or 4 rounds):
  - each 1 MiB of a segment as the heap reaches it: Trig 1.4 to 1.9%
    faster, RSS about 2% higher;
  - that, and each large block whole, and its growth: 2.6 to 4.5%
    faster, RSS 16 to 26% higher;
  - that, but a new large block's first three quarters and half of a
    growth, at most 8 MiB: 2.8 to 5.8% faster, RSS 6 to 9% higher. It
    made `bench/actors`' spread about three times as slow (each of 22
    workers faults in its first MiB at start), `spawn` 5% slower, and
    `bench/http` answer up to 20% fewer requests (buffers written
    sparsely);
  - only the half of a growth by `mremap`: no regression, and 0.9% on
    ts-pattern, which does not pay for its lines.

  The third is built, applied only by the heap that does the program's
  work (`src/alloc.zig`, `leads`), which keeps Trig's gain at one
  checker and leaves the benches as they are.
- The Map's entries in its table slots, measured and not taken. A hit
  waits on memory twice: for `tags[i]` and `at[i]`, which load
  together, then for `es[j]`. Putting each key and value in its slot,
  with the order kept as a List of slot indexes, waits once. On cold
  lookups over 4M entries (a Mac bench of `CacheKey` keys and `U32`
  values, dependent, 90% hits) it took 92 to 95 ns against 152 to 156.
  But real Trig on pup, which inserts nearly as much as it finds, was
  12% slower on ts-pattern, with 41% more RSS (646 MB against 459), and
  4 to 6% slower on zod3 and tiny-invariant. `bench/hash`, which looks
  keys up in the order they were put in, lost too: hits about twice as
  slow, inserts 40 to 70% slower, iteration about 16 times as slow.
  Packing the tag and the index into one `U64` slot instead saved
  nothing: the two arrays already load together. The slot was 40 bytes
  for a `CacheKey` and a `U32`, where a plain one is 24, because a free
  slot holds no `K` or `V`, so both are optional fields. A `Slot?` the
  size of a `Slot` (its place in the order an object that names its
  none) needs `if !@slots[j] as s` to hand a write view of `s.value`
  back to `edit`'s caller (`from @`), which the checker accepts (CORE
  sentence 7), and a field moved out of its object alone (partial
  moves). A layout to try again starts from that.
- Remote frees batched per owning heap, as Linux 7.4's slab sheaves
  and snmalloc do. Today each free of a block another heap owns
  (`src/alloc.zig`) is one compare-and-swap onto that heap's remote
  list; a batch would gather a chain per owner and push it with one.
  Measure first, on a multi-checker Trig run: how many frees are
  remote, and the share of time those compare-and-swaps take. Source:
  Rig (fork)'s errors-track handoff.
- Active workers tracked, rather than every worker scanned, as Linux
  7.4's workqueue flush does. `src/sched.zig` walks all workers in
  `earliestDue`, `claimWaiting` and `takeWaiting`, `busyDescriptors`
  and `serviceAll`, stealing, and the check for any work; a bitmask of
  the active ones, or one shared earliest deadline, would replace the
  walks. It matters only at 64 or more cores. Measure first, on such a
  machine: the share of a scheduler-bound bench's time those scans
  take. Source: Rig (fork)'s errors-track handoff.
- An unwrap of an optional that traps when it is `none`. The built-in Map's
  `Map.ensure` reaches its value, which is never `none` there, with a
  `while true` whose only exit is a `return`; the unwrap would replace it.
- `Map.ensure`, `Map.put_new`, and `Set.add` taking a `?K` and cloning
  the key only when it is stored (owner approved), now that `+k` of a
  `?K: Clone` clones in a generic body; today they take an owned `K`.
- A clone in a generic body of a value that holds a type parameter
  behind a List or a box (`+xs` of a `?List[T]`, `+b` of a `^T`) is
  still "a type parameter has no deep clone in a generic body": its
  requirement would walk the parameters a value reaches
  (`reachedTypeVars`), not those it holds by value.
- Compiler memory on two generated shapes, the same on main, found by
  #270's review.
  - One straight-line function of 10,000 bindings takes 2.6 GB, and one
    of 20,000 takes 10 GB. Proofs take most of the time, and likely the
    memory.
  - A chain of generic functions, each calling the next at
    `(fun(T) -> Int)?` of its `T` (which adds no instance depth), grows
    about cubically: 300 links take 1 GB, 1000 take 19 GB.
- A view of an error with fields as a view of a set that holds it: `?a`
  of `a: A` where a `?L` or `?error` goes is a type mismatch, and the
  value is bound as the union first. Both read the same
  `rig.ErrorValue`, but the ownership checker's reach (`sema.viewReach`)
  would have to see a `?L` reach an `A`, or a view of a temporary `A`
  outlives it.
- Lending a handle parameter to write is accepted as `!c` but rejected
  as a capture. In `sub poke(c: *Cell[Int])`, `(!c).set(2)` lends the
  Cell `c` holds, while `f = |!c| (!c).set(3)` is "cannot lend parameter
  `c` to write". So is `!o.h` for `o` an owned parameter. Decide whether
  a capture and a field lend, like `!c`, lend what the handle holds.
- **A closure that stores nothing, at a value type that can hold a
  view** (deferred by the owner). `!m.update(|k, v| v = none)` on a
  `Map[String, (?String)?]` is refused with its instance (SPEC "Generic
  bodies"): the rule reads the function value's type, not the closure.
  A refinement would check a closure literal's body, or a declared
  function's, at each call, and discharge the requirement where it
  stores and gives no view of a parameter; it would accept that call,
  `retain(|k| k.len == 5)` on a `Map[?String, ?String]`, and
  `update(|k, v| v = "lit")`.
- **A scheduler unit test fails under load** in a debug build.
  `src/sched.zig`'s "two tasks that answer each other over a socket stay
  on one worker" counts the answers a side reads on a worker other than
  the one that wrote them, and expects few. On pup, with another release
  build's load (1.2 to 5.4), `zig build test -Doptimize=debug` failed it
  in 3 of 4 runs, on main as on a branch that left the scheduler alone
  (2026-10-27); safe and fast passed.
  Decide whether the test measures a property load may break (and
  should allow a share of crossings, or run pinned), or the scheduler
  lets a woken pair drift apart under load.

Found while writing the Learn Rig journeys. Those marked *checked* were
confirmed on `main` when they were written here; check the rest before
fixing.

- **A discarded result passes silently** *(checked)*. `file.remove(p)!`
  as a statement drops its `Bool` with no error, while a bare `0` is
  rejected. Make the rule one: a statement whose value is not `Void`
  needs `_ =`, or say in SPEC why a call's result may go unused.
- **The shorthand `c.area()` does not see through a box,** though the
  type's own methods do (`b.area()` on a `^Square`); `b.describe()`, a
  default, says "no method `describe` on type `Square`". Decide whether
  a box takes the shorthand, and name the API in the message either way.
