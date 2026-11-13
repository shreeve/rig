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
- Keeping a function out of line when its loop makes a call that stays a
  call (through an API table, a `rarely` function, a closure) and it
  would be inlined into a caller with loops of its own. On arm64 the
  merged function runs out of callee-saved FP registers: ray-dyn with
  `ray_color` `noinline` runs 6.2% fewer instructions and 2.2% fewer
  cycles on the Mac; on x86-64, which saves no XMM register across a
  call, it is level. Needs 20 quiet rounds on the Mac and a measure on
  Trig before it is a candidate
  ([records](../history/records/2026-10/ray-inline/README.md)). Trig's
  200 KB higher peak memory in #777 (0.06%), against 8 KB more code, is
  not yet measured.
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
  the exits of one `match` arm. For an arm `.one(:n)` of `match <e`
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
- Big integers: `std.bigint` is built. Trig's own arbitrary-precision
  integers (its jsnum uses them in 3 places) pass all 32,076 of its test
  cases; the std one must pass the same cases and be as fast before Trig
  swaps.
- **`from @field` through an alias of self**: `whole = ?@` then
  `whole.text` in a `from @text` body is reported as a view of all of
  `@`, since an alias of self carries no path. Over-strict; it waits for
  a program that writes it.
- **A field of a bounded iterator's type**: `Hold[I: Iter]{inner: I}` is
  refused by `[I: Iter]` under `from @field`'s rule 4, which judges a
  field of a type variable at the declaration; judging it per instance
  would admit it, when an iterator adapter needs one.
- **API objects, the conservative edges**, each over-strict, none
  unsound, each waiting for a program that needs it:
  - a `?String` view of a `String` with `add String: Shape` is no
    `?{Shape}` ("a view provides no API"), though the `String` itself
    erases;
  - a local task over an object, `area_of(s)&` of a `?{Shape}` or
    `make()&` giving a `^{Shape + Owned}`, is refused as if it could
    leave its scope;
  - `fun me(?@) -> ?{Shape} from @` cannot leave, since self erased is
    a copy by kind (H12);
  - `swap(!h.g, v)` of a `^{Shape}` is refused as a value that may hold
    a view, where a `^{Shape + Owned}` swaps.
- **Traces in Rig terms**: a panic, or an error that leaves `main`,
  prints Zig's stack trace, whose lines are in the emitted Zig (in the
  package directory `rig run` names); mapping them to `.rig` lines would
  need a source map.
- **An explicit emitter context**: the emitter keeps per-function state
  in `Emitter.fun`, swapped out around a closure's body; passing it
  explicitly would make what each helper reads visible.
- **Tighter generated code**: Debug builds pay for round trips such as
  `rig.lend(&rig.elemPtr(xs, j).*)` and `rig.eql((&p).*, (&q).*)`, and a
  generic `for x in xs` copies each element it only lends. Release
  builds optimize these away.
- **A statement under `if target.debug` leaves a trace in a release
  build** (Trig's NEEDS 77). `target.debug` is known at compile time,
  so `@check_node(n) if target.debug` should vanish before emit in a
  release build. Trig put that line in about 450 of its AST readers
  (trig#338): on contracts at one checker on pup, the release build ran
  0.26% more instructions and its binary was 1.56 MB larger, though Zig
  prunes the call's body. The likely cause is before Zig: the call still
  reaches `src/inlining.zig`, which counts it in its caller's size, and
  `@check_node`'s body is emitted. The fix drops a statement whose
  compile-time condition is false, and the false branch of such an
  `if`, before inlining's budget and emit see it, with no change to the
  language. The case: a function whose only statement is `f(x) if
  target.debug` emits no call and no `f` in a release build (a `code`
  case), and Trig's 450 readers retire level instructions.
- **Nexus's `Span.text`** in place of slicing the source by position.
- **Runtime tests outside the runtime**: `src/runtime.zig` carries its
  unit tests into every emitted package; they could move to their own
  file.
- **A float's `math.pow` as accurate as libm's**: Zig's
  `std.math.pow` gives C's answers for zeros, infinities, and NaN, but
  its values can differ from libm's in the last digits: `pow(1.0000001,
  1e9)` is 2.688103843211962e43 where libm gives 2.6881038582144647e43
  (5.6e-9 relative), and `pow(0.999, 12345.6)` is about 500 ULP off.
- **A widening vector conversion and a vector store**
  (`Simd[U8, 16]` to `Simd[U64, 16]`, stored into a typed slice) would
  let a loop such as std.terminal's `widen` be vector code whatever the
  optimizer does. Nothing needs it while `widen` is written in Zig
  (ROADMAP, "Zig 0.18").
- `text.ByteSet`, a byte set built once when the program runs and
  searched with `set.find(s, at)`: the run-time sibling of
  `text.find_any[set]`. Built when a port needs a set known only at run
  time; none does yet.
- The rest of a String's appends by value. `add`'s text and values
  (`appendFixed`, `addValueOf`) still pass the String's address out of
  line, so a loop of `!s.add(..)` keeps its fields in memory as pushes
  did before growth by value (a mixed `add` and `push` loop measured
  the same on main and with it). `Table`'s committed growth and the
  Map's entry growth (`resizeEntries`) have the same shape. Each needs
  the print size guard, bench/hash, and std.json.
- Lengths known to LLVM can cost a register. With growth by value, a
  List a function fills to a constant length has that length as a
  constant, and in bench/hash's HashMap `text_miss` LLVM builds the
  loop bound (100,000) with two instructions on every lookup rather
  than holding it, 2 to 3% slower on the Mac (8.61 against 8.80-8.90
  cycles a lookup); the Map's code is the same. No change to the
  runtime holds the bound without taking a List's address again.
- fasta's plain port folds its probability tables only by chance: on
  main a `--release` build computes the cumulative sums at compile time
  and compares against constants, but with growth by value it loads
  them each draw (9% more cycles on the Mac), and with the two tables
  declared after the first section's `repeat` neither main nor the
  branch folds them (6.89 and 6.86G instructions). Keeping the tables
  in registers without the fold would need them proven uncaptured
  across the String's calls; Zig's fast mode is unaffected.
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
  `loop` whose only exit is a `return`; the unwrap would replace it.
- `Map.ensure`, `Map.put_new`, and `Set.add` taking a `?K` and cloning
  the key only when it is stored (owner approved), since `+k` of a
  `?K: Clone` clones in a generic body; the three take an owned `K` today.
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
  as a capture. In `sub poke(c: *Cell[Int])`, `!c.set(2)` lends the
  Cell `c` holds, while `f = |!c| !c.set(3)` is "cannot lend parameter
  `c` to write". So is `!o.h` for `o` an owned parameter. Decide whether
  a capture and a field lend, like `!c`, lend what the handle holds.
- **A Map's value in its key's tail padding.** An ordered `Map`'s entry
  is `{key, value}` in Zig's layout, so a value that would fit the
  key's tail padding still pads the entry. Read from Trig's layouts it
  saves about 0.3 MiB on ts-pattern alone, and 4 MiB (1.7% of peak RSS)
  if Trig also narrows the instantiation owner to a U32. The entry must
  lay out the key's fields and the value side by side and hand keys out
  by value or field by field, since an assignment of a whole key may
  copy its padding. It waits for a round on the entry's layout
  ([records](../history/records/2026-10/perf-stage/tail-padding.md)).
- **A small optional result through memory stalls x86-64.** std.text's
  out-of-line search returned `?usize`; Zig wrote its two fields apart
  and the caller read them whole, so every match on x86-64 stalled on a
  failed store forward (a 3-byte needle in 16 bytes 54% slower than
  `std.mem.find`), while aarch64 did not show it. Returning a plain
  index with `maxInt` for none fixed it (#869). Rig's emitted `?T`
  results of functions LLVM keeps out of line may meet the same stall:
  count them in Trig's x86 profile (blocked loads by store forwarding)
  before deciding anything.
- **A large optional result of a direct call goes out by value.** An
  API object's table entry whose result is an optional wider than three
  words writes it through the caller's place (INTERNALS, "APIs and API
  objects"); a direct call, `Sphere.hit` or a witness's method, still
  returns it, and a miss that is not inlined writes the whole undefined
  payload. Doing the same there changes the Zig signature of every such
  function, which each use of it as a value follows: a witness's
  member, `rig.selfArg`, a table entry, a closure, a task, and a call
  Zig evaluates at compile time. ray.rig gains nothing (its `hit` is
  inlined, and `Material.scatter`'s `Scatter?` is too); it waits for a
  program whose large optional result crosses a call LLVM keeps, with
  the entry's numbers as the guide: 9% to 25% fewer cycles from 25
  bytes with a niche, a fast build.
- **A closure that stores nothing, at a value type that can hold a
  view** (deferred by the owner). `!m.update(|k, v| v = none)` on a
  `Map[String, (?String)?]` is refused with its instance (SPEC "Generic
  bodies"): the rule reads the function value's type, not the closure.
  A refinement would check a closure literal's body, or a declared
  function's, at each call, and discharge the requirement where it
  stores and gives no view of a parameter; it would accept that call,
  `retain(|k| k.len == 5)` on a `Map[?String, ?String]`, and
  `update(|k, v| v = "lit")`.
- **Seeded runs never use the "run next" slots.** With `RIG_SEED`,
  `sched.wakeIn` appends every woken fiber to the one ready list, so
  `seeds: 20` covers none of the slots' paths: the circle's displacement
  of the oldest, the streak limit, `handoff` from a slot, and a thief's
  take of the oldest. Only `test/cli/run_next_lost.sh` and
  `run_next_fair.sh`, real runs on several workers, catch a lost or
  starved fiber there, and not the same way twice. Model the slots in a
  seeded run: each simulated worker keeps its own circle and ring, the
  seed picks which worker runs and when one steals, so a fiber lost or
  left waiting fails under the same seed every time. Source: Rig,
  reviewing #1001.
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
- **A result that views a `for` element cannot outlive the turn.**
  `for b in balls` (or `for b in ?balls`) over a `List[Ball]` whose
  `Ball` copies, then `best = ?b.hit()` with `fun hit(?@) -> Hit from @`,
  is rejected: "`b` does not live long enough ... `b` goes out of scope
  while `best` still views it". The first error's hint, `?b.hit()`, gives
  the second. Indexing, `best = ?balls[i].hit()`, runs, and so does a
  loop over `List[^Ball]`; Rust accepts the loop over `&self.list`. The
  rejection is sound for the Zig emitted, since a copyable element is
  bound by copy (`for (balls.items()) |b|`). Accepting it takes two
  changes: the loop binds a view of the element (`|*b|`) where a view
  of `b` leaves the turn, decided once in storage, and the ownership
  checker gives that view the loan on `balls`, as CORE's "`for x in ?v`
  reads each element in place" says. Found porting Rust (2026-10-29;
  probe in the Rust-ports notes, `r1-view-from-loop-element.rig`).
- **A write call's result as an assignment target keeps the long
  form.** `(!a).at_mut(i).n = 1` is accepted and `!a.at_mut(i).n = 1`
  does not parse ("unexpected `=`"): a statement that starts with `!`
  is an expression, not a place. The paren rule writes every other
  used write call short; decide whether an assignment's target should
  take the short form too. Trig has 60 such sites (2026-10-29).
- **Literal arithmetic given a read view is refused.** `f(4 + 1)`,
  where `f` takes a `?Int`, says "type mismatch: expected `?Int`, got
  `Int`", while `f(4)` and `f(x + 1)` are lent as made values. Literal
  arithmetic checked against a view should be checked against the
  value it views. Found with the errors-only fixes (2026-10-29).
- **A `?^T` field cannot be filled from a parameter.** A
  parameter `?^T` is rejected (SPEC "Box"), but a field or a result of
  type `?^T` stays, and a `?T` parameter is no `?^T`. Decide whether a
  read view of a box is rejected wherever it is written, or a `?T`
  given a box may be held as one.
- **An object's own optional in its fields is rejected, not built.**
  `kids: List[Node?]`, `prev: ?Node?`, and `^(Node?)` in `obj Node`
  (or in a payload of `enum Node`) are
  refused (sema `checkOptionalLoops`), since `rig.Opt(Node)` asks Zig
  for `Node`'s layout while `Node` is laid out. A layout chosen lazily,
  inside a struct whose fields Zig resolves later, would let them
  compile; measure what it costs every object's optional first. Found
  with the port bugs (2026-10-29).
- **A write view of an array is no read slice.** A `![4]U8` passed
  bare where a `[]U8` goes is rejected ("type mismatch: expected `[]U8`,
  got `![4]U8`"), though a `![]U8` reads as the `[]U8` it views and a
  `?[4]U8` lends its elements there. It is sound, only stricter: decide
  whether a write view of an array lends its elements to read, as `?a`
  does, and otherwise name the form to write in the message (`?k` or
  `?k[..]`). Found with queue row 29 (2026-10-31).
- **A payload test on an error's member never lowers.** `.bad(l?)` or
  `.bad(none)` in a `match` on an error of a set whose `bad` holds an
  optional field passes `rig check` and fails in Zig (`type 'anyerror'
  does not support field access`), with `_` for the rest or not; on a
  union of sets emit reports "cannot emit this payload pattern". Lower
  it, or reject it with a message, and then let such tests cover a
  member as they cover an enum's variant (SPEC "Testing a pattern").
  Found reviewing #923 (2026-11-04).

Found while writing the Learn Rig journeys. Check each before fixing.

- **The shorthand `c.area()` does not see through a box,** though the
  type's own methods do (`b.area()` on a `^Square`); `b.describe()`, a
  default, says "no method `describe` on type `Square`". Decide whether
  a box takes the shorthand, and name the API in the message either way.
