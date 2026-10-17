# Formal Rig: what parity with Rust takes

Rust's ownership model has had ten years of expert attack and a
machine-checked proof. This page lists what Rig needs to stand beside it
in two senses: **assurance**, meaning a safety claim as trustworthy as
Rust's, and **reach**, meaning the programs Rust can write and Rig cannot
yet. Its main idea is that some of Rust's features are best left out.
Leaving out a feature that is hard to prove sound does not just remove
work. It removes the place where the bugs live, so the verification
problem **dissolves** instead of being solved.

This page is a plan, not a description of the compiler. What is built is
in [CORE](../../docs/CORE.md) and [SPEC](../../SPEC.md). What Rig takes from Rust and
what it leaves, feature by feature, is in [RUST-TRIAGE](../../docs/RUST-TRIAGE.md);
this page builds on it and says where it should change. It comes from a
panel of six reviewers (Rust soundness, formal methods, types and traits,
systems and foreign code, concurrency, simplicity and assurance),
2026-10-16.

## The bar Rust sets

- **What is proved.** RustBelt (POPL 2018) defines λRust, a model of
  Rust's core with explicit lifetimes, in the Iris logic in Coq. It
  proves that the model's type system is sound. It also proves that
  models of `Arc`, `Rc`, `Cell`, `RefCell`, `Mutex` and others are
  semantically well typed, so their `unsafe` code upholds the safe
  rules. Along the way it found a real bug: `MutexGuard` was `Sync` when
  it should not have been (#41622).
- **What is not proved.** Nobody has proved that `rustc` matches λRust,
  and LLVM is trusted. Most of the standard library is not modeled. That
  part of Rust's trust rests on Miri, which runs programs under an
  aliasing model and stops at undefined behavior; on crater, which builds
  every public crate before a release; on fuzzing; and on a decade of
  users. Rust also ships with known soundness bugs, which its tracker
  labels `I-unsound`.

So parity has three parts:

1. a proof that the model is sound;
2. a proof that each piece of trusted code upholds the model;
3. evidence that the compiler does what the model says.

Rig can do better than Rust on the third part, because its checker is
small and it compiles whole programs.

## The strategy: dissolve, don't solve

Most of RustBelt's difficulty, and most of Rust's soundness bugs, come
from a few features:

- lifetime parameters and variance;
- open-world `unsafe` code that mixes raw pointers with references;
- guards whose `drop` is what keeps the program safe;
- values that point into themselves;
- specialization.

Rig's rules already leave most of these out. The plan keeps six
principles:

1. **Views are second-class.** A view lives in a local, a parameter or a
   result, and its loan is checked where it is used. There are no
   lifetime parameters to quantify over, and no variance.
2. **Ownership is checked per instance, over the whole program.** A
   generic body is checked at each instance, so the proof needs no
   polymorphism. Rig needs no coherence or orphan rules.
3. **Unsafe code lives in Zig, never in Rig.** Rig has no raw pointers.
   Code that needs them is a Zig-backed declaration with a Rig
   signature, and each such declaration is proved on its own.
4. **Safety never rests on a drop running.** A cycle of `*T` handles can
   leak, as in Rust (#24292). A task group ends when its closure returns,
   never in a guard's drop.
5. **The Core has a budget.** The rules a proof covers are capped at 12
   rules and 600 words. A new rule retires an old one, or changes the
   Core through its own process (CORE §10). For comparison, the "ten
   sentences" of CORE §2 run to about 1,600 words today.
6. **Concurrency is tasks and channels.** A program spawns tasks in a
   group and passes values between them on channels. Threads, fibers,
   `Pin`, async functions, and atomic orderings are how it runs, not
   what a programmer writes.

## Leave out, and it dissolves

Each entry gives the Rust feature, what leaving it out removes from the
proof, and how a Rig programmer copes without it.

| Rust feature | Removes from the proof | How Rig copes |
|---|---|---|
| Lifetime parameters, variance, higher-ranked bounds (`for<'a>`) | Lifetime inclusion and the variance bugs (#25860, #84591) | Loan sets, `from` and `keeps` |
| Subtyping under `!` or inside a container | Writing a wider type through a narrower view | `^C` becomes `^Tr` only at a value's top level |
| Associated types and generic associated types | Type projection and normalization | Trait type parameters. Lending iterators already work (below) |
| Specialization | Overlapping impls (#40582, #31844) | Fast paths come from kind facts |
| Blanket impls, `impl Trait` results, auto-trait leakage | Global reasoning about impls | A generic function, a named type, or `^Tr` |
| Trait objects of traits that are not object-safe | #57893 | Every trait is object-safe by its shape: no generic methods, no `Self` but the receiver |
| The `Fn` / `FnMut` / `FnOnce` hierarchy | Reentrant closures that write their captures | An owned closure's environment never changes. A stack closure that captures a write view cannot reach itself |
| `Pin` and self-referential values | #66544 and the `Pin` API | Not needed at all (below) |
| `#[may_dangle]` | The drop-check escape hatch | A drop reads the views a value holds only if its type has a `drop` body |
| Raw pointers, `transmute`, inline asm, untagged unions in Rig | An aliasing model for user code | Zig-backed declarations in trusted packages |
| Guards whose drop keeps the program safe | #41622 and leaked join guards (#24292) | A task group that takes a closure |
| Threads as a concept, detached `spawn`, thread-locals | `'static` bounds, orphan threads | Tasks spawned in a group that always ends; pass a context |
| Async functions, futures, and function coloring | Futures that point into themselves | A task runs on its own stack, which never moves; code stays straight-line |
| `Mutex`, `Arc`, atomics, and their five orderings | Shared mutable state, and a weak memory model for user code | Channels that move values; a task that owns state answers messages; added later only if measured |
| `mem::forget` as safe | Leaks counted as safe | A leak is a compiler bug, except a `*T` cycle |
| Macros, editions, compile-time type functions | Checking code that does not exist until expansion | Libraries in userland; a migrator for each breaking release |

Lending iterators need no associated types. A method's result can be a
view `from self`, and `for` lends the iterator to each step:

```rig
obj Windows
  buf: List[Int]
  i: Int

  fun next(!self) -> ([]Int)? from self
    return none if self.i + 2 > self.buf.len
    self.i += 1
    ?self.buf[self.i - 1 .. self.i + 1]

sub main()
  b: List[Int] = List()
  !b.push(1)
  !b.push(2)
  !b.push(3)
  w = Windows(buf: <b, i: 0)
  for s in !w
    print(s[0], s[1])
```

```output
1 2
2 3
```

## Pin is not needed

Rust pins a value for four reasons. Rig meets each one without it, so
the reserved pin sigil `@x` gets no rules and no proof. It stays reserved
until tasks and channels are built.

| Why Rust pins | Where it goes in Rig |
|---|---|
| A future keeps views into its own frame, and the frame may move | A task's frame is on its own stack, a thread's now and a fiber's later, and that stack never moves |
| A value points into itself | "A value never holds a view of itself"; arenas with IDs |
| An intrusive list needs nodes that keep their address | Written in trusted Zig, as std's channel keeps its waiters |
| C or the operating system holds an address | `^T`: moving a box moves the handle, not the value it owns |

## What to build for reach

These come in rough order. Sizes are rough too. The rounds RUST-TRIAGE
already plans (field loans, `keeps`, path tokens, partial moves, errors
that carry data, `yields !T`) stay as they are.

1. **Static traits with default bodies (round R2).** Bounds such as
   `[T: Hash]`, and default method bodies, because tsc's visitors need a
   no-op for every node kind. A default body is a generic body with
   `Self: Tr`. Iterators as values come from `trait Iter[T]` here, not
   from `*fun` adaptors. About two weeks.
2. **Generic `drop`, and arrays of owning values in generic code.** Today
   a `drop` body is allowed only on a non-generic object, and a generic
   object cannot keep a `T` that owns a resource in an array. Both are
   needed for small-vector storage. About a week.
3. **Trait values with downcast (round R3).** `?Shape` and `^Shape` as
   values, and `if s as Circle c`. GPUI's element tree and tsc's `Any`
   need them, so this is a must for parity. It is specified as a
   closed-world enum: a trait value is a variant, a call is a match, and
   a downcast is a match. It needs no new typing rule. About three weeks.
4. **Tasks and channels.** Concurrency free of data races, with nothing
   for users to learn but a group, a task, and a channel:
   - **A task group** ends when its closure returns, after every task
     spawned in it has finished; cancellation reaches every task, and no
     task outlives its group. A **local** group runs its tasks on one
     thread, so they may capture anything, `*T` and `Cell` among them;
     GPUI's foreground tasks are this case. A **parallel** group spreads
     them across cores.
   - **Channels** carry values by moving them, `ch.send(<msg)`. The
     sender cannot touch a value it sent, and a view is never sent, so
     tasks share no mutable state. A `select` waits on several channels.
   - **Two facts** decide what a parallel task may capture or send:
     *moves*, meaning it may move to another thread, and *shares*,
     meaning two threads may read it at once. A `?x` capture needs `x`
     to share; `!x`, `<x` and `+x` need it to move, and so does a value
     sent on a channel. A Rig object's facts come from its parts, as its
     kind does (CORE §1). Each Zig-backed type *declares* both, with no
     default, because deriving them for a library type is how #41622
     happened. `*T`, `~T`, `*fun`, `Cell` and `Signal` do neither.
   - **The engine is Zig's.** Zig 0.17's `std.Io` has futures, groups,
     queues and `Select`. Rig adds the surface and the rules, not a
     scheduler. In Zig 0.17.0 only its threaded backend works: each task
     is an operating-system thread, cancellation is prompt, and the
     system's thread limit caps how many tasks run at once (about 8,500
     on macOS and 97,000 on Linux in a probe). Its event-loop backends,
     on io_uring, kqueue and Dispatch, do not compile. So tasks and
     channels are built on the threaded backend first, behind an API
     narrow enough to move to fibers, and cheap tasks by the hundred
     thousand, when Zig's event loops work.
   - **Costs.** Fibers are cooperative: a task that computes without
     waiting holds its thread, so heavy work goes in a parallel group. A
     cache many tasks write, or a hot counter, costs a message where an
     atomic step would do; `Mutex` and `Atomic` come back only if a
     measurement asks. Deadlock stays possible, as in Rust and Go. A
     parallel checker cannot share a tree of `*T` nodes; it reads one
     through `?` captures, or uses arenas with IDs. A task keeps its own
     stack, so an idle task costs kilobytes where a Rust future costs
     hundreds of bytes: the price of having no `Pin` and no async
     functions, paid in memory per idle connection, not in speed.
   - **Actors are a task and its channel.** They live in std, built on
     round R2's traits, so they add no rule to prove. The channel is the
     actor's mailbox, and the actor's address is the channel's sending
     end. A mailbox is typed and bounded, so a sender waits while it is
     full. `receive` is a `match` on the next message, taken in order;
     there is no selective receive.
   - **A supervisor** is a group that restarts a task that ends with an
     error. The task starts again from fresh state, up to a limit, and
     past the limit the supervisor fails too. A restart is safe because
     the task shared nothing and everything it owned was dropped when it
     ended. A panic stays fatal for the whole program: it means a bug,
     and Rig runs no cleanup after one. Pony is the precedent.
   - **Preemption** may come later: a countdown on each loop's back edge
     that yields when it reaches zero, kept only if the speed rule
     allows it.

   About six weeks after the probe.
5. **Trusted packages.** Only std may bind declarations to Zig with
   `extern zig` today (SPEC §15). A package that opts in as `trusted`
   may do so too, and `rig check` lists every trusted file it compiled.
   With it come:
   - **Zig-backed types** (`obj Window owns`): each declares its kind,
     drop, clone and thread facts. A window, a GPU buffer or a mapped
     file becomes an owner that lends `from self`.
   - **Objects with C layout and C-callable `export` subs**, for
     callbacks from C. A `void*` context stays in the Zig shim.
   - **An "every bit pattern is valid" fact** for plain objects with C
     layout and no `Bool`, enum or padding. With it, `[]U8` can be read
     as `[]T`, with alignment checked. It replaces `transmute`.

   About six weeks.

**What this reaches.** A tsc port needs items 1 and 2 and the rounds
RUST-TRIAGE already lists. A GPUI-class engine needs all five.

## Assurance: four stages of proof

| Stage | What | Size |
|---|---|---|
| 1 | The Core as paper rules, within the budget | weeks |
| 2 | λRig and an executable semantics in Lean 4 | 5–8 person-months |
| 3 | Soundness of λRig, and a check of every compiled program against it | 16–30 person-months |
| 4 | A proof for each Zig-backed declaration | 6–12 person-months |

**Stage 1: paper rules.** The Core's rules are written as rules, each
small enough to state formally, within the budget above.

**Stage 2: an instrumented interpreter.** λRig is the core of the
reference checker (`test/oracle/`), restated in Lean. It covers:

- objects, optionals, `List` as a primitive buffer, and `^ * ~`;
- `Cell`, views, slices, paths, drop flags, `defer` and `e!`;
- first-order functions with `from` and `keeps`, `?fun`, and `*fun`
  that holds no loans.

It leaves out syntax, generics, modules and text. Its semantics is
an interpreter that tags every view with its loan. Writing an owner
kills its read tags, and using a dead tag stops the program. It runs the
suite, the corpus and the matrix. It catches what the sanitizer cannot:
a read view that sees its owner change when nothing was freed (CORE §4).
It replaces `bin/rig-oracle` over time rather than becoming a third
checker. Its first slice is built: [`formal/`](../README.md) has λRig
with boxes, plain numbers and views, and a proof that no step of the
interpreter leaves a place with read loans and a write loan at once. A cheaper version of the same check also goes into the emitted
code (`RIG_SANITIZE=views`): each owner counts its writes, and a view
checks the count it was lent at on every read.

**Stage 3: soundness.** Progress and preservation for λRig over that
interpreter, in the style of Oxide (Weiss et al., 2019). The proof must
show:

- the `from` and `keeps` summaries are sound, which is the crux;
- a drop body reads only the views its value holds;
- no loan enters a home that holds none;
- no value views itself;
- every way out of a scope reports the loans it ends;
- each check the compiler omits as proven really holds;
- for trait values, that their desugaring adds no rule;
- for parallel task groups, freedom from data races.

Iris treats values as droppable at any time, so it cannot prove Rig's
leak claim. That part needs Iron (Bizjak et al., POPL 2019) or explicit
heap accounting, and it adds 3–6 person-months.

The same stage links the compiler to the proof: `rig check --facts`
exports each function's loan sets, and a small validator in Lean checks
them against λRig's rules for every program compiled. This is one
mechanism, built once. Rust has no such link.

**Stage 4: trusted code.** Each Zig-backed declaration in std, the
runtime, and every trusted package is proved to inhabit its Rig
signature's semantic type:

- it consumes what is moved;
- it keeps no view outside its `keeps`;
- a `from` result points only into that owner;
- its drop frees exactly what it owns;
- its declared thread facts hold.

The task group and `Channel` are proved in a logic for weak memory
(iRC11); user code never needs one. Because Rig has no raw pointers, this is one lemma per
declaration, about 6–12 person-months, not the 36–60 an open-world proof
like RustBelt's would take.

## Assurance beyond proof

Rust's trust comes as much from machines that attack it daily as from
its proof. Rig already has:

- every program run under the sanitizing allocator;
- the reference checker;
- the generated grids (`test/matrix.py`);
- the corpus of reviewer probes;
- the merge gate.

It adds:

- **A fuzzer against the reference checker.** It turns accepted corpus
  programs into near misses: a sigil dropped, a write placed between a
  lend and its use, a header nested. The checkers must agree, and every
  accepted program must run sanitizer-clean. Three to five weeks.
- **A crater of its own.** Trig, `std.json`, and every example are built
  and run on every release candidate.
- **An `unsound` label.** A soundness bug gets a `test/known` test
  within a day, a named class, and its siblings checked. No release
  ships with one open.
- **A stability promise.** A soundness fix may break programs, as
  Rust's RFC 1122 allows. Every break ships with a migrator, like
  `tools/migrate-0.3.py`. Rig has no editions: in whole-program builds
  they would cost much and buy nothing.
- **`noalias` waits for stage 2.** Telling Zig that write views do not
  alias turns a checker bug into a miscompile, so it comes only after
  the interpreter can catch such bugs. Rig needs no separate aliasing
  model like Miri's, because without raw pointers its loan rules already
  are the aliasing model.

## The trusted base

What a proof of λRig does not cover is trusted:

- the Zig compiler and LLVM;
- `src/emit.zig`;
- `src/runtime.zig`;
- std's Zig code;
- the Zig code of trusted packages.

Stage 4 covers the last three. The rest gets narrower in two ways. First,
the Zig subset `emit` uses is written down, and the emitted code is
linted against it. Second, compiled programs' output is compared with
the interpreter's. `--release=fast` turns checks off by request, so it
lies outside the claim.

## Changes this implies for RUST-TRIAGE

- **The machine-checked proof** moves from "Might want" to "Should add
  soon" for stages 1 and 2.
- **Concurrency** is task groups and channels, not scoped threads,
  `Shared`, or async. It needs both thread facts, though not as traits:
  derived for Rig objects, declared for Zig-backed types.
- **The narrow raw-pointer facility** is replaced by trusted packages
  with `extern zig`.
- **Default bodies** join R2, and **R3** becomes a must for parity.
- **Iterators as values** come from an R2 trait and `yields`, not from
  `*fun` adaptors.
- **`noalias`** waits for stage 2.
- **"Don't add" grows** by the rows of the table above that it lacks.

## Open decisions

The panel split on these. The default comes first in each.

1. **Unsafe code:** Zig in trusted packages, and no raw pointers in Rig.
2. **Module mutable state:** left out; pass a context, as GPUI passes
   `cx`. The alternative is a plain module `var` that is never lent.
3. **Allocators as owners:** left out for now; arenas with IDs. Revisit
   when a GPUI port measures the need.
4. **Iterator adaptors that may only be parameters, locals or results:**
   left out; write the loop, or use `yields`.
5. **The Core budget** of 12 rules and 600 words.
6. **The Lean interpreter** replaces `bin/rig-oracle` instead of being
   added beside it.

## Next step

The probe of `std.Io` is done (What to build for reach, item 4). Next is
the design round for tasks and channels on the threaded backend, and a
new probe of Zig's event-loop backends at each Zig release.
