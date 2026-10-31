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
2. **Notes outside the repo.** The owner's Rig sessions keep theirs in
   `~/Data/Code/Claude/rig/`. Its `CLAUDE.md` gives their order, and
   `rig/og-handoff.md` there lists what is open at the moment, with its
   paths on pup. The owner's standing preferences are in
   `~/.claude/projects/-Users-shreeve-Data-Code-rig/memory/MEMORY.md`.
3. **See what is open:** `gh pr list` (drafts are being measured or
   wait on the owner), "In flight" below, and `git log --oneline -20
   origin/main` for what landed last.
4. **Work** in a worktree (`wt new NAME`, AGENTS.md "How a change is
   made"), never in the main checkout. Each compiler, emit, runtime, or
   std change passes the gates of AGENTS.md step 6, std.json's guard
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

- **Release:** `v0.2.9` is the latest release (Zig 0.17.0, Nexus
  2.0.0). `main` is ahead of it toward `v0.3.0`, which is not tagged.
  The changes since `v0.2.9`, renames and removed spellings included,
  are in [CHANGELOG.md](CHANGELOG.md).
- **Releases:** every change, fixes included, ships in the current
  line, `v0.3.x`; an earlier line gets no further releases. Rounds land
  on `main` untagged until the next tag; its release notes include a
  migration guide for the renames (`tools/migrate-0.3.py`).
- **Branches:** `main` is the one long-lived branch. Work lands through
  short-lived branches and pull requests: plain git, with no CI,
  gates, or required checks.
- **Toolchain:** Zig 0.17.0, pinned in `mise.toml`. Nexus 2.0.0
  generates the parser at every build, from the sibling checkout's
  `nexus/bin/nexus` (AGENTS.md, "Workflow").
  [docs/internals/zig-0.17.md](docs/internals/zig-0.17.md) covers every
  Zig API Rig uses. Its `@intCast` from a signed type to a narrower
  unsigned one miscompiles in release builds (LLVM `trunc nsw`); Rig's
  emitted Zig and runtime cast through the unsigned type of the source's
  width instead, until Zig fixes it.
- **Health:** the bar for landing is a green full run on `main`: the
  full suite (`swarm test/rig.rip all`, with the doc examples, their
  pending examples the planned Core rules), `test/matrix.py`, the unit
  tests, and the oracle floors in `test/oracle/coverage`. A change to
  the compiler, the runtime, or std also passes Trig's light gate
  (`tools/light`, AGENTS.md step 6) before it merges: a debug trig on
  Trig's six cli projects, four ways each, byte-identical to tsc, in
  about a minute; and loco's (`rig/tools/light` in a loc checkout):
  loco built with that Rig, its output identical to the Rust loc's.
  Trig's full suites run on both mains on pup every four
  hours or on demand (`tools/full-main`); the last result is in
  `/zfs/trig-pup/full/LATEST`. One case is marked `known: true`: a
  module constant holding a vector passes as a field default and then
  fails in Zig (`test/rig/types-simd.rig.test`).

## In flight

- **Small std additions for the sanstun port** (owner, approved with
  the port's panel): `std.hint.keep[T](x: ?T)`, Rust's `black_box`, as
  an empty `asm volatile` with a memory clobber, which needed a
  Zig-backed function to take a bare type parameter; `net.Ip` and
  `net.Addr`, addresses as plain data that parse, print, hash, and
  give an `/n` prefix; `time.Instant` `: Ord` with `add` and
  `Instant.at`. In review as one draft PR; the names are the owner's
  to confirm.
- **std.io's standard streams** (#798, the coreutils port's first std
  addition; owner approved `io.stdin()`, `io.stdout()`, `io.stderr()`):
  the three streams as `file.File`s, stdout through `print`'s buffer;
  `File.read` into the caller's buffer, with no allocation when it has
  room; `FileError` with a member per errno and `file.reason(e)`, the
  system's words. The owner approved the member names and `reason`;
  the gates are green, and it waits to merge.
- **`std.crypto`** (#800, owner 2026-10-30, for the sanstun port):
  ChaCha20-Poly1305 and XChaCha20-Poly1305, X25519, BLAKE2s and
  HMAC-BLAKE2s in Rig, with a Zig shim for DIT, wipes, and a value
  barrier. Its adversarial review's findings are fixed; a draft until
  its light gates run.

- **A range's counter has its bounds' type** (queue row 13): a bare
  or `_` range loop over `U64` bounds emitted an `i64` counter that Zig
  rejected; the counter now reads the range's recorded type. In review
  as one PR.
- **`net.Stream.split()` and `batch`** (owner, 2026-10-30): a stream
  splits into a `Reader` and a `Writer` two tasks own, the writer's
  close a half-close; `batch(on)` lets the system hold small writes.
  The poller's ends now wake only the waits they end. In review as one
  PR, for the mini-redis port.
- **A server's memory, PR A** (#779, the runtime part of the memory
  panel's fixes, owner 2026-10-30): a net read without room holds no
  buffer while it waits, each thread's signal stack is an untouched
  mapping, a blocked task touches one stack page, and fresh stacks hold
  none. Merged. PR B is split (owner, 2026-10-30: nothing slower
  lands): B2, reads that grow a String unfilled, in review alone; B1
  and B3 (#785, a draft: another heap's remote list before carving a
  page, a program-wide bound on large blocks) wait for a heap to reuse
  other heaps' kept large blocks, so 64 KiB values on 22 workers are no
  slower.
- **A large optional result through the caller's place** (ray-speed
  review, decision 1, owner 2026-10-29): an API object's table entry
  whose result is an optional wider than three words writes it through
  the caller's place and returns a flag; a `none`'s payload is not
  filled in a safe build. In review as one PR (#781); the direct-call
  case is in the backlog.
- **Push loops keep `len` in registers** (finding 1 of the Rust ports'
  second speed review, owner 2026-10-29): a String's and a List's
  appends grow by value through one `growBy` each, so no append passes
  the owner's address to a call. In review as one PR (#780).
- **A shared value made in a variant's call** (B4 of the Rust ports,
  2026-10-29): `Frame.bulk(data: *Frozen(...))`, a `*Chan[T](n)`, or
  an `*Actor(x)` there is the payload's value, and `*Actor(x)` takes
  its type from `x` where an `*Actor[T]` is expected. In review as one
  PR.
- **The inlining PR** (owner, 2026-10-29, approving the Rust ports'
  speed reviews): each compile-time instance is its own function to the
  yield checks, so `at[true]` calling `at[false]` no longer checks; a
  generic function is inlined by the size rule; `slices.reverse` swaps
  the first half with the last, its mirror index proven. In review as
  one PR of three commits. Specializing `fun` parameters (gap 1) waits
  on a design note.
- **A lent self's element is reached in place** (R2 of the Rust ports,
  2026-10-29): `?xs[i].m()` gives `m` a view of the element, never of a
  copy, so a `from @` result no longer views a temporary. In review as
  one PR. R1, a result that views a `for` element, is in the backlog.
- **The paren rule** (owner, 2026-10-29, the design note's rule): a
  write call whose value is used is written short, `x = !v.pop()`; only
  one whose method declares a `Bool` result keeps `(!s).add(k)` where
  its value is used. It only accepts programs rejected before, so Trig
  needs no migration; `tools/drop-write-parens.py` drops the
  parentheses no longer needed. In review as one PR.
- **The cost around each list node** (too-many-lists' speed review,
  `~/Data/Code/Claude/rig/rig/rust-ports/reviews/tml-speed.md`): `^T?`
  and `~T?` are a pointer's size, a store into a field taken with
  `<p.f` drops nothing (`old_nones`), the drop queue is drained only
  when it holds something, and a `*T`'s drop is inline until the last.
  In review as one PR, measured commit by commit.
- **Four bugs the Rust ports found** (port-bugs, one PR, a commit
  each): a generic object holds an optional view of itself, and a field
  naming its own object's optional (`List[Node?]`, `?Node?`) is
  rejected; a read view of a handle changes no Cell; a taken binding
  that owns a resource is lent to write, a handle's too; an optional
  view compares as the optional of what it views. Trig and std use none
  of the rejected forms. In review.
- **The keep-or-cut panel's fixes** (owner, 2026-10-28, approving its
  defaults; records in `~/Data/Code/Claude/rig/rig/feature-cut/`):
  cut nothing, and freeze `*{A}`, `~{A}`, `once ?fun`, and user
  `api`/`add`. A type that contains itself is told to box the field
  (`next: ^Node?`), and `for x in ?h` walks a List or array a shared
  handle holds, in one PR. A loop over a box (`for x in ?b` of a
  `^List[T]`) is still rejected, a sibling SPEC's box table implies.
  Next: drop `*Frozen`'s weak count; measure what the weak count costs
  every `*T` on Trig, by share first.
- **The Rust-style review's errors-only fixes** (owner, 2026-10-27,
  its default): a method with the very signature a built-in API fixes
  on a type whose header does not name the API, a parameter `?^T`, and
  a clone into a read view are rejected, each with its fix; a literal
  is self of a call through an API (`Twice.twice(4)`); `async` and
  `await` name `&` and `>t`. Trig, std, the examples, and the benches
  use none of the rejected forms. In review as one PR.
- **A float provides no `Ord`** (owner, 2026-10-27, the Rust-style
  recommendations' default): a NaN is neither below nor above a
  number, so `T: Ord` takes no float, and floats compare by their own
  `min`, `max`, `clamp`, and `total_order` (SPEC "Floats in order").
  Two PRs: the methods and `Num`'s comparisons first, which reject
  nothing; then the fix, once Trig has run `tools/migrate-float-min.py`
  on its six `math.min` sites of floats. The name `total_order` is the
  owner's call against `total_cmp`, Rust's.
- **A generic body's own values hold no untracked view** (SPEC
  "Generic bodies", approved 2026-10-27): an instance whose type
  argument can hold the view a body could put in a `T` it holds is
  refused at the call or type that makes it, `update`, `retain`, and
  `ensure_with` of a Map or HashMap at a value type that can hold a
  view among them; `ensure_with` keeps nothing of `make`, and `!?T` is
  rejected as `!?String` is. The oracle refuses the three Map calls
  alike and abstains at a program's own generics, as at any instance
  at a view. Deferred by the owner: accepting a closure that stores
  nothing (docs/internals/backlog.md); records in
  `~/Data/Code/Claude/rig/rig/generic-rule/`.
- **The consolidation round** ran on 2026-10-23
  ([PLAN.md](docs/history/records/2026-10/consolidation/PLAN.md)); what
  it landed, measured, and left is in
  [round-report.md](docs/history/records/2026-10/consolidation/round-report.md).
  Emit decides nothing itself (`Pending` is gone), and no case is
  `known: true`. Open: the owner's decisions it lists, and the oracle's
  model of the hidden `E?`.
- **Partial moves** (CORE §5, "A field of an owned object moves like a
  name", approved 2026-10-24): built in two PRs, the oracle first
  (#668), then the compiler; records in
  [partial-moves/](docs/history/records/2026-10/partial-moves/). Trig
  can drop about 82 of its 111 `swap(!x.f, empty)` sites and 3
  optional fields kept only to be taken (its NEEDS 26). λRig has no
  fields, a gap formal/README.md records. An optional field of a
  parameter, capture, or `=!` local moves too (decision 14, for
  Loco's `<o.by_file` and `<c.entries`); an assignable local's is taken.
- **`par.workers(!states, ?items, |s, x| ...)`** (decision 8c, approved
  2026-10-25) is on `main` (#684): a task for each state, pulling items
  in the caller's order, results in item order. It matches Trig's
  hand-built channel loop for work-stealing checkers (Trig #207) in
  [bench/par](bench/par/README.md); Trig may swap its loop for it.
- **`$plain(T)` narrowing** (SPEC "Generic bodies", approved 2026-10-26)
  is on `main` (#701): inside `if $plain(K)` a generic body may copy a
  `K`. Sema decides plain once per instance and emit passes it as a
  compile-time Bool; the oracle knows the rule.
- **The hash race:** `bench/hash` races both Rig maps against abseil,
  boost, ankerl, hashbrown, indexmap, Rust std, Zig and Go on every row
  of `bench/hash/WORKLOADS.md`, all built for the CPU they run on. The
  goal is first place, with two families: the ordered `Map`/`Set` and
  an unordered `HashMap`/`HashSet` (working names). The owner's plan:
  win in Zig first, then make Rig emit that Zig. Faithful Zig ports of
  boost and ankerl (`zig-foa`, `zig-dense`) lead on the Mac and trail
  on x86; `zig-hash` and `zig-ordered` are being grown from them. The
  panel's twelve decisions are approved
  ([hash-race/](docs/history/records/2026-10/hash-race/)). #685's
  SwissTable `std.hash` is archived as `archive/std-hash`. Of the
  allocator's two gaps the race found, large blocks reused by fit are
  #725; huge pages from 2 MiB (decision 11) raised Trig's peak memory
  and were left out, and huge pages from 16 MiB, which the owner
  approved, are #726, measured again on Trig's memory
  ([alloc-large/](docs/history/records/2026-10/alloc-large/),
  [alloc-thp16/](docs/history/records/2026-10/alloc-thp16/)).
  The first compiler piece the race needs, `for k in m.lanes()` (the
  panel's work order, step 4, approved 2026-10-27), walks a mask's true
  lanes in each target's form, the nibble mask on ARM and `pmovmskb` on
  x86, at four or five instructions a lane (`test/cli/mask_lanes.sh`).
  Its lane-range fact for the proof pass (`0 <= k < n`, so `[n]T`
  indexed by `k` needs no test) waits for the masked-index proof in
  `src/proofs.zig`. The next, `xs.prefetch(i)` (step 3), is one
  prefetch instruction with no range test, since a prefetch of any
  address does nothing a program can see, so it needs no proof
  (bench/prefetch).
  The built-in `Map` and `Set` are rewritten on `zig-ordered`'s design
  in safe Rig (std/prelude.rig; INTERNALS, "The built-in Map and Set"):
  Trig 4-6% fewer cycles and lower peak memory on pup; the rows that
  trail main, in-cache hits, the latency chains, 4M inserts, and text
  removes, are in
  [map-rewrite-rig.md](docs/history/records/2026-10/hash-race/map-rewrite-rig.md).
  The owner then made their table a compiler built-in (2026-10-27):
  `Map` and `Set` stay declared in the prelude over `OrderedMap[K, V]`
  and `OrderedSet[K]`, the prototype ported into src/ordered.zig
  (INTERNALS, "The built-in Map and Set"); Trig 2.9-3.6% fewer cycles
  than #735 on pup
  ([map-builtin.md](docs/history/records/2026-10/hash-race/map-builtin.md)).
  `HashMap` and `HashSet` (names confirmed by the owner) are built the
  same way over `UnorderedMap[K, V]` and `UnorderedSet[K]`, `zig-hash`
  ported into src/unordered.zig (INTERNALS, "The built-in HashMap and
  HashSet"): Map's members but `at`, order unspecified; 60 of
  bench/hash's 104 rows on the Mac and 77 on pup within 5% of zig-hash
  or faster
  ([hashmap-builtin.md](docs/history/records/2026-10/hash-race/hashmap-builtin.md)).
  Open: the iterator names (`HashItems` and the rest) are the owner's to
  confirm; text-key rows trail zig-hash 1.2-2.6 times, as the Map's
  trail zig-ordered (a String key's slot is 40 bytes, with no
  prefetch).
- **Masked indexes** (`src/proofs.zig`): `s[e & m]` with `m = s.len -% 1`
  under a guard `s.len > 0` makes no bounds test, ready for the Map
  rewrite. The built-in Map, Set, and Interner keep their two guarded
  passes: probing `(home +% d) & mask` made Trig run 1.15% fewer
  instructions and most bench/hash rows faster, but `lat16 chain` 20-50%
  slower (PR #729 has the numbers). The lane fact for `for k in
  m.lanes()` indexing a `[n]T` is not built: an array index has no
  proven form in emit yet.
- **Trig's stores on `Table`/`Slot`:** Trig's migration; the same reads
  without a test, measured in a stand-in build, made ts-pattern about 3%
  faster.
- **A view lent through a write-view binding** (CORE sentence 7, §7
  Defer) is built: `if !@slots[j] as s` / `return !s.value` `from @`,
  and the same through a local, a `for` element, a call's result, and a
  `match !` payload
  ([records](docs/history/records/2026-10/wview-return/)). What it
  unlocks is not built yet: Map's and Set's `find` handing back the
  entry (`(!Entry[K, V])? from @`), with `edit` and `ensure` on top,
  which removes the index re-tests behind the 1.3-1.9% ceiling on
  ts-pattern; it changes std's Map, so it is timed on Trig on its own.

Errors with data, from the approved spec
(docs/history/records/revamp/r3/errors-panel/), is on `main`:

- declared error sets (R2, #542), with clones across modules and Map's
  `+` (#548);
- the runtime's error-data plumbing (R3a, #550);
- CORE's paragraph "A failure moves its error", revised by a panel of
  four (docs/history/records/2026-10/errors-core/);
- fields on members wherever a failure goes (R3, #555): calls, function
  values, closures, tasks, actors, `par`, `isolate`, `main`, and tests;
- one representation for `error` (Option U, #566);
- std.json's `JsonError` (R4, #565), by `load` beside a `Bool` `parse`
  kept for speed;
- generic sets (R2.5, #569), `fun total[E](f: ?fun() -> Int!E) -> Int!E`
  (docs/history/records/2026-10/errors-r25/).

Two pieces remain: the oracle's model of the hidden `E?`, and std's I/O
sets (R3-3), which wait for the owner's names.

## Next, in order

In the owner's order:

1. **APIs Stage 3,** by the build plan's six phases
   ([docs/history/records/2026-10/apis-stage3/build-plan.md](docs/history/records/2026-10/apis-stage3/build-plan.md)).
   Phase 1, declarations and conformance, is built: `api`, headers and
   `add` checked but not lowered, coherence, and bounds by a program's
   own APIs at each instance
   ([phase1-notes.md](docs/history/records/2026-10/apis-stage3/phase1-notes.md)).
   Phase 2, calls through a bound and their witnesses, is built:
   defaults, additions, `Shape.area(c)`, error sets and the
   API's clauses through a bound
   ([phase2-notes.md](docs/history/records/2026-10/apis-stage3/phase2-notes.md)).
   Phase 3, method-level bounds and additions to types with value
   parameters (`Slot[n]`, `Table[T, n]`), is built
   ([phase3-notes.md](docs/history/records/2026-10/apis-stage3/phase3-notes.md)).
   Phase 4, associated types and `Iter` with std.iter, is built
   ([phase4-notes.md](docs/history/records/2026-10/apis-stage3/phase4-notes.md),
   [review-p34.md](docs/history/records/2026-10/apis-stage3/review-p34.md)).
   An item views its iterator only at an instance whose items may view
   memory the iterator owns, so a body that holds no item past the next
   `next` (`iter.count`) takes every iterator, and one that holds an
   item is rejected only at such an instance (consolidation round 2,
   row 29); items of a `next` that names only fields declared as read
   views (`from @map`), as Map's and Set's iterators do, view no
   iterator: a method's view names the path of self it views, Core
   sentence 7
   ([records](docs/history/records/2026-10/from-field/approved.md)).
   Phase 5, the Lean lemma, is
   built (formal/LambdaRig/Calls.lean; formal/README.md, "Calls through
   an API"). Phase 6, implied bounds and the rule that public generics
   state their bounds, is built
   ([phase6-notes.md](docs/history/records/2026-10/apis-stage3/phase6-notes.md)):
   it rejects programs a release accepted, so Trig takes its migration
   (`tools/state-bounds.py`; the diff is
   [trig-migration.diff](docs/history/records/2026-10/apis-stage3/trig-migration.diff))
   when it lands. Stage 3 is then complete.
2. **APIs Stage 4, API objects** (`?{Shape}`, `!{Shape}`, `^{Shape}`),
   in progress, in phases with an adversarial review each, landed after
   the suite and Trig's light gate
   ([build-plan.md](docs/history/records/2026-10/apis-stage4/build-plan.md);
   its 21 defaults approved,
   [open-questions.md](docs/history/records/2026-10/apis-stage4/open-questions.md)).
   Phase 0, the Core, is done: CORE §1 and §4 state the rules, from a
   panel of four the owner approved
   ([core-panel/](docs/history/records/2026-10/apis-stage4/core-panel/approved.md)).
   Phases 1 to 3, the types, views and calls, and boxes, are built;
   phase 4, the Lean lemma, and phase 5, associated types in braces,
   remain.
   **Stage 5, shared and crossing objects** (`*{Shape}`, `~{Shape}`,
   `^{Job + Sends}`), is in progress, in phases the same way
   ([build-plan.md](docs/history/records/2026-10/apis-stage5/build-plan.md);
   its defaults approved with the panel's changes,
   [open-questions.md](docs/history/records/2026-10/apis-stage5/open-questions.md)).
   Phase 0, the Core, is done: CORE §1 and §4 state the rules, from a
   panel the owner approved
   ([core-panel/](docs/history/records/2026-10/apis-stage5/core-panel/approved.md)).
   Phase 1, crossing bounds in the braces (`^{Job + Sends}`,
   `?{Shape + Syncs}`), is built, in review
   ([phase1-notes.md](docs/history/records/2026-10/apis-stage5/phase1-notes.md));
   phase 2, `*{Shape}`, `~{Shape}`, and `*{Shape + Syncs}`, is built
   on it, in review
   ([phase2-notes.md](docs/history/records/2026-10/apis-stage5/phase2-notes.md)).
   Phase 3, the Lean obligation, and phase 4, owned closures as objects
   (a performance PR, kept only if faster), remain.
3. **`rig lsp` on Nexus's generated server** (`nexus --editor --lang
   src/rig.zig rig.grammar DIR`): Rig fills in the generated `hooks.zig`
   (tokens, Rig-worded syntax errors, analysis of the editor's unsaved
   text, completion words). Analysis needs an entry to the checker that
   takes source in memory. Nexus's template already has the fixes from
   Rig's dry run.

Beside these, Rig supports Trig's speed: the owner's aim is to match
or beat tsrs. Trig checks with several checkers in tasks, and its
output equals tsc's at each count. Built with `--pgo`, Trig took 893 ms
on ts-pattern at one checker against tsrs's 665 (1.34x, 2026-10-26),
with 1.20x its instructions and 1.48x its peak memory; #705, #706,
#710, and #711 landed after that measurement, about 4% fewer
instructions by their separate measurements. Trig's own program logic
is at parity with tsrs's; the rest of the gap is in Rig's patterns. What landed for it on
2026-10-24 to 26: PGO, cheaper yield checks, release builds without
frame pointers, prefaulting large heaps, `Table` reads without a test,
one compare for an index against a fixed bound, a yield check that
keeps registers, the Map's probe inlined, and an object of integers
hashed one multiply a pair of words. What is left, by share of
ts-pattern's 8,527M instructions: List operations and their checks
(10%), Map/Set (9%), spills around calls (4%), yield checks (3%), and
`hashMix` (2%); each is measured for its share before work starts
([records](docs/history/records/2026-10/perf-stage/)). Trig's needs
from Rig, in the owner's order:

1. **Single-thread speed of the checker and of Map/Set,** which carries
   into every checker. With every safety check removed, ts-pattern runs
   11.2% faster (index tests 8.0%, conversions 2.9%, Zig's bounds 1.7%,
   overflow 1.2%; docs/history/records/2026-10/safety-checks/measurement.md). By
   share of that cost: the stores (`Table`/`Slot`), Trig's symbol and id
   accessors, the std Map/Set probes, and Trig's AST records. Map and
   Set code is 18.8% of ts-pattern's samples, beyond its checks. The
   wide-key Maps' lookups already run as the hand-written Zig table's
   do; their cost is the index's misses, a third of Trig's L2 load
   misses and half its STLB misses
   ([map-wide-keys.md](docs/history/records/2026-10/hash-race/map-wide-keys.md)):
   huge pages for a large index are the lever left, and the wide-key
   insert row is 34% behind zig-ordered's.
2. **Doing less.** Trig allocates about 6.4x what tsrs does. Its memory
   is live data, not List slack (exact presizing saved 4% on Linux): the
   stores' contents, Map entries, and about 200,000 small `u32` lists.
   The heap profile (`RIG_HEAP_PROFILE=sites`) names their owners.
3. **Build speed.** `rig build` reuses no cached work (ROADMAP, "Cached
   `rig build`"), and a Trig release build takes about 9 minutes and
   about 9 GB on pup.
4. **The ownership checker's Map limits** are lifted: partial moves
   are built, and a write view bound by `if !@slots[j] as s` is
   returned `from @` (In flight). What waits is std's Map using them:
   `find` handing back the entry, a 1.3-1.9% ceiling on ts-pattern
   (docs/history/records/2026-10/safety-checks/len-and-map-notes.md).
5. **Startup** (Trig's NEEDS 62): std.file calls go through the
   blocking pool, a futex round trip each; an empty Trig run makes 52
   futex calls against tsrs's 5. While only one task can run, a
   blocking call could run on the caller's stack.

Measured and set aside: lazy member tables (symbols are about a tenth
of Trig's heap), prefault for every heap with tasks (no gain, 8-15%
more memory), sharing global types across checkers (a low ceiling, and
tsc's ids per checker could not be matched), and a parallel parse and
bind (about 1.5% of ts-pattern).

APIs, `api Shape` ([docs/design/apis.md](docs/design/apis.md)), are
built in stages. Stage 1, method calls on a type parameter, and Stage 2,
built-in bounds (`[T: Ord]`, `obj Version: Ord`, a type's own `eq`,
`hash_into`, `order`, and `print`), are on `main`, and Stage 3's phases 1
to 4 with them. Stage 4, API objects, is built in phases (phase 0, its Core text, done), each landed
after the suite and Trig's light gate: phase 1, the types and their
rules, is built
([phase1-notes.md](docs/history/records/2026-10/apis-stage4/phase1-notes.md)),
and phase 2, views of objects and calls through their tables
([phase2-notes.md](docs/history/records/2026-10/apis-stage4/phase2-notes.md)),
and phase 3, boxes of objects, `^{Shape}`
([phase3-notes.md](docs/history/records/2026-10/apis-stage4/phase3-notes.md)),
each in review in turn; objects of an API with an associated type
(phase 5) wait for a program that needs them. Stage 5, shared and
crossing objects, is in progress (phase 0, its Core text, done; phase 1,
crossing bounds, built and reviewed,
[review-p1.md](docs/history/records/2026-10/apis-stage5/review-p1.md),
awaiting its gates; phase 2, shared and weak objects, built and in
review); a
design question is answered from the
record, and what it does not settle goes to the owner as a decision with
a default.

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
([record](docs/history/records/2026-10/perf-stage/pgo.md)). Release
builds omit frame pointers; `RIG_FRAME_POINTERS=1` keeps them for a
profiler.

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

Toward `v0.3.0` are a full run and the tag. Its migration guide is
[docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md), and CHANGELOG's
"Upgrading from v0.2.9" lists the 43 forms 0.2.9 accepted that 0.3.0
rejects, which the tag's release notes take over. The scripts:
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
- **Language and library work toward `v0.3.0` and Trig,** listed in
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
  byte-for-byte in Nexus's `test/rig`, so a change to them needs a Nexus
  re-sync.
- **Builtins:** a builtin call is `$name(...)`. Rig's raw builtins track
  Zig's names exactly (`$fromBackingInt`, `$trunc`). The old names are
  rejected with a hint.
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
