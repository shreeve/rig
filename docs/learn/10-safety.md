# Safety you can trust

Here is a C program that compiles without a warning:

```c
char *name = strdup("rig");
free(name);
printf("%s\n", name);
```

It reads freed memory. The compiler does not mind, and a test may pass
for years before the allocator reuses the block. Rust promises to rule
this out in safe code, and backs the promise with a machine-checked
proof of a model of its core and years of attack.

Rig makes the same kind of promise, and a promise is only worth what
stands behind it. This chapter states what Rig guarantees, marks the one
place where the guarantee is yours to keep, and shows what checks the
claim: the debug build, a second checker, and a proof in Lean. It ends
with what none of them covers.

## Six promises

The compiler's guarantees are written down in [AGENTS](../../AGENTS.md)
as rules that do not bend. They are about the compiler, not the process:

| Promise | What it means for you |
|---|---|
| Accept means correct | If `rig check` accepts a program, the Zig it writes compiles, runs, and does what the source says. What it cannot lower, it rejects with a Rig error. |
| Safe code cannot corrupt memory | Use after move, double free, use after free, dangling views, and leaks are compiler bugs, not program bugs. Only `raw` code may break this. |
| Effects stay visible | No feature hides a move, a clone, an allocation, a failure, or a mutation. Each sigil is a named step in the compiler's tree. |
| One classifier per fact | Whether an expression is a place, a made value, a lend, or a view is decided once and recorded. The checker checks what emit writes. |
| Ownership fits the Core | Every ownership rule follows from the ten sentences of [CORE](../CORE.md). |
| Docs claim only what runs | Every `rig` example in the docs is a test. |

The first two are the ones a program depends on. They have one
exception that is not a bug: a cycle of strong handles keeps itself
alive and leaks. A debug build reports it, as [Ownership without a
collector](02-ownership.md) shows, and `~` breaks the cycle.

A broken promise is a bug in the compiler, and the program that shows
it is kept as a test. Here is a program the compiler refuses, because
accepting it would break the second promise:

```rig reject
sub main()
  b = ^1
  r = ?b
  <b
  print(r)
```

```error
cannot drop `b` while it is lent
```

`r` views the box in `b`. Dropping `b` frees the box, and `print(r)`
would read it. Hold on to this program, because two more things below
judge it independently.

## The one place the promises are yours

`raw` is the boundary of what the checker guarantees. Inside it, and
only there, a program may call one of Zig's builtins, such as a bit
cast, or call a C function declared with `extern`:

```rig
fun bits(x: Float) -> U64
  raw
    $bitCast(x)

sub main()
  print(bits(1.0))
  print(bits(-2.5))
```

```output
4607182418800017408
13836183955189006336
```

`$bitCast(x)` reinterprets the eight bytes of a `Float` as a `U64`.
The compiler cannot tell whether that is what you meant, so it asks you
to say `raw` first. The block yields its value, and a safe function
wraps it. That is the intended pattern: the caller of `bits` writes no
`raw`, and one function holds all the trust.

The same holds for C. A call to an `extern` function is rejected
outside `raw`:

```rig reject
extern fun abs(n: I32) -> I32

sub main()
  print(abs(-5))
```

```error
call to extern function `abs` requires `raw` block
```

Only integers, floats, and `Bool` cross into C.

Notice what `raw` does not do. It does not switch the checker off.
Everything else inside the block is still checked, so a use after a move
is rejected there too:

```rig reject
sub show(xs: List[Int])
  print(xs.len)

sub main()
  xs = List([1, 2])
  raw
    show(<xs)
    print(xs.len)
```

```error
use of `xs` after move
```

So `raw` widens what you may write by two things, Zig builtins and C
calls, and the checker takes your word for each. Search your program for
`raw` and `extern`, and you have found every spot where the first two
promises depend on you.

## What a debug build checks

`rig run` builds in Zig's debug mode with several checks on. They catch
what the compiler's checks might miss, and what `raw` code gets wrong:

```rig
fun pick(xs: ?List[Int], i: Int) -> Int
  xs[i]

sub main()
  xs = List([10, 20, 30])
  print(pick(?xs, 2))
  print(pick(?xs, 3))
```

The first call prints `30`. The second asks for an index the list does
not have. The suite checks this program but does not run it, because a
panic's stack trace names paths on your machine. Run it, and stderr
shows the panic and Zig's trace, shortened here:

```text
$ rig run pick.rig
30
panic: index out of bounds
.../rig/runtime.zig:2036:33: in index (__rig_main)
    if (idx >= count) indexPanic();
...
error: rig: the program was killed by signal 6
$ echo $?
134
```

The program never reads past the list. It stops at the access, with
status 134, which every panic has. Four checks work this way:

| Check | What it catches | What you see |
|---|---|---|
| Bounds | an index or slice outside its list, string, or array | `panic: index out of bounds` |
| Overflow | an integer operation that does not fit its type | `panic: integer overflow` |
| Conversion | a numeric conversion whose value does not fit | `panic: integer does not fit in destination type` |
| Leaks | memory still allocated when `main` ends | `error: rig: memory leak detected: ...`, status 1 |

A cast in a `raw` block is a conversion like any other: `$intCast(300)`
to a `U8` panics instead of wrapping. Built with `RIG_SANITIZE=1`, a
program also gets a fifth check. Each block of memory has pages of its
own, a free makes them inaccessible, and no address is used twice, so a
use of freed memory crashes at the access instead of printing a stale
value. The test suite sets it for every program it runs.

`--release` keeps bounds, overflow, and conversion, in Zig's safe mode.
`--release=fast` drops the overflow and conversion checks by request, so
there an overflow is undefined behavior. That mode is outside the
guarantee.

A check at run time says nothing about paths no test took. It is a net
under the compiler, not a substitute for it.

## A second opinion

A bug in the compiler's ownership checker, `src/ownership.zig`, would be
a bug in the guarantee, and tests written by its authors may share its
blind spots. So Rig keeps a second ownership checker, `bin/rig-oracle`,
built from `test/oracle/`.

It is written from the ten sentences of CORE and the ownership sections
of SPEC, without reading the production checker, and a lint in the suite
fails if it uses any of the compiler's own ownership classifications. It
lowers each function to a small form with every temporary and the order
of evaluation written out, then follows moves, loans, and drops through
the control flow. Each function gets a verdict, accept or reject with
the rule broken, or none when it uses a form the oracle does not model.

Here it is on the program from the first section, with the compiler's
verdict beside its own:

```text
$ bin/rig-oracle -v drop.rig
drop.rig main prod=reject ref=reject C4 4:3 cannot move `b` while a read loan of it is live (L0, carried by `r`#3)
```

`prod` is the compiler and `ref` the oracle. Each rejects the program,
and their wording differs because each wrote its own message.

The suite runs the oracle beside the compiler over every behavior and
rejection test, every doc example, every example program, and a
generated grid of each expression form in each context for each kind of
type. This is a differential run, with two outcomes that matter:

- **The compiler accepts what the oracle rejects.** That may be a hole
  in the compiler, so the run fails. It can never be allowlisted.
- **The compiler rejects what the oracle accepts.** The difference is
  recorded with its reason: the compiler is stricter than the Core, the
  oracle is less precise, or the Core does not decide it. A recorded
  difference that disappears also fails the run, so the list stays true.

The oracle's own rejections are listed in `test/oracle/rejections`, one
function a line. A rejection missing from the list fails the run, and so
does a listed one the oracle stops making, so a change that quietly
weakens the oracle shows even when the compiler is unchanged.

Two checkers can share a blind spot, which is why the oracle is written
from the rules and not from the code. Where they disagree, one of them
has a bug, and the disagreement finds it.

## A proof in Lean

Tests and a second checker show how the compiler behaves on the
programs we tried. A proof speaks about every program. The `formal/`
directory holds λRig, the ownership model's core in Lean 4, with an
interpreter, an ownership checker, and a proof about them.

The first slice of λRig is small. Its values are plain integers and one
kind of owner, a box holding an integer. Its forms are a name, a move
`<x`, a clone `+x`, a box `^e`, the lends `?x` and `!x`, assignment,
`+`, `print`, sequencing, and a scoped binding. The interpreter runs a program and tags every view
with the loan it was lent under. It checks the tag on each use and stops
at the first broken promise: a use after move, a use after free, a view
used after its loan ended, or a leak at the end.

The program from the first section, written in λRig, is one of eleven
that the repository keeps, each with whether the checker accepts it:

```lean
/-- Rejected: a view outlives the box it sees. `b = ^1`, `r = ?b`,
`<b`, `print(r)`. The drop ends the loan, so the run stops at the dead tag. -/
def dropWhileRead : Expr :=
  letIn "b" (box (lit 1)) <|
  letIn "r" (lend .read "b") <|
  drop "b" ;; out (name "r")

#guard !accepts dropWhileRead
```

`accepts` is the λRig checker, and the `#guard` makes `lake build` fail
if it ever accepted this program. Run anyway, it stops at a dead tag:
the view `r` is used after its loan ended. Four of the eleven are
accepted and run clean. Each of the seven rejected ones stops at the
fault its rejection prevents.

The theorem is `accepts_runs`:

```lean
theorem accepts_runs (e : Expr) (h : accepts e = true) :
    ∃ out, run e = .ok out
```

In prose: if the checker accepts a program, running it ends without a
fault and with nothing left allocated. `run` reports a fault for a name
used after a move, a cell used after it was freed, a view whose loan
ended, a step with no meaning, and a leak at the end, so `.ok` rules out
each of them. It holds for every program the checker accepts, whatever
the program. A `#guard_msgs` in the source pins the proof's axioms to
Lean's standard three, so no step is assumed. It is the λRig form of the
second promise, for this slice.

The proof covers the Core's first six sentences, each by the fault it
rules out. Sentences 5 and 6 are the loan rules: any number of read
loans or one write loan, and a loan lasts until the last use of the
views that carry it. A second theorem, `Keeps.eval`, shows that every
cell of every state the interpreter reaches holds read loans or one
write loan, never both. That shows the machine means sentence 5 the way
the Core states it, and it says nothing about the checker.
`accepts_runs` does.

## Waits and tasks

Two more models, in `Wait.lean` and `Tasks.lean`, cover the part of the
runtime that decides whether tasks behave. They are machines of their
own, not λRig programs, because the scheduler and not the expression
decides these facts.

`Wait.lean` models how one fiber waits and how a waker or a cancel ends
the wait: the protocol of `Wait` in `src/sched.zig`, as atomic steps.
Of every state that any order of steps reaches, five facts hold:

- at most one waker ends a wait;
- the fiber is queued at most once for it;
- once the fiber has switched away, a wait that was ended has queued it,
  so no wakeup is lost;
- a cancel that comes while the fiber sleeps in a wait it may end
  queues the fiber;
- a waker of an earlier wait changes nothing.

A script in the suite, `test/cli/wait_sync.sh`, keeps the model and the
Zig in step: it checks that the numbers match, that the functions
touching the wait's word are the ones the model names, and that each
step's checks are on both sides. A change to either fails it until the
other follows.

`Tasks.lean` models who holds each task's handle, which core each runs
on, and the values that stay on one thread, such as the `*T` handles of
[Concurrency without async](04-concurrency.md), whose count is not
atomic. Five facts follow from an invariant that every step keeps:

- every task but `main` is held by a running task, or by the result of
  an ended one held so in turn, so no task runs with no one answerable
  for it;
- once `main` has ended, no other task is left;
- two tasks that hold one value that stays on one thread are pinned to
  one core and run there, so no two cores touch it;
- a pinned task stays on its core;
- a cancel is never taken back.

The third fact is the rule behind local tasks. It holds because a task
that is not local may return no such value.

The same directory holds `Models/`, which is weaker evidence. A checker
written in Lean tries every interleaving of the atomic steps of the
scheduler's work-stealing ring and of how workers search and sleep,
within bounds. It is a check, not a proof, and it assumes sequentially
consistent steps, so it says nothing of weaker memory orderings. It does
find things: `formal/README.md` writes up one schedule for work made
into the global queue, with the variant of the protocol that passes.

## What is not proved

A proof is a claim with edges. These are the edges.

- **That `bin/rig` agrees with the Lean checker.** λRig's `check` is
  written for λRig. It is not taken from `src/ownership.zig`, and it is
  stricter in places: it rejects a bare name of a box, which Rig reads
  in place. The proof says nothing about the compiler's own checker.
  The oracle and the tests stand in for that link.
- **That the Zig Rig writes does what λRig does.** Zig has no formal
  semantics. The test suite and the sanitizer stand in for it.
- **Anything outside the slice.** The proof has no objects, optionals,
  `List`, functions, `*T`, `~T`, `Cell`, or loops. It covers six of the
  Core's sentences for integers and boxes, and tests check the rest.
- **Data-race freedom for the full model.** The task model proves its
  five facts. It leaves out task sets, actors, channels, the rule that
  dropping a handle cancels and waits, the deadlock walk, and unwinding
  to a boundary.
- **The code Rig trusts.** Zig and LLVM, `src/emit.zig`,
  `src/runtime.zig`, and the Zig that backs the standard library are
  taken as correct. Each is tested, and none is proved.

Put together, the claim is this. The ownership rules fit in ten
sentences. A checker built from them agrees with the compiler's on every
test, doc example, and generated program the suite holds. A proof shows
that the rules, for a small calculus, keep a program from faulting. A
debug build catches what slips by. None of these says Rig has no bugs.
Together they say where to look for one.

## Summary

| Question | Answer | Evidence |
|---|---|---|
| What does Rig promise? | safe code cannot corrupt memory, and accepted means correct | AGENTS, the six promises |
| Where is that yours? | in `raw` and `extern` only | the compiler requires `raw` for each |
| What if the compiler is wrong? | a debug build panics at the access | bounds, overflow, conversion, leak, sanitizer |
| Who checks the checker? | a second checker, written from the Core | `bin/rig-oracle`, run over every test and doc |
| What is proved? | `accepts_runs` for a small calculus; wait and task facts for models | `formal/`, `lake build` |
| What is not? | the link from the proof to `bin/rig`, and the Zig it writes | the list above |

**The guarantee is what the checker enforces, and everything else is
evidence for how well it does.**

## What is not there yet

The Lean model grows in slices, each keeping `accepts_runs` proved:
objects, optionals, `List`, first-order functions with `from` and
`keeps`, `Cell`, `*T` and `~T`, and loops. After those, the plan is to
run the interpreter over the suite beside the oracle, and in time to
replace the oracle with it. A validator that checks the loan facts the
compiler exports against λRig's rules, for every program compiled, is
planned too, and so are proofs for the code Rig trusts. The plan is
[FORMAL-RIG](../design/formal-plan.md).

## Where to go next

- [What it costs](11-performance.md), the next journey, follows a
  program down to the Zig it becomes and shows what it costs.
- [Tests that fail the same way twice](09-tests.md) shows how to write
  the tests this chapter leans on.
- [BEYOND-RUST](../BEYOND-RUST.md) compares Rig's checker with Rust's,
  and [formal/README.md](../../formal/README.md) lists every file of the
  Lean model.
- [Tests, internally](../internals/tests.md) describes the reference
  checker and the differential runs.
- The reference: [SPEC §15, Raw code and FFI](../../SPEC.md#15-raw-code-and-ffi),
  [CORE](../CORE.md), and
  [SPEC §17](../../SPEC.md#17-printing-and-stopping) for panics.
