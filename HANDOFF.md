# HANDOFF: where Rig stands

This is the resume point for anyone, human or agent, picking up Rig
work. Read it first, then [AGENTS.md](AGENTS.md) (the rules) and
[docs/CORE.md](docs/CORE.md) (the ownership model every rule derives
from). What changed is in [CHANGELOG.md](CHANGELOG.md), and what is
planned is in [docs/ROADMAP.md](docs/ROADMAP.md). Why it was decided,
and what was measured, is in the records,
[docs/history/records/](docs/history/records/INDEX.md), whose ledger's
newest entry summarizes the latest rounds.

## Start here

A new session, human or agent, takes these steps in order:

1. **Read** this file to the end, then [AGENTS.md](AGENTS.md) (the
   rules, the map of the compiler, and how a change is made, its gates
   included), then the newest "RESUME HERE" entry of the
   [ledger](docs/history/records/ledger.md). [docs/CORE.md](docs/CORE.md)
   is the ownership model every rule derives from; read it before any
   change to the checker or the language.
2. **The speed brief.** Read
   [docs/internals/trig-speed.md](docs/internals/trig-speed.md): the
   goal and bar against tsrs, what is already known, the paths on pup,
   and what was measured and is not to be redone. The owner's standing
   preferences are in
   `~/.claude/projects/-Users-shreeve-Data-Code-rig/memory/MEMORY.md`.
   The work queue (`queue.md`, kept by Rig - Swiss) and the beat-tsrs
   list (`beat-tsrs-list.md`) are session notes outside the repository,
   in `~/Data/Code/Claude/rig/rig/`.
3. **See what is open:** `gh pr list` (drafts are being measured or
   wait on the owner), "In flight" below, and `git log --oneline -20
   origin/main` for what landed last.
4. **Work** in a worktree (`wt new NAME`, AGENTS.md "How a change is
   made"), never in the main checkout. Run `tools/basecheck BASE`
   before starting, before each gate run, and before asking to merge:
   it lists main's commits since BASE that touch the branch's files.
   Each compiler, emit, runtime, or std change passes the gates of AGENTS.md step 6, std.json's guard
   among them, and a speed change meets Trig's bar (AGENTS.md, "A speed
   feature pays for its lines").
5. **Ask the owner** what the record does not settle: a short message,
   with each decision numbered and a default for each. Only the owner
   approves a merge, a rule change, a name, or a release; an approval
   relayed by another session is not his.
6. **Leave it current.** A change updates its docs, CHANGELOG, and this
   file's status in the same PR; a session that ends adds a "RESUME
   HERE" entry to the ledger.

## Current state

- **Release:** `v0.3.0` is the latest release (Zig 0.17.0, Nexus
  2.0.0). What changed since `v0.2.9`, the renames and removed
  spellings included, is in [CHANGELOG.md](CHANGELOG.md), and
  [docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md) migrates a 0.2 program.
- **Releases:** every change, fixes included, ships in the current
  line, `v0.3.x`; an earlier line gets no further releases. Rounds land
  on `main` untagged until the next tag; its release notes include a
  migration guide for the renames (`tools/migrate-0.3.py`).
- **Branches:** `main` is the one long-lived branch. Work lands through
  short-lived branches and pull requests: plain git, with no CI,
  gates, or required checks.
- **Patterns and chains (built):** a pattern is tested with `x matches P`
  ([design/matches.md](docs/design/matches.md), #883): alternatives in
  parentheses that bind when they agree, `name?` and `none` in a
  payload, and `x as .p` rejected (`tools/migrate-matches.py` rewrites
  it). Fused iterator chains ([design/iterators.md](docs/design/iterators.md),
  #885) run as the loop they mean, with `min_by(key)` and `max_by(key)`
  (ties as Rust's: `min` keeps the first, `max` the last); a chain is
  typed stage by stage and its errors name the stage (#887); a range
  is walked by a cursor both loops continue, its inclusive end without
  overflow (#892, #895); `zip` and `enumerate` end in `count` or a `for`,
  and in `sum`, `min`, or `max` only after a `map` (#893). A clone ends a
  view before the call writes what it viewed (#888, CORE §6):
  `!@m.take(+best.key)` where `best` views `m`. On pup a `trim` written
  as a chain runs 10-13% faster than its hand loop. Deferred by the
  owner: a chain's function that can fail and `catch` on a chain, `T`
  meeting `none` as `T?` in loop and `if` values, and range values
  ([records/2026-10/chains/](docs/history/records/2026-10/chains/)).
- **Toolchain:** Zig 0.17.0, pinned in `mise.toml`. Nexus 2.0.0
  generates the parser at every build, from the sibling checkout's
  `nexus/bin/nexus` (AGENTS.md, "Workflow").
  [ZIG-0.17.md](ZIG-0.17.md) covers the Zig APIs Rig uses, and
  INTERNALS, ["Where Rig meets Zig 0.17"](docs/internals/INTERNALS.md#where-rig-meets-zig-017),
  where Rig depends on them. Its `@intCast` from a signed type to a narrower
  unsigned one miscompiles in release builds (LLVM `trunc nsw`); Rig's
  emitted Zig and runtime cast through the unsigned type of the source's
  width instead, until Zig fixes it.
- **Health:** a change lands on a green core suite (`swarm test/rig.rip`:
  the test files, the doc examples, their pending examples the planned
  Core rules, the examples, the unit tests, the oracle floors in
  `test/oracle/coverage`, the scripts of test/cli, and the probes of past
  reviews). A change to the compiler, the runtime, or std
  also passes Trig's light gate (`tools/light`, AGENTS.md step 6) before
  it merges: a debug trig on Trig's six cli projects, four ways each,
  byte-identical to tsc, in about a minute; and loco's (`rig/tools/light`
  in a loc checkout): loco built with that Rig, its output identical to
  the Rust loc's. The full suite (`swarm test/rig.rip all`, the core
  with the matrix's programs whose own Zig changed,
  built in packs), and Trig's full suite
  (`tools/full-main` on pup; the last result is in
  `/zfs/trig-pup/full/LATEST`) run before each major or minor release,
  optionally before a patch. Nothing runs on a schedule: there are no
  crons and no nightlies. A quick check takes under a minute a repo and
  a long one under ten; one that takes longer is a defect to fix. No
  case is marked `known:`; a `known:` names the failure it waits for.

## In flight

- **A thread with no alternate signal stack stops the program** (PR
  #1050, branch `runtime-hardening`): the main thread, workers and the
  blocking pool's threads exit with a message where they ran on. Level
  with main on both machines.
- **Raising the workers** (PR #1046, branch `raise-workers`):
  `task.workers(n)` after the first task raises the number of workers,
  never lowers it, for Trig, which learns its checker count once it has
  parsed. Level with main on both machines. The owner merges.
- **Dense stacks** (draft PR #1045, branch `dense-stacks`): a direct
  `f()&` whose target cannot need much stack takes a stack from one
  shared reservation, under a guard sealed after the link. Memory per
  task falls from 33.5 to 17.6 KB on the Mac and 9.1 to 5.2 KB on pup;
  `chain` and `spawn` cost a little. Packed slots build on it. The owner
  merges.
- **`task.fast_cores()`** (draft PR, branch `fast-cores`): the fast
  physical cores within the affinity mask, on macOS and Linux. The name
  is provisional, the owner's to settle; the worker count is unchanged.
- **Language review fixes** (draft PR, branch `language-review-fixes`):
  from the 2026-11-08 language review, nothing is written through a
  `!?T` (an element of `for x in !vv` over a `List[?T]`), a view of a
  module constant held in an object or array is a run-time value, and
  SPEC names the slots that make a template fixed text (Int, Bool,
  `Static`). Gates green on the Mac; the owner merges.
- **Small stacks, step 2: the cheap fixes** (draft PR, branch
  `cheap-fixes`; the panel's order is
  [records/2026-11/task-memory/small-stacks.md](docs/history/records/2026-11/task-memory/small-stacks.md)):
  free stacks shared between workers and returned in runs once they are
  idle, small-page advice on stacks, the deadlock walk on the worker's
  stack, every handler on the alternate signal stack. Shootdowns on
  bench-scale's `alloc` as tasks fall from 3,220 to 24-58 a run on pup
  at 8 workers; `spawn` is 47% faster on the Mac. Steps 1a and 1b
  (switch-first preemption, #1020, and the vector state off the stack)
  wait on #1007; step 4's census tool is next.
- **Backtick templates, T1** (owner-approved 2026-11-07; the design is
  [records/2026-11/templates-t1.md](docs/history/records/2026-11/templates-t1.md)):
  T1a, the record and pending rules (draft PR); T1b, lexing, parsing,
  the places, the `?String` buffer, and folding (draft PR, branch
  `templates-t1b`); T1c, `"""`, `'''`, and multi-line backticks (draft
  PR, branch `templates-t1c`). After T1: test files' `'''` results move
  to the closer's-column rule by a script.
- **`loop`, and loops that give no value** (draft PR, branch
  `loop-keyword`, owner-approved 2026-11-06): `loop` is a keyword and
  the one loop that gives a value; `while true`, a loop `else`, a `for`
  or `while` used as a value, and `break v` in one are rejected;
  `List.index_of`; messages for other languages' forms. It rejects
  Trig's 109 `while true` lines and loco's one, so Trig and loco run
  `tools/migrate-loops.py` before it merges.
- **The huge-page test follows the system's mode** (panel item 6): the
  allocator reads Linux's THP mode once and counts only the asking
  thread's node
  ([records/2026-11/huge-pages/gate-modes.md](docs/history/records/2026-11/huge-pages/gate-modes.md));
  no speed claim. Its Linux unit tests pass natively on x86 Linux in
  debug, safe and fast.
- **Parallel teardown at `os.exit` on the Mac** (draft PR, branch
  `exit-teardown`): a release build's `os.exit` stops the workers and
  unmaps Tables, segments and free stacks on four of them before
  `_exit`; Mac Tables take ranges of 32 GiB regions. Trig 9-18% faster
  at four and eight checkers on mitt, neverthrow and superstruct, 4-7% on
  tiny-invariant, level on zod3, ts-pattern and at one checker
  ([records/2026-11/exit/](docs/history/records/2026-11/exit/parallel-teardown.md)).
  Linux keeps its exit until parallel unmapping is measured on pup.
- **A task's maker keeps its worker** (research 29 #6): a yield check
  leaves work to an idle worker it wakes, and yields only when every
  worker is busy
  ([records/2026-11/spawn/](docs/history/records/2026-11/spawn/README.md));
  Trig's parse in waves (research 29 #4) builds on it. Its x86 timing on
  pup waits with the rest.
- **Preemption by signal** (#952), the default on x86-64 Linux and
  arm64 macOS in this change, for a program that makes tasks and no
  local task (docs/internals/scheduler.md, "Preemption"). Yield checks
  stay on other targets, in Linux debug builds, for local tasks, in
  `rig test`, and in the test runner's packs of seeded cases; its
  other packs are preempted, as each program would be built alone
  (`rig batch build --preempt`; `RIG_PACK_PREEMPT=0` turns it off), at
  no cost to the core's time on the Mac. The coverage
  gate is `test/cli/preempt_cover.sh`. On pup, signal against the
  yield checks on Trig is 1.3-3.3% faster with 3.8-4.6% fewer
  instructions at one checker, 4.0-6.4% fewer at many; fork-join's psum
  is 5 times faster on the Mac, near Rayon's; #1001 (four run-next
  slots) ended `hog`'s wait behind preempted tasks
  ([records/2026-11/preempt/](docs/history/records/2026-11/preempt/design.md)).

- **The revamp of the runtime and std**
  ([records/2026-11/revamp-runtime/](docs/history/records/2026-11/revamp-runtime/ledger.md))
  landed in three rounds, #902-#912:
  - the output lock never held across a program's `print` method;
  - panics that leave no lock, mailbox slot, or stack behind;
  - waits that park, and an edge on a socket that reaches every waiter;
  - file I/O with no lock or table, its descriptor and buffer moved
    into the pool call (`io.copy` in a task 2.2 times faster on pup);
  - one completion primitive for a task's end and an actor's answer;
  - one UTF-8 owner in std, and std.terminal's memory bounded;
  - "self" for "receiver" in the compiler.

  The owner decided the
  twelve std questions on 2026-11-04
  ([owner-decisions.md](docs/history/records/2026-11/revamp-runtime/owner-decisions.md)):
  the renames and behaviors of items 1-6, 8, 9, and 10's labels are
  built (`json.parse`, `JsonError` members with offsets, `order` for
  `compare`, BigInt's `Eq + Ord + Hash`, search by `x: ?T`, std.iter
  gone, Lemire's `random.int`, one `math.pow`), with
  `tools/migrate-std-0.3.py`; 7 and 12 stay as they are, and 11 is a
  later measurement.
- **The revamp of the compiler**
  ([records/2026-11/revamp-compiler/](docs/history/records/2026-11/revamp-compiler/ledger.md)):
  - **Phase 1, the front end and the type checker (#914-#917),
    landed.** It fixed nine accepted programs that misbehaved or crashed
    the compiler, among them three crossing holes for tasks and actors,
    and a `select` arm closure that read a dead frame.
  - **Simplifications:** ten type walks share one list of a value's
    parts; built-in type names are found through scope; compile-time
    calls have one argument check.
  - **Check speed:** `rig check` is 4.7% faster; `bench/check/guard.py`
    runs as documented and holds the new baseline.
  - **Its five decisions** were approved after a panel of three
    experts agreed with each
    ([panel-decisions.md](docs/history/records/2026-11/revamp-compiler/panel-decisions.md)).
    They landed in #922, with `select` as a value matched by `match` (#923),
    the conditional-expression binding rule (#924), and a fix for a
    check-speed regression on deep generic chains (#925).
  - **Phase 2 and the rest of v0.3.0's scope (#927-#937), landed:**
    ownership, storage, facts, and emit; the twelve std decisions
    (`tools/migrate-std-0.3.py`); a task returned with read loans;
    the `$type` rule; and by-name patterns (`tools/migrate-patterns.py`).
    Four more holes on main were closed.
  - **Next, right after v0.3.0 (the owner):** `@embed`, a task's end as
    a `select` arm, keyword durations, `as a, b` shadowing, two gaps in
    the oracle, emit's last decisions moved into storage, and the
    test/cli scripts as a gate for compiler PRs.
  - **Emit's last decisions** (branch `emit-facts`): the classifiers
    `Facts` still called are recorded decisions of the storage plan
    (`catch_all`, `match_selects`, `binds_string_bytes`,
    `hoists_results`, `through_write`, `bind_hold`, `compound_call`),
    and a `swap`'s kind is typecheck's record; a unit test holds
    `Facts` to reading records.
- **`select` as a value matched by `match`**, approved and built as
  a test case (records/2026-11/revamp-compiler/panel-select-*.md):
  `match task.select(add: !a.on_recv(), late: time.after(ms: 50))!` with
  arms `.add(v?)`, `.add(none)`, `.late`. A compile-time function that
  builds types may later replace `sema.selectType` without changing
  what programs write. The closure arms are the old spelling for this
  release (`tools/migrate-select.py`). A task's end is an arm too,
  built: `done: ?t.on_end()` lends `t`, its variant carries nothing,
  and the body takes the result with `>t`; two task arms are a race.
- **Durations** (owner, 2026-11-04; branch `durations`), built: a bare
  number is seconds, an `Int` or a `Float`, and `ms:`, `us:`, `ns:`
  name the other units, in `time.sleep`, `time.after`, `time.within`,
  `Instant.at`, and `t.add`; `per:` is seconds. It changes what a
  0.3.0 program means, so `tools/migrate-durations.py` rewrites one
  (MIGRATING-0.3, "From 0.3.0 to 0.3.1"), and Trig and loco get its
  note before it merges.
- **A ternary's condition binds names** (owner, 2026-11-04), built:
  `v.id if r.decl as v else 0` and `r * r if s matches .circle(r) else
  0`, the names visible in the value before `if` only (SPEC, "Block
  expressions"). A postfix guard still binds none.
- **`$embed(path)`** (owner, 2026-11-04), built: a file's bytes as a
  `Static`, read when the program is compiled, from the directory of the
  file that names it and inside the program's directory (SPEC
  "Builtins"). `rig check` opens the file and reads none of it; the
  package holds a copy at `__rig_embed/PATH`, so other bytes are another
  build (INTERNALS, "Embedded files"). Trig's pre-built libs (its NEEDS
  item 70) can move from literals to files, and `!xs.extend_from_bytes(s)`
  (built) reads their records with one copy, for a `T` whose every bit
  pattern is a value (`sema.bytesRecord`, SPEC "List"). An embed is held
  at 16 bytes (`rig.Embed`, an assembler `.incbin`; Zig's own backends
  place it as `@embedFile` does), and its records may hold `Bool`s and
  enums, whose values the compiler checks when it reads the file
  (owner, 2026-11-04, the zero-copy design's decisions 4 and 6). A
  record is an `exact` object (`obj NodeRec exact`, owner 2026-11-05):
  its fields in declaration order with no padding, a Zig `extern
  struct`; every other object keeps Zig's layout. Zero copy itself
  (decision 1) is built: a large run mapped into an empty List in a Linux
  release build (`alloc.mapRun`; its Zig ceiling on Trig: mitt 17.3%
  fewer cycles, nothing slower)
  ([records/2026-11/zero-copy/design.md](docs/history/records/2026-11/zero-copy/design.md)).
- **The `for` header (t05)**, approved and not started: a use in a
  `for` header belongs to the loop's entry, not its body, where the
  header copies its source out, so `for x in a.arr` with a body that
  writes what `a` viewed is accepted (`review-header-paths-1-t05`, a
  `prod-strict` line of `test/oracle/differences`). The row's goal,
  rule, cases, and gates are in
  [records/2026-10/core-33d/next-handoff.md](docs/history/records/2026-10/core-33d/next-handoff.md)
  (row 2). It follows 33D (#859: a statement's loans end at their last
  use, CORE §6 rewritten) and the oracle taught CORE §6 (#861).
- **The oracle's model of the hidden `E?`** (errors track 2's R3-3) is
  the one piece of errors with data left
  ([round-report.md](docs/history/records/2026-10/consolidation/round-report.md)).
- **The hash race** (`bench/hash`; its panel's decisions in
  [hash-race/](docs/history/records/2026-10/hash-race/)): `Map` and
  `Set` are compiler built-ins over `zig-ordered`'s table, and `HashMap`
  and `HashSet` over `zig-hash`'s (INTERNALS, "The built-in Map and
  Set"). Open: the owner confirms the iterator names (`HashItems` and
  the rest); text-key rows trail zig-hash 1.2-2.6 times (a String key's
  slot is 40 bytes, with no prefetch); the lane fact that would let `for
  k in m.lanes()` index a `[n]T` with no test waits for an array index's
  proven form in emit; and std's Map using a write view returned `from
  @` (`find` handing back the entry, with `edit` and `ensure` on top), a
  1.3-1.9% ceiling on ts-pattern, timed on Trig on its own.
- **Byte equality** (`bytes-eq`, `bench/eql`): text `==`, string
  patterns, and the tables' text keys compare by the runtime's
  `bytesEql`, whose loads stay wide in code a `--pgo` profile finds
  cold, where `std.mem.eql`'s ran byte by byte (2.5% of Trig's cycles
  on zod3). It lands on Trig's zod3 timing under `--pgo`.

## Next, in order

The owner's priority is Trig's speed against tsrs; memory counts where
it buys speed. Trig checks with several checkers in tasks, and its
output equals tsc's at each count. Standing-8
([tsrs-standing-8.md](docs/history/records/2026-10/hash-race/tsrs-standing-8.md),
#882, PGO Trig after rig#873's packed small objects) measured it
against tsrs as shipped: ts-pattern 10.6% slower at one checker and
32.8% at four, zod3 31.8% and 42.9%, with 34-51% more peak memory on
the large projects. Since then Trig has tsrs's lazy member tables
(trig#249: ts-pattern 1.3% faster at one checker, zod3 2.8% and 5.1%
at four, about 10% less peak memory on both), so the next standing,
standing-9, measures from there. The leads, in order:

1. **`get_property_of_type_ex`'s extra calls,** 1.8-2.25 times tsrs's,
   counted by call site.
2. **Flow and name resolution:** their counts match tsrs's, and their
   gap is cost per call (zod3).
3. **The head:** parse and bind cost per node, and file calls off the
   blocking pool.
4. **Trig's full suite in under ten minutes:** split release builds
   (rig#854's units: 3.1 minutes against 28.6 on pup), one shared build,
   and smaller shards. Its two release compiles take 31 and 18 minutes,
   and its 300-test chunks about 15 minutes each.

Waiting on the owner's go, each in a fresh session:

- **Maps second to none.** A new race standing on both machines
  against every competitor in `bench/hash`, then the gaps by size, text
  keys first (they trail zig-hash 1.2-2.6 times). No Map row may get
  slower.
- **The std pass:** each module of std against the best implementation
  in any language (yyjson for std.json, Ghostty for std.terminal), with
  the gap, then the gaps one at a time, each behind a speed guard.
- **A worker cap by default:** the test runner uses about 60% of the
  cores when not under `tools/heavy`, and cross-builds go through
  `tools/heavy`, so several sessions never overload the Mac.
- **The oracle's value loops:** `test/oracle/lower.zig` decides no
  function whose `while` yields a value, the shape a chain's rewrite
  makes. Measure its share, then lower that loop; its floors rise.
- **Trig's HANDOFF** lists what landed only to #223; it is brought up
  to date in Trig.

What was measured and is not to be redone (table coloring, prefault,
sparse links tables, the relation cache's key and path, Map calls out
of line, store-forward stalls, loop bounds checks, re-checked optionals
and tags, parse-time atoms, broad-corpus PGO, and more) is in the
brief's "Do not redo"
([docs/internals/trig-speed.md](docs/internals/trig-speed.md)).

Beside these, `rig lsp` moves onto Nexus's generated server (`nexus
--editor --lang src/rig.zig rig.grammar DIR`): Rig fills in the
generated `hooks.zig` (tokens, Rig-worded syntax errors, analysis of
the editor's unsaved text, completion words), and analysis needs an
entry to the checker that takes source in memory.

APIs, `api Shape` ([docs/design/apis.md](docs/design/apis.md)), are
built in all five stages. What remains, objects of an API with an
associated type (Stage 4, phase 5), the Lean model's crossing
obligation (Stage 5, phase 3), and owned closures as objects (Stage 5,
phase 4), is in [docs/ROADMAP.md](docs/ROADMAP.md), "APIs, the rest".

`Map`, `Set`, `Hasher`, `Order`, `Printer`, and `Symbol` are built in;
the run-time string interner is `text.Interner` in `std.text`. Trig
moves to these names with `tools/migrate-builtin-map.py` and
`tools/rename-interner.py`.

An object's optional is the size of the object where a field has room
for `none` (a String's, List's, box's, or handle's address, a `Bool`,
an enum's spare tag), an object that is an id names its own
(`none id == 0`), and every other flag optional is written in one
store. On Trig's binder (checker.ts, x86), a 4-byte `Node?` measured
14% faster and the one store alone 7%; Trig takes the first by naming
`Node`'s none and writing `none` for its `Node(id: 0)` placeholders.

Release builds on Linux can be laid out by a workload with BOLT,
`rig build --release --bolt -- WORKLOAD`: 7.6 to 7.9% fewer cycles on
Trig projects it was not trained on. They can also be optimized by
LLVM's profile-guided optimization, `rig build --release --pgo --
WORKLOAD`: Trig 10% faster with 14% fewer instructions on a project it
was not trained on, and 5-9% faster than BOLT alone
([record](docs/history/records/2026-10/perf-stage/pgo.md)). The same
flag works on the Mac: Trig 5 to 15% faster on projects it was not
trained on ([record](docs/history/records/2026-11/mac-pgo/README.md)). Release
builds omit frame pointers and stack canaries; `RIG_FRAME_POINTERS=1`
keeps the first for a profiler, `RIG_STACK_PROTECTOR=1` the second.

`std.terminal`, a terminal emulator library, matches Ghostty (pinned
at `31bdcd5a7963`) on 416 recorded cases and its fuzzer, scrollback
included, and beats it on every corpus of bench/terminal. Its
decisions, model, checks, and what is left are in
[docs/design/terminal.md](docs/design/terminal.md). Nothing is in
flight; the next piece (a reading API for renderers, OSC, resize, or
`std.tty` last) is the owner's choice.

Compile-time functions (`fun cap[n: Int] -> Int`, called `cap[8]`)
run in the checker (`src/cteval.zig`) over integers, `Bool`, plain
enums, and fixed arrays of them, and a function value goes to any
task (SPEC, "Compile-time functions" and §18). The next forms, a call
over an enclosing generic's parameter (`[cap[n]]T`) and text
parameters, are in docs/ROADMAP.md.

Learn Rig ([docs/learn/](docs/learn/README.md)) has journeys 01 to 11.
Journey 07 teaches generics and built-in bounds, and 08 APIs of a
program's own and API objects of every form, Stages 3 to 5. Journey 12
is written last; how a journey is written, and its outline, are in
[docs/internals/journeys.md](docs/internals/journeys.md). What the
journeys found in the compiler and its docs is at the end of
[docs/internals/backlog.md](docs/internals/backlog.md).

`v0.3.0`'s migration guide is
[docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md), and CHANGELOG's
"Upgrading from v0.2.9" lists the 74 forms 0.2.9 accepted that 0.3.0
rejects. The scripts:
`tools/migrate-0.3.py` (box, list, string, obj, builtin, label, self,
const), `tools/state-bounds.py`, and, for programs written against
`main` between the releases, `tools/migrate-builtin-map.py`,
`tools/rename-interner.py`, `tools/rarely-body.py`, and
`tools/rename-task-bounds.py`. Over the 4,836 programs `v0.2.9`
accepts, `main` accepts 1,094 as written and 3,495 after the scripts;
the rest need a form of the guide's Step 2 or 4 by hand
([release-0.3.0.md](docs/history/records/2026-10/consolidation-2/release-0.3.0.md)).
Everything after that is in
[docs/ROADMAP.md](docs/ROADMAP.md); the decided engineering items, with
their probe cases, are in [docs/internals/backlog.md](docs/internals/backlog.md).

## Scope

The North Star (AGENTS.md) and `docs/CORE.md` are fixed points.

**In scope:**

- **Building the Core's planned rules.** Each is marked *(planned)* in
  `docs/CORE.md` and shown by a `rig pending` example. Building one
  turns its pending example into an ordinary one, in the same change.
- **The weak spots and open questions** in
  [docs/internals/weak-spots.md](docs/internals/weak-spots.md), bug
  fixes, docs, tests, and speed.
- **Language and library work toward `v0.3.1` and Trig,** listed in
  [docs/ROADMAP.md](docs/ROADMAP.md). Each fits the Core.

**Needs the design owner first:**

- **A change to a rule.** It goes through `docs/CORE.md` first, as its
  own reviewed change, and needs the owner's agreement.
- **New library modules** beyond those in the roadmap, such as threads,
  and a new type built into the language.

A change that rejects programs a release accepted lists them in the
release notes.

## Conventions

- **Vocabulary:** *you lend a view; the compiler remembers the loan.*
  - lend: the act, written on the owner's side;
  - view: the value handed over;
  - loan: the owner-side record.

- **Commits:** prose, "area: what it now does", with a body of plain
  sentences and no AI attribution (AGENTS.md).
- **Comments:** timeless, describing the code as it is. History belongs
  in git.
- **The parser:** `src/parser.zig` is generated by `zig build` from
  `rig.grammar` and is not tracked; edit the grammar.
  `rig.grammar`, `src/rig.zig`, and `src/diag.zig` are mirrored
  byte-for-byte in Nexus's `grammars/rig`, so a change to them needs a Nexus
  re-sync.
- **Builtins:** a builtin call is `$name(...)`; Rig's own are `$size`,
  `$align`, `$type`, `$name`, `$plain`, `$variants`, and `$embed`. Rig's raw builtins track
  Zig's names exactly (`$fromBackingInt`, `$trunc`). A raw builtin's old
  spelling is rejected with a hint.
- **Speed work:** a speed feature lands when its gain on a real program,
  measured on runs it was not trained on, pays for its lines
  (AGENTS.md, "Working rules").
- **Merging:** after a branch merges, delete it locally and on GitHub,
  and remove its worktree. `main` stays the only branch.

## Who to ask

This file, AGENTS.md, and the records state the current facts, and are
enough to start from. Design intent and Core questions go to the owner,
as decisions with a default each; the records under
[docs/history/records/](docs/history/records/INDEX.md) hold the panels
and measurements behind every past decision.
