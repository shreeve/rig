# HANDOFF: where Rig stands, and what comes next

This is the resume point for anyone, human or agent, picking up Rig
work. Read it first, then [AGENTS.md](AGENTS.md) (the rules) and
[docs/CORE.md](docs/CORE.md) (the ownership model every rule derives
from).

## Current state

- **Release:** `v0.2.9` is the latest release (Zig 0.17.0, Nexus
  2.0.0). `main` is ahead of it toward `v0.3.0`, which is not yet
  tagged. `main` has changed the language since `v0.2.9`:
  - **Renames:** `Box[T]` is `^T`, `Vec` is `List`, the owned `Text` is
    `String` and its read view is `?String`, and `Static` is the type of
    literal text.
  - **`obj`:** `struct` is spelled `obj`, a contextual keyword.
    `struct` is an ordinary name, and a declaration written with it is
    rejected with a hint. `unique`, `from`, and `static` are contextual
    keywords too.
  - **Syntax:** a deeper-indented line starting with `.` continues the
    statement above (not after a line that opens a block); a closure may
    omit trailing parameters; a bare `for X` loops over `X`; an iterator
    in a place is written `for x in !it`.
  - **Weak handles:** `*w` upgrades a weak handle to a `*T?` (`*<w`
    upgrades and takes it); the method `w.upgrade()` is rejected with a
    hint, and so is `*~T`, as every holding sigil over a held value is.
  - **Numbers:** `x.not()`, the integer bit methods `leading_zeros`,
    `trailing_zeros`, `count_ones`, and `swap_bytes`, and the wrapping
    left shift `<<%` and `<<%=`.
  - **Text and lists:** String `reserve`, `push[T, e]`, and List
    `reserve`; a byte order on a one-byte type is rejected; clearing a
    List of plain values sets its length.
  - **Owned closures:** `*fun` and `*sub` take and return anything a
    function's signature may hold: write and read views for the call,
    owners, and handles (docs/CORE.md §7). A temporary callee,
    `(+h.f)(x)`, is planned.
  - **Vectors:** `Simd[T, n]`, `n` lanes of a number or `Bool` (`n` a
    power of two from 2 to 64): lane-wise operators that panic on
    overflow (`+%` and friends wrap), comparisons that give a mask
    `Simd[Bool, n]` with `any()`, `all()`, and `bits()`, `v.with(i, x)`,
    and byte reads with one bounds check. A vector is plain data
    (docs/CORE.md).
  - **Modules at scale:** a directory is a module whose `.rig` files
    share one namespace, as a Go package's do: `use a.b` names the
    directory `a/b/`, a `use` binds its name in its own file, private
    names are module-wide, and each module emits one Zig file. Modules
    still may not import each other in a cycle. A method may be
    declared outside its type's body in the type's module
    (`fun Point.norm(?self)`, `fun Wrap[T].map[U](...)`), which
    desugars to the member. Module constants fold in dependency order,
    and one that depends on itself is rejected. A directory's
    `_test.rig` files belong to its module only as the root of `rig test`
    (docs/INTERNALS.md, "Directory modules").
  - **Evaluation order:** every assignment evaluates its value first,
    then its target's steps, then stores; the order is one recorded fact
    (`storage.SetOrder`, `storage.eachSetStep`) that emit and the
    ownership checker both read.
  - **Errors:** `error` is a type, an error of any set (a parameter, a
    field, `List[error]`), and it is owning in every program: `<e`
    moves it and `+e` clones it (docs/CORE.md, "A failure moves its
    error").
  - **Speed:** runtime fast paths for push, add, and clear; small,
    only-called functions are emitted `inline` by a size rule the
    compiler decides (`src/inlining.zig`); a function marked `inline fun`
    is inlined at every call, one marked `called fun` is always a call
    (`noinline fn`), and one marked `rarely fun` is kept out of line with
    Zig's cold hint (the three words are contextual); a
    `for` index counter needs no per-iteration cast.
  - **The stack:** a program runs on a 64 MiB stack the runtime maps
    over a 64 GiB guard (`rig.onOwnStack`), so running out of stack, by
    deep recursion or a frame no larger than the guard, stops with
    `error: rig: stack overflow` in every build mode; each frame's reach
    (what it keeps and every value its code makes or copies) is held to
    a bound that keeps it within the guard by a measured factor, not yet
    a proven one (destination-passing, TODO.md, will make it one), and a
    large frame is never inlined; a fill a box or a local takes is built
    in place (docs/INTERNALS.md, "The program's stack").
  - **Compiler and tools:** a synthetic span outside its source reads as
    empty; the package cache and the build store have size caps;
    `src/parser.zig` is generated at build time from `rig.grammar`
    with Nexus, which is co-developed with Rig; and `tools/migrate-0.3.py`
    migrates 0.2 programs, each rename an independent pass (box, list,
    string, `obj`).
- **`std.json` (experimental):** a one-pass, validating JSON parser in
  safe Rig (`std/json.rig`) that builds a tape, with a tiered string
  scan (SWAR, then `Simd[U8, 16]`). `./test/run json` checks it against
  Python's `json` module on 10,511 inputs; `tools/fetch-json-data.sh`
  fetches the third-party files those read. `bench/json/` times it
  against Zig's `std.json`, serde_json, simd-json, sonic-rs and
  zimdjson (docs/json/RESULTS.md). Its API is not settled
  (docs/json/DESIGN.md, "Open items").
- **Releases:** every change, fixes included, ships in the current
  line, `v0.3.x`; an earlier line gets no further releases. Rounds land
  on `main` untagged until the next tag, which is cut only after the
  deep gate (AGENTS.md, "Land fast, release deep"); its release notes
  include a migration guide for the renames.
- **Branches:** `main` is the one long-lived branch. Work lands through
  short-lived branches and pull requests. The ruleset on `main` requires
  `test (ubuntu-latest)` and `test (macos-latest)`, and blocks force
  pushes and deletion.
- **Toolchain:** Zig 0.17.0, pinned in `mise.toml`. Nexus 2.0.0
  generates the parser at every build, from the sibling checkout's
  `nexus/bin/nexus` (AGENTS.md, "Workflow").
  - [docs/zig-0.17.md](docs/zig-0.17.md) covers every Zig API Rig uses.
  - The cross-project Zig guide is `~/Data/Code/zig/docs/ZIG-0.17.md`.
- **Health:** the gates in "The gates" below are green on `main`: the
  full suite (`./test/run`, with its pending examples the planned Core
  rules), the corpus, `test/matrix.py`, the unit tests, and the oracle
  floors in `test/oracle/coverage`. `test/known/` holds no open bugs.
  CI and each deep-gate run report the counts.

## Scope

The North Star (AGENTS.md) and `docs/CORE.md` are fixed points.

**In scope:**

- **Building the Core's planned rules.** Each is marked *(planned)* in
  `docs/CORE.md` and shown by a `rig pending` example. Building one
  turns its pending example into an ordinary one, in the same change.
- **The weak spots and open questions below,** bug fixes, docs, tests,
  and speed.
- **Language and library work toward `v0.3.0` and Trig,** listed under
  "What comes next". Each fits the Core.

**Needs the design owner first:**

- **A change to a rule.** It goes through `docs/CORE.md` first, as its
  own reviewed change, and needs the user's agreement. Ask the "Rig"
  session (below).
- **New library modules** beyond those in "What comes next". Examples:
  io, fs, Map/Set, traits, threads.

A change that rejects programs a release accepted lists them in the
release notes.

## The consolidation

The compiler was restructured so the Core's rules come from its
structure: about 90% of earlier soundness bugs traced to three
structural weak spots, which these steps removed (the evidence is in
`.git/revamp/reports/`, local). All ten steps are done:

1. **Type facts.** One fact per question (copies, unique, needs
   cleanup, may hold a loan, cloneable, how a read view is represented)
   replaced the disagreeing proxies; `obj T unique` exists,
   `std.random.Rng` became the unique `Random`, and a type holding a
   `Cell` is unique.
2. **One classifier and one exit.** `sema.handsOver` decides what every
   expression hands over by a positive list, and one exit primitive ends
   every path, running defers and reporting the loans it drops; the
   `classify` test keeps `handsOver` the only classifier.
3. **Reads and lends.** A bare name reads in place where a view is
   expected, one lend table serves every owner (List, String, `^T`, `*T`,
   optionals), and a header's subject is viewed or taken by its
   classification.
4. **Containers hold anything.** `List[String]`, nested Lists, and records
   that own text work; `?v[i]`, `!v[i]`, and `<v[i]` lend or take an
   element; assigning a view place re-points it or writes through.
5. **The remaining planned rules.** An error value meets `T!` only as
   `return`'s operand, `(!s).insert(k)`, `x =! e`, an owner moves
   as a function's or block's last value, and `+x` deep-copies List, `^T`,
   and owning objects.
6. **Result origins.** A call's result carries the loans of the
   arguments whose types could hold what it views, `from a` narrows
   that, and each body is checked against its signature.
7. **Vocabulary.** Diagnostics, docs, and internal names say lend, view,
   and loan; the `vocab` test fails on Rust's word.
8. **SPEC follows the Core,** derived from it in the new vocabulary.
9. **Speed.** Generic uses are indexed by parameter, which removed the
   quadratic generic checks.
10. **Lowering, decided as storage facts.** Every hidden storage
    location emit makes is a fact (`src/storage.zig`), emit takes no
    address of a Zig temporary such a fact names, the sanitizer poisons
    hidden storage, and the ownership checker walks what a call holds.

Alongside them, a reference ownership checker built from the Core alone
(`bin/rig-oracle`, `test/oracle/`) checks the compiler: `./test/run
oracle` fails when the compiler accepts a function the Core rejects,
and when the oracle decides fewer functions than the floors in
`test/oracle/coverage`.

The final review (`.git/revamp/r3/final-review/core-review.md`, local)
found no unsound program. Its fixes are in: a write method on a
temporary needs `!`, which lends the temporary to write in its
statement's slot (`!mk().pop()`, CORE sentence 4), a binding with no
type holds a call's write view, and the payload-view and loop
diagnostics name only forms that compile.

**Held, each waiting on the change named:**

- **Whole-program parameter summaries** (CORE §9, *planned*): a generic
  `Holder[?String]` built from literals is still rejected.
- **Field-precise re-pointing:** its own round (decision 1d): what a
  var holds is still per var, so re-pointing `p.v` keeps the old view's
  loans while `p` lives.
- **Std search taking `x: ?T`:** it would reject
  `slices.contains(?v[..], ?t[4..5])`; decide whether implicit lends
  extend to branching values.
- **`into` for stores, function-type `from`, and path tokens:** Core
  changes, each its own reviewed change.

## Open questions

These belong to the design owner; `.git/revamp/r3/rig-questions.md`
(local) has the evidence for each.

- **Core wording.** The commit "Correct CORE status words and
  precision" proposes the status words and precision the final review
  found wrong; it needs the owner's approval, and can be dropped alone.
  So does B4b's "Mark bare break and payload views past the arm built
  in CORE sentence 1".
- **Field-disjoint loans** are built (CORE sentence 5 and §5, "A field
  is a place of its own"); field-precise re-pointing waits for its own
  round. The other three rules the Core left open are decided and built
  (CORE sentences 1, 6, and 7): a call's result that holds no write view keeps a write
  argument lent to read, and that argument's write lend ends as the call
  returns; dropping a container of views uses them only through a `drop`
  body; a bare name or place only reads, so `x = h.w`, like `x = w`, of
  a `!Int` copies the Int.
- **The kind of an object of `?String` values:** CORE calls it a view, SPEC plain
  data; the compiler treats it as CORE's read-view kind.
- **A branching receiver:** a pointer per leaf (built) or a rejection?
- **Clone limits:** are the missing clones of a type from another
  module, or one holding a `Signal`, rules or gaps?

## Weak spots

Reviewers keep finding problems in these areas. Change them carefully,
and run the corpus after.

- **Statement temporaries** (Core §3). A header whose subject makes a
  temporary and reaches a place outside it binds the place's own: emit
  points at it (`storage.headerPoints`, the storage fact `header_value`
  held by pointer). One that reaches no place copies a value made in the
  header (`copiesHeader`, the storage fact `header_copy`) and is
  rejected, unless it takes its subject or binds plain data of a value
  made there. Tests: `test/behavior/ownership/header_points_through_temporary.rig`,
  `header_temporary_points.rig`, `header_branch_points.rig`, and
  `test/reject/ownership/header_temporary_rejected.rig`.
  - *Resolved in B4a:* a place inside a view of a value the header
    makes (`id(?mk()).e`, `(?mk()).e`, `idh(?mkh()).xs`) lives in the
    header's own temporary, so the header copies it and stays rejected;
    pointing there would read the temporary after the header drops it.
    Tests: the `sema` unit test "storage: a header points at a place its
    temporaries reach, never into one" and
    `test/reject/ownership/header_place_inside_temporary.rig`.
- **Payload views.** A read match's binding that is no plain data views
  the subject where emit matches it (`storage.matchesInPlace`: a place,
  a held part, a view a call returns, a value branching over views,
  through temporaries or a guard), so a view of it carries the subject's
  loan past the arm. Where a read match matches a copy, such a binding
  is usable within its arm only (`SymbolFlags.arm_view`); every such
  subject with a header temporary is also rejected (`rejectHeaderCopy`).
  Tests: `test/behavior/ownership/match_payload_view_outlives_arm.rig`
  and `test/reject/ownership/match_payload_view_escapes.rig`.
  - *Resolved in B4a:* a generic read view a field or an element holds
    on the subject's path (`match w.r`, `match arr[1]`) is reached in
    place, `rig.viewedPtr(T, &w.r).*`, never through a `rig.viewed`
    copy whose payload a pointer would outlive. Tests:
    `test/cli/emit_shapes.sh` (no `&rig.viewed(` and no switch on a
    `rig.viewed(` copy), `test/behavior/emit/generic_view_field_subject.rig`,
    `test/behavior/emit/generic_view_field_guard.rig`, and the escape
    `test/behavior/ownership/generic_view_field_escape.rig`.
- **Addresses of Zig rvalues.** `emitLeafPtr`'s `&@as(T, value)` and a
  temporary array lent to a call are the storage fact `zig_temp`. Emit
  still takes the address of two kinds of Zig rvalue no fact names: a
  `?self` method on a made value no slot keeps, or on a branching value
  with a made leaf, and labeled value blocks' yields (docs/INTERNALS.md,
  Emit, "Addresses of Zig temporaries"). They are latent: the checker
  keeps each view within its statement, and Zig keeps the rvalue's slot
  today. Next: make the chokepoint structural, so every `&` and `|*x|`
  targets a place, a slot, or fact-named storage whose `life` the
  chokepoint checks.
- **Decisions emit still makes itself** are `Pending` in
  `src/facts.zig`, which a unit test keeps from growing; each should
  become a recorded node fact (`sema.Question`), as the leaf walk did.
- **What a view could hold:** `carry` and `sema.viewReach`, and `?String`
  values in Cells, generics, and closures.
- **What a `^T` does not yet forward:** a box reaches its value's fields
  and methods, and lends its views, but `xs[i]`, `?xs[a..b]`, `for x in
  xs`, `==`, and arithmetic on a boxed array, List, or number name the
  box and are rejected; a box has an `unbox` of its own that hides a
  value's method of that name. A generic body cannot reach through a
  `^T` of a handle either (it cannot call a method of `T`), so the box
  and handle stacking rule is checked at generic instances only in
  fields and signatures.
- **Evaluation order versus what is emitted:** call arguments, and
  `print` and `String(...)` arguments. Assignments share one recorded
  order (`storage.SetOrder`).
- **`defer`/`errdefer` at exits,** owners behind `Cell`, `^T`, and
  `*T`, and generic instances.
- **Statement-long loans the Core does not need** (compiler-stricter,
  listed in `test/oracle/differences`): a call's result's read loans,
  and a write lend the call stores or whose result is a write view, last
  until the statement ends, not until their last use in it. So
  `match find(!v)` cannot write `v` in an arm after the payload's last
  use, `print(firstw(!v).n, v.len)` is rejected, and so is reading `v`
  after `keep(!v, !h, ?x)` in its statement though `h` is used no more.
  The Core allows all three, and the oracle accepts them. A later round
  ends these loans at their last use within the statement. Likewise a
  generic callee's argument write lend lasts to the statement's end,
  since its origins come from its signature, where a `T` could hold
  anything (`print(gfirst(!v).n, v.len)` is rejected); per-instance
  origins are a later refinement.
- **Review findings not fixed:**
  - Over-rejections main has too (review of B4b part 2, probes
    `test/corpus/review-b4b-2-p22`, `p24`, `p25`, `p43`): a payload
    view pushed into a List inside a `for` stays rooted on the loop
    binding; a view returned from a `match` nested on an outer payload
    binding (`match r.i` in `.a(r)`) is rooted on that binding; and a
    write-view local a payload view came through cannot be re-pointed
    while the view lives.
  - An operator, generic inference, and a binding with no type read a
    read view of a scalar as the value (`readsAsValue`), but keep a read
    view of a plain object, array, or optional as the view: copying
    those out there would change the type of accepted programs
    (`x = r` with `r: ?Point` binds a `?Point`). Where a type is
    expected, every value that copies is copied out (`sema.copies`).
  - The oracle accepts two shapes the Core rejects (the compiler
    rejects both): a `?self` result reaching an owned field beside a
    held view (`x77`), and re-pointing a write view a closure has lent
    (`x68`). Add them as `# oracle:` tests when the oracle learns them.
  - Whether an expression is a view is not one fact yet (CORE §9,
    *planned*): a loop over a call's returned view of a List of owners is
    rejected as if the List were made there.
  - `bin/rig-oracle` in a worktree goes stale; `./test/run` rebuilds it,
    so rebuild before using it by hand.

## What comes next

**In flight**, in landing order (each is a branch, not yet on `main`):

1. `m.first()` on masks, and `any` and `all` that stay fast in loops
   (`simdfirst`).
2. Checker-proved check elimination, redesigned around units: first
   `loopfacts` (where loop steps run and jumps go, recorded once; no
   emitted change), then `proofs2`.

**Toward `v0.3.0`:** the docs pass, the deep gate, and the tag with a
migration guide (`tools/migrate-0.3.py`).

**Later:**

- Errors that carry data, after `error` the type: declared sets
  (`T!E`, `error L = A | B`) and the typed `catch` binding, then member
  fields moved up through `!`, then std.json's fallible API (SPEC §13,
  "Declared sets and fields").
- Constant tables: module constants built from constructors of plain
  types, for Trig's diagnostics catalog (part B of the modules
  proposal, `.git/revamp/r3/proposal-modules-constants.md`, local).
- SIMD: `pad:` reads, `blocks(N)`, and one load for 4- and 8-byte
  byte-lane reads on ARM. (Round 2 built `t.lookup(idx)`, `cur.lag[k](prev)`, `+|` and
  `-|`, and lane shifts.)
- A String API for part-word appends and windowed writes.
- Several results after v1 (TODO.md): small results in registers, and
  `from` per result.
- Nexus's `Span.text`, in place of the position slicing Rig does.

**Also open:**

- The design owner settles the open questions and the CORE wording.
- B5: what B4b left of the header temporaries rule, a header that
  copies a value made in it.
- The structural address chokepoint.
- The per-expression "is a view" fact.
- The held items, as their prerequisites land.

## The gates

Two gates (AGENTS.md, "Land fast, release deep"):

- **The fast gate, per round:** the build, `./test/run --delta`, the
  round's new tests, a targeted grid of the forms it changes, and one
  independent review in parallel. A round that changes a soundness
  classifier also runs the full matrix.
- **The deep gate, on `main` about twice a day:** everything below, plus
  equivalence against the last deep run, the JSON benchmark guard, and
  the check-speed guard. A
  failure is bisected and fixed before any new round lands; a tag needs
  a clean deep gate. It also runs the Unicode tables' freshness test
  with the database present: `RIG_UCD=dir ./test/run unicode_tables`
  (the generator fetches any pinned file `dir` lacks).
- **The JSON benchmark guard:** on the Mac, `cpuq run --cores 2 --label
  rig:json -- bench/json/guard.py` builds `rig-safe` for the six corpus
  files and counts instructions retired per byte, which do not move
  with the load. A file more than 2% above its baseline in
  `bench/json/guard.txt` is a regression, and the guard fails. A change
  meant to move the counts commits a new baseline
  (`bench/json/guard.py --update`).
- **The check-speed guard:** on the Mac, `cpuq run --cores 2 --label
  rig:check -- bench/check/guard.py` builds the compiler in ReleaseSafe
  and runs `rig check` on a generated program about the size of Trig's
  parser (`bench/check/gen.py`). It fails when the instructions retired
  are more than 2% above `bench/check/guard.txt`, when a pass of `rig
  check --time` (best of 7) is more than 20% and 0.25 ms slower (skipped above a
  load of 5), or when checking a program 8 times larger along one
  dimension (modules, variants, fields, functions, statements) grows
  with an exponent over 1.15. A change meant to move them commits a new
  baseline (`bench/check/guard.py --update`).

The machines are shared: run heavy work through the job queue
(`cpuq run --cores 2 -- …`, with `-j "$CPUQ_CORES"`), which shares the
CPUs fairly. Full runs go to the Linux machine, pup, one
at a time with its spare cores.

```bash
./test/run -j 2                               # full suite; the sanitizer is on by default
./test/run -j 2 corpus                        # every reviewer probe; has caught real use-after-frees
python3 test/matrix.py -j 2                   # form x context x type programs
zig build test --cache-dir "$(mktemp -d)"     # unit tests; a plain rerun replays cached results
```

- Rerun a timeout failure alone before trusting it: under load,
  timeouts are often spurious.
- **Equivalence** proves that a refactor changed nothing:
  `python3 test/equiv.py OLD_RIG bin/rig` compares the parse, the
  checks, the facts, and the emitted Zig of every program and doc
  example, the root module's and the whole sanitized package's. It
  caches the old compiler's results, so a rerun against the same base
  runs only the new compiler. Explain every difference it prints.

## Conventions

- **Vocabulary:** *you lend a view; the compiler remembers the loan.*
  - lend: the act, written on the owner's side;
  - view: the value handed over;
  - loan: the owner-side record.

  The `vocab` test fails on Rust's word; `test/vocabulary-allow.txt`
  lists the few lines that must name it.
- **Commits:** short, imperative, with no AI attribution.
- **Comments:** timeless, describing the code as it is. History belongs
  in git.
- **The parser:** `src/parser.zig` is generated by `zig build` from
  `rig.grammar` and is not tracked; edit the grammar.
  `rig.grammar`, `src/rig.zig`, and `src/diag.zig` are mirrored
  byte-for-byte in Nexus's `test/rig`, so a change to them needs a Nexus
  re-sync.
- **Builtins:** Rig's raw `@` builtins track Zig's names exactly
  (`@fromBackingInt`, `@trunc`). The old names are rejected with a hint.
- **Merging:** after a branch merges, delete it locally and on GitHub,
  and remove its worktree. `main` stays the only branch.

## Who to ask

For design intent, Core questions, or whether something is a new feature
or consolidation, send a message to the **"Rig"** session. Its work log
is `.git/revamp/ledger.md` (local); this file states its current facts.
