# Goose, and Rig read the same way (2026-11-15)

A read-only review, asked for by the owner: Goose, a new language that
bills itself as faster than C++ and Rust, and then Rig through the same
lens. No program was built or timed for it; every number below is one
the project in question published, or one in Rig's own records. The
ideas worth keeping are in [docs/IDEAS.md](../../../../IDEAS.md), each
marked "Source: the Goose review".

## Goose

**What it is.** A memory-safe systems language by Wouter van Oortmerssen
(Lobster, FlatBuffers), begun 2026-08-30, with about 3,600 GitHub stars
at this date. It compiles to one C file, with an in-process TinyCC
backend that runs a program with no build step. It has no heap, no
garbage collector, no reference counts, and no destructors: every
dynamic value lives inline on bump-pointer data stacks that the
compiler assigns, freed when its scope ends. Secondary reports say most
of its code was written by an AI from the author's design; that was not
checked.

**Its ideas:**
- Grow-only arrays never move, so a reference to an element survives
  any number of later pushes.
- Nested variable-size data is stored inline: a record with a string and
  an array of items is one block with no pointers (29 bytes and no
  allocation, against 153 bytes and 4 allocations for its Rust form).
- Variable-size enums: an array of `Shape..` stores each value at its
  own variant's size. It can be walked but not indexed.
- Relative references: a link stored as a 1, 2, or 4-byte offset from
  the field itself, so a structure means the same at any address; it is
  saved as its bytes and loaded by one read and a pass that checks every
  tag, length, and link.
- Construction in place is a language guarantee, through any depth of
  calls.
- `checkfree fn`: the compiler must show that no bounds check remains in
  the function.
- No ownership marks at all: no move, no read or write lend, no rule
  against two writers. The compiler infers which variable bounds each
  reference and rejects one that would outlive it, specializing a
  function per case where needed.

**Its claims.** Over 16 benchmarks, 3.5 times the speed of idiomatic C++,
1.24 to 1.26 times hand-tuned C++, and 1.13 to 1.19 times the best safe
Rust (its report of 2026-10-16; the README says 1.12).

**Against the claims:**
1. Most of the gain is layout, not the language. Against C++ or Rust
   using the same layout (an arena with indices), the gap is small:
   `tree` 1.03 to 1.12 times. `sum` and `particles` are level, and
   `calc`, `lru`, and `scene` lose to Rust under MSVC.
2. The averages take the fastest Goose program per benchmark and the
   smallest per memory figure; its own report says no one program has
   all of those results.
3. One Windows machine, best of 3 whole-process runs, no core pinning,
   and benchmarks small enough to tune a compiler to, as one Hacker News
   reader suspected.

**What the design costs.** Only one growing value per data stack at a
time; values cannot move or be handed off; threads share no memory; a
reused pool slot lets a stale reference read another item of the same
type, which corrupts no memory but is a logic error that Rig's or
Rust's ownership checker rejects. Long-lived graphs with deletion and
shared ownership do not fit it.

Sources: [github.com/aardappel/goose](https://github.com/aardappel/goose)
(README, `bench/results.md`);
[zeli.app 49748954](https://zeli.app/story/49748954),
[zeli.app 50224300](https://zeli.app/story/50224300),
[zeli.app 50224100](https://zeli.app/story/50224100),
[80aj.com](https://www.80aj.com/2026/10/25/human-design-goose-language/).

## Rig, read the same way

As of main 42e4a0a (2026-11-15).

**What it is.** Begun 2026-05-11; 5,177 commits; a compiler of 128,000
lines of Zig, a std of 9,200 lines of Rig, 10,205 test cases, a SPEC of
14,500 lines and a CORE of 2,200, a Lean model in `formal/`, and one
GitHub star. Like Goose, it is written mostly by AI sessions.

**Where it is strong:**
- Effects are visible: each move, write, failure path, and task is
  marked where it happens, by ten sigil characters that mean the same
  thing in every position.
- Concurrency with no async: tasks on real stacks, no colored functions,
  schedules replayed from a seed, a deadlock that panics naming its
  calls. Starting, waiting for, and yielding tasks beat Tokio and Go by
  1.6 to 30 times.
- Verification: every doc example is a test, a second ownership checker
  written from CORE alone (the oracle), the Lean model, and 4 cases
  marked as known bugs.
- A real workload: Trig, a TypeScript checker whose output equals tsc's.
- The benchmarks page shows its losses: memory per task and `fanout`.

**Against its claims:**
1. docs/launch/benchmarks.md's Rig rows were measured in Zig's fast
   mode, which Rig no longer builds, as the page says. The README's task
   and HTTP claims rest on them until they are measured with
   `--release`.
2. Linux HTTP, 830,158 requests a second against hyper's 296,728 (2.8
   times), with the load generator on the same machine and hyper's setup
   not audited.
3. One run of each script, best of 3 to 7, on the owner's machines; no
   one outside has checked them.
4. Trig against tsrs (standing-8, 2026-11-02): slower on every project
   at one checker, by 5 to 32%, with 34 to 51% more peak memory on the
   large ones; trig#249 gained 1 to 5% since. Part of the gap is Trig's
   code, not Rig's.
5. 17.0 KiB a sleeping task on the Mac, against Go's 2.9 KiB and
   Tokio's 264 B.

**What the design costs:**
- Ten sigil characters in about 20 uses; `?` and `!` have four each.
  This is Rig's largest cost to a newcomer.
- "Fewer rules than Rust" sits beside a SPEC of 14,500 lines.
- The language still changes: the 0.2 to 0.3 renames and 14 migration
  scripts.
- "Accept means correct" has an open hole in docs/internals/backlog.md:
  a payload test on an error's member passes `rig check` and fails in
  Zig. `test/oracle/differences` has 337 lines.
- It needs Zig 0.17, before 1.0 and with an LLVM miscompile Rig works
  around, Nexus, and Bun and Rip for its tests. TLS, an HTTP client, and
  raw pointers are not built.

## The two models

Goose removes the questions ownership marks answer by narrowing what a
program may do: memory is freed only at a scope's end and never moves,
so use after move, dangling views, and invalidated iterators cannot
arise. Rig keeps moves, a heap, and tasks that share data, so its
checker must know where each move and write is, and it shows them. The
gap is narrower than it looks: Rig leaves reading unmarked, and marks
writes, moves, copies, holding, failure, and tasks. For a general
systems language Rig's model is the more capable one; Goose's speed
comes from its layouts, which Rig can take without giving up a mark.

## What Rig can take

By what it is worth for the work it costs:

1. A function that must have no bounds checks, on `src/proofs.zig`: no
   CORE change; a name from the owner.
2. A benchmarks page written by its scripts, with the next measurement.
3. A fast edit-run loop: measure what `rig run` costs on a small program,
   and whether debug builds use Zig's own x86 backend.
4. A List that never moves: a CORE paragraph, since a push would end no
   view; Trig already works around it with `Table` and `Slot`.
5. A packed sequence of variant records: std only, after a measured
   share.

Set aside: regions freed at once (the largest possible gain, but a CORE
change and a long design round), Goose's lack of ownership marks, its
no-heap model, threads with no shared memory, and multi-frame returns,
which Rig's design rules out or `e!` and actors already cover.

Checked and dropped: narrow slots. `Slot(n)` in `src/table.zig` already
takes the narrowest integer that holds `n - 1` (`u8`, `u16`, `u32`, or
`u64`).

## Open items

For the owner, each with a default:

1. Measure docs/launch/benchmarks.md again with `--release` on the Mac
   and pup, through the Rig session's pup slots. Default: yes.
2. Audit hyper's setup before the Linux HTTP figure is quoted again.
   Default: yes.
3. Propose the no-bounds-checks mark to the Rig session, with names for
   the owner. Default: yes.
4. Write the benchmarks page from its scripts, with item 1. Default: yes.
5. Measure `rig run`'s cost on a small program. Default: yes.
6. Leave the List that never moves and the packed sequence in IDEAS
   until a measurement shows a need. Default: yes.
