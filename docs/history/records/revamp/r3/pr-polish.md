## Summary
Fixes for the rough spots that blind tests with fresh readers and outside critics found, with the sigils `?` (look) and `!` (act) kept. Nothing here touches lend classification, binding types, or ownership decisions: `src/ownership.zig` changes only the text of its messages (PR #94, `payload-loan`, changes it near line 2575; this branch changes `reportAlias`, `placeText`, and a few strings, so the two do not overlap).

| Change | Old | New |
|---|---|---|
| A comparison under `not` takes parentheses | `not it.qty > 3` accepted, read as `not (it.qty > 3)` | rejected: "write `it.qty <= 3`, or `not (it.qty > 3)`: `not` applies to the whole comparison" |
| Copy rejections in plain words | "would copy the buffer pointer and double-free on scope exit; use `<v` to move ownership" | "`v` owns a `Vec[Int]`, which can't be copied by `=`: write `<v` to move it, `+v` to clone it, or `?v` to view it" |
| Hints print the user's own call | "use `(!receiver).pop(...)`", "`v[...]`" | "write `(!v).pop()`", "`v[0]`" |
| No implementation terms in diagnostics | "drop glue", "closure environment", "smuggle", "interior-mutable", "swap-and-yield" | plain words |
| docs/QUICK.md | none | a one-page guide to the sigils |
| DESIGN's "each have a marker" | claimed for drops and allocation too | says which effects are written and which are implicit, as in Rust |
| The test suite's shared build store | unused builds kept 7 days (past 200 GB seen) | kept 2 days (`RIG_BUILD_STORE_DAYS` default) |
| The cache of built programs | grew without bound (48 GB seen) | trimmed daily of rig's packages unused for 5 days; `rig clean` removes only what rig made |

## 1. `not` before a comparison
- **Where.** The parse is unambiguous: the grammar's `neg = NOT operand:neg` sits below the comparisons, so `not a > b` is `(not (> a b))`. Parentheses leave no node (`"(" expr ")" → 2`), so the rule is a type-checker diagnostic (`Checker.checkNotScope`, called from the `.not` case of `synth`) that reads the spans: a `not` written over a parenthesized comparison ends past it, at the `)`. The grammar and `src/parser.zig` are unchanged.
- **Exact scope.** Rejected: a `not` whose operand is a `==`, `!=`, `<`, `>`, `<=`, or `>=` node, unless that comparison is written in parentheses directly after the `not`. This holds wherever `not` stands: a condition, a guard, an argument, an operand of `and` or `or`, a module constant, a generic body, and an inner `not` (`not not a == 1`). `not (a) > (b)` is rejected: the parentheses group a side, not the comparison.
- **Still valid:** `not done`, `not bag.is_empty()`, `not (a > b)`, `not not done`, `not a and b` (that is `(not a) and b`, as in Python), `a or not (b < c)`, `not o ?? false` (`??` is no comparison; see Decisions).
- **The hint.** It offers the flipped comparison first wherever the flip means the same: `==` and `!=` always, and an ordering whose sides are both integers or text (a String or a `[]U8`). For a Float, a generic `T`, or anything else it offers only `not (...)`, since `not (x > y)` is not `x <= y` for a NaN. The flip replaces only the operator, so a parenthesized side keeps its parentheses: `(a) <= (2)`.
- **Docs:** SPEC §5 (operators: the rule, a `rig reject` example with its message), SYNTAX §6 (precedence), FAQ, QUICK.

### The rewrite
`.git/revamp/r3/polish/rewrite.py` (`scan` / `apply`) is the syntax-b script, driven by the new diagnostic: at each `not` it reports, it puts the comparison in parentheses (`not (it.qty > 3)`, never the flip, so the rewritten program means the same to the letter). It reads every tracked `.rig` program, `std/` through a program that uses every module, every ```` ```rig ```` doc block with its `file=` modules, and the test/cli heredocs, and moves the `# error: L:C:` directives an insertion shifts. KEEP: `test/reject/syntax/not_comparison_scope.rig` and doc blocks whose error is the rule's. `scan` on the head reports 0 files.
- **Result:** 6 files, 11 sites: `test/behavior/syntax/boolean_operators.rig`, `SPEC.md` (one example), `test/reject/types/receiver_sigil_bool_result.rig` (a directive moved one column), and corpus probes `R3c1-t19_ctx`, `R3c1-t37_prec` (6 sites), `review-sc3-n4`.
- **UNCHECKED** (by a regex, for a hand): prose in SYNTAX (rewritten by hand), INTERNALS and STD (not code), and corpus lines such as `not c or f() > 0`, which are `(not c) or ...` and need nothing.
- Main's compiler on each original and the new compiler on its rewrite emit identical Zig (boolean_operators, R3c1-t19, R3c1-t37); review-sc3-n4 is rejected by both, for the write-call rule, one column over.

## 2. Diagnostics in plain words
- **Copy rejections** (`ownership.reportAlias`, the one place every kind is reported). The message names what holds the value and lists every fix that works for it:
  - `<x` to move it (a name), or `<p.f` to take it out, leaving `none` (an optional part);
  - `+x` to clone it, where `sema.cloneable` says it has a clone (`+h` "for another handle" for a `*T` or `~T`; none for a type with a `drop` body, a unique type, or one holding a write view);
  - `?x` to view it, where the sink is a binding.

  With no fix, it says the value has no clone and can't be moved out of its parent. The sink reads as "by `=`", "into an argument", "into a field", "into an array", "into a shared box", "out by `return`", "out by `break`".
```
`v` owns a `Vec[Int]`, which can't be copied by `=`: write `<v` to move it, `+v` to clone it, or `?v` to view it
`f` owns an `F`, which can't be copied by `=`: write `<f` to move it or `?f` to view it
`a` is a unique `Seed`, which can't be copied by `=`: write `<a` to move it or `?a` to view it
`rc` is a `*Wrap` handle, which can't be copied by `=`: write `<rc` to move it, `+rc` for another handle, or `?rc` to view it
`h.o` owns a `Bag?`, which can't be copied into an argument: write `<h.o` to take it out (leaving `none`) or `+h.o` to pass a clone
```
- **A bare argument whose parameter takes ownership.** When the callee is a declared function or method (`Checker.ownerCallee`; not a constructor, a closure, or a built-in method like `push`), the message names it and the parameter fix:
```
`total` takes ownership of a `Vec[Int]`, and `v` can't be copied: write `<v` to move it or `+v` to pass a clone; if `total` only reads it, make its parameter a `?Vec[Int]`
```
  The checker learns the call from a new field, `arg_call`, set while a call's arguments are walked; it is read only for this message.
- **Placeholders replaced by the real text:**
  - receiver hints (`needs its receiver lent to write`, `consumes the receiver`, `writes its receiver`, `does not consume`, a temporary's `add !`, `writes the elements`, a `!` that reaches a type or module, `?(...)` result lends): the whole call as written, with its arguments, through `Checker.callWith` / `writeCallText` (a parenthesized receiver keeps one pair of parentheses). `(!receiver).pop(...)` became `(!v).pop()`, `<receiver.consume(...)` became `<u.consume()`;
  - `ownership.placeText` printed every index as `[...]`: it prints the index written, so "cannot assign to `a[0]` while `a` is lent", "cannot move out of `v[0]`". `placeText` is only ever shown, never compared.
- **Implementation terms removed** from diagnostics (grep of every string in `src/`): "carries drop glue and would leak as a discarded statement" ("this statement makes a `T`, which owns what it must release, and does not use it"), the `Cell[T]` element rule's "drop glue", `Cell.get`'s "would alias the cell's owned value ... swap-and-yield", "closure captures are owned by the closure environment", "smuggle the handle out of the closure environment", "a closure's environment", "interior-mutable `Cell[T]`", and "aliased" for a stack closure. "Drop glue" stays where SPEC and INTERNALS define it.
- Expectations updated: 83 reject tests (90 with review 1's capture wording), and doc examples in CORE (2), SPEC (2), WELCOME (1), BEYOND-RUST (1).

## 3. docs/QUICK.md
86 lines, from `.git/revamp/r3/sigil-test/cheatsheets/A.md`: the sigil table, a bare argument is read, `?` in a binding makes a lasting view, moves, clones and drops (`<x` as a statement), `(!v).pop()`, optionals and failure, `not`, builtins, and `?self` / `!self` / `<self` receivers, with one program that runs under the suite (doc/QUICK). It is in the AGENTS.md Map and linked at the top of README's tour; TODO's "one-page sigil spec" item is removed.

## 4. Honest wording
- **DESIGN, "Effects stay visible":** "Rig writes every move, clone, and write where it happens, and reading is unmarked. ... Like Rust, Rig leaves some effects implicit: a drop where a scope ends, the allocation a `Vec`, `Box`, or `Text` makes, a plain copy, and a change inside a `Cell`". The idea paragraph says every effect the checker reasons about "is written in the program, or follows from where a scope ends".
- **WELCOME:** "every move, clone, write, and failure path" with drops at scope end said; the opening's "no hidden allocation" says only the few types that own memory allocate.
- **FAQ:** a count *ends* where its handle's scope does (not "every count change is written"); "moves, clones, and writes visible at the call site".
- **SPEC §7:** the sigils mark ownership effects, a read lend may go unwritten, and a value not moved is dropped at its scope's end with no mark.
- README and BEYOND-RUST make no such claim.

## 5. The cache of built programs
- **The cache home** is `$XDG_CACHE_HOME/rig`, else `$HOME/.cache/rig`. A variable that is not an absolute path is ignored, as the XDG spec says; with neither usable, `rig clean` fails and the trim is skipped.
- **Rig's tag.** Rig writes a standard `CACHEDIR.TAG` (`Signature: 8a477f597d28d172789f06886806bc55`) when it makes the cache home, or in an existing untagged home that holds at least one of rig's packages or its empty stamp and nothing else (one an earlier rig made). An empty home, or one holding trash-named entries, is never tagged. The trim and `rig clean` act only on a home that holds the tag and is not a symbolic link; any other home is left alone (`openCacheHome`). Backup tools skip a tagged directory too.
- **Only what rig makes there is ever removed** (`CacheEntry` in `src/main.zig`, the one classifier the trim and `clean` share): a directory named `<name>-<16 lowercase hex digits>` whose `rig` directory holds the regular file `runtime.zig`, none of them a link (checked under the package opened with `O_NOFOLLOW`); a `.trash-<16 lowercase hex digits>` directory; the stamp `.trimmed`, only when empty; the tag, only when it carries the signature.
- **A lock per package.** `run`, `build`, and `test` make the package directory and take a shared `flock` on its `.lock` file (opened to read and write, as Linux NFS requires of a lock, and never through a link; any failure goes on unlocked) before they write the package, check that the lock file is still the one at that path (a trim may have renamed the package meanwhile; then they make it again), mark the directory used, and hold the lock until rig exits (`holdPackage`). The system releases the lock however the process ends, Ctrl-C and `kill -9` included. The trim and `clean` take an exclusive lock without waiting (`lockForRemoval`), then check that the locked file is still the one at the package's path (by inode), so they never move a package a run made there after another trim renamed the old one; a package whose lock is held, or that cannot be locked, is skipped. Where the system has no file locks, nothing is removed (fail safe).
- **Trimmed.** If `.trimmed` is older than a day, missing, or dated in the future, they touch it and remove every package unused for 5 days, all but the current one. Under its exclusive lock, each package's time is read again against the clock read then, and a time in the future is fresh; a lock file the trim had to make (in a package from an earlier rig) is not counted as a use. Then it is renamed to `.trash-<random>` under the lock, and deleted. When the trim removes any, it prints one line on stderr: `rig: removed N packages unused for 5 days from PATH` (the first trim after an upgrade is not capped; it says what it did). A failure never fails the build.
- **`RIG_OUT_DIR` is never trimmed**, and a run with it set does not trim the cache home either.
- **`rig clean`** removes every rig entry but a package whose lock is held; then, if nothing else is in the home, the stamp, the tag, and the home itself. It reports `rig: removed N packages from PATH`, plus `rig: kept N packages a run, build, or test is using` and `rig: kept PATH, which holds files rig did not make` as they apply (an entry another process removed first counts as removed, not as a stranger's). `rig: nothing to clean in PATH` when the home does not exist; an error, exit 1, for a home that is a link or holds no tag. It takes no file.
- **Documented** in `rig --help` (command, usage line, RIG_OUT_DIR), README's "Build and run", and INTERNALS.
- **Test:** `test/cli/cache_trim.sh`, every cache in its own directory (`HOME` and `XDG_CACHE_HOME` set there; Zig's global cache kept):
  - an untagged home holding a stranger's directory: neither tagged, trimmed, nor cleaned;
  - a home of rig's own entries only: tagged on the next run, then trimmed, and the report printed;
  - kept by the trim: a recent package; an old one whose lock a helper process holds (a `perl` `flock`, as a run does); one dated in the future; a non-rig name; uppercase hex; a package name without rig's runtime; a package whose `rig` is a link; a link named like a package; a link named like trash; and no report when nothing went;
  - no second trim within a day; a build a day later trims and marks its package; a stamp in the future is old;
  - an interrupted run: a sleeping program's package survives a trim while it runs; after `kill -9`, its package goes;
  - concurrent runs after an idle week: 5 rounds of 4 programs at once, all stale; every run must succeed and print its line (ac9dcd8a failed 6 of 20 in this loop);
  - `RIG_OUT_DIR` left alone;
  - `rig clean` keeps a held package, a non-empty `.trimmed`, and every stranger's entry and link target; then, with only rig's entries left, removes the home; then "nothing to clean"; `rig clean FILE` refused;
  - a cache home that is a link (to a home rig made): neither trimmed nor cleaned, and `clean` says why;
  - `XDG_CACHE_HOME=.` beside a tagged `./rig`: the cache is under `$HOME`, and `./rig` stays; a relative `HOME` is refused;
  - `XDG_CACHE_HOME=$HOME` with an untagged source tree at `$HOME/rig`: a run there does not tag it, and `clean` refuses it.

## 6. The shared build store keeps 2 days
`test/run`'s default `RIG_BUILD_STORE_DAYS` is 2, not 7 (the owner's decision: the shared store grew past 200 GB with a 7-day window). It sets how long a run with no filter keeps the store's unused builds and the results cache's unused records. Stated in test/run's header, test/README.md (the build store and the results cache), and INTERNALS. `test/cli/test_prune.sh` checks the default: with `RIG_BUILD_STORE_DAYS` unset, a build unused for 73 hours goes and one used 25 hours ago stays (it fails with 7). No test asserted 7. The prune now reads each entry's `used` again just before moving it, so an entry a concurrent run marked used since the scan stays.

## Commits (since main 48f20f2a)
- b52c476f Put each comparison under `not` in parentheses (rewrite.py). Valid on main, so green on its own.
- dfb22b4a **Write a comparison under `not` in parentheses, or flipped** (typecheck, tests, SPEC, SYNTAX, FAQ).
- 9d72f8ce **Say in plain words why an owner can't be copied, with every fix, and name the real index.**
- ea6a38fb Write the user's own call in receiver hints, not a placeholder.
- 7d5bfa05 Say plainly what a closure keeps, what a Cell hands back, and what a statement discards.
- c44e9834 Say which effects Rig writes and which it leaves implicit, as Rust does.
- 0e6c5de2 Add a one-page guide to the sigils and ownership.
- c56a6c9d **Trim the cache of built programs, and add `rig clean`.**
- aea73c3f Write `*<x` for boxing a name in the one-page guide.
- 2e50bde9 **Trim and clean only what rig made in an absolute cache home, never a running program's** (review 1: F1, F2, the stamp, the trim's report, "nothing to clean").
- e125ee3a **Offer a take, a handle, or a parameter type in a hint only where it compiles** (review 1: F3, F4, the generic hint, the multi-line `not` hint).
- ac9dcd8a Say when a bare argument is read, and when a count is released (review 1: QUICK, DESIGN).
- c2ec7d54 **Lock each package while it is used, and trim only a cache home rig tagged** (review 2: R1, R2, S1–S3).
- 48b6db55 Keep the shared build store's unused builds 2 days, not 7.
- 0f84526a Merge origin/main (308585bf, #94) into polish. One conflict, in `requireAccess`: #94's `readMatchHint` kept with this branch's `Cell[T]` wording. One #94 expectation updated for the real index (`s[0]`). #94's new messages use no placeholder or implementation term. `rewrite.py` over the merged tree: 0 files.
- b5bd7444 **Open lock files to read and write, tag a home only on proof, and re-check before pruning** (review 3: N1, N2, N3, Q3).

## Tests
- `reject/syntax/not_comparison_scope.rig` (10 errors, `# errors: 10`): ordering, equality, Float, text, joined with `and`/`or`, a guard, parenthesized sides, a nested `not`. Accepted on main.
- `behavior/syntax/not_scope.rig`: the forms that stay valid, with their values.
- `cli/cache_trim.sh`. Fails on main (no trim, no `rig clean`).
- The diagnostics' tests are the 83 updated reject tests; the hints check (`test/hints.py`) passes over them.

## Verification
Gates on the head b5bd7444 (main 308585bf merged), one at a time, `--delta`, through `cpuq run --cores 2-6` directly:
- suite: 3065 passed, 0 failed, 3 pending;
- corpus: 9131 passed (324 carried over), 0 failed;
- matrix: 7501 programs, 3681 ran clean, 3820 rejected, 0 failed;
- unit: 136 passed, 1 skipped (fresh cache dir).

The merged head 0f84526a passed the same four gates before the review-3 commit (3065 / 9131 / 7501 programs, 0 failed; unit 136 passed).

**`test/equiv.py` against main 308585bf, on b5bd7444:** 11634 programs, 506 differ, every one in `check` and `facts` only. None differs in `parse`, `normalize`, `sema`, `storage`, `emit`, or `pkg`, so every program both accept emits identical Zig and an identical package. Newly rejected: 3, the `not` rule's own (the SPEC example and the two `not_comparison` reject tests); none newly accepted; the other 503 are rejected by both with the same number of errors, in new words.

**`test/equiv.py` against main 48f20f2a, on ac9dcd8a:** 11041 programs, 495 differ, every one in `check` and `facts` only. None differs in `parse`, `normalize`, `sema`, `storage`, `emit`, or `pkg`, so every program both accept emits identical Zig and an identical package (and recording `untakeable` changes no fact).
- **Newly rejected: 3,** all the rule's own: the SPEC `rig reject` example, `reject/syntax/not_comparison_scope.rig`, and `reject/syntax/not_comparison_lines.rig`. None newly accepted.
- **The other 492** are rejected by both with the same number of errors, in new words (on aea73c3f, by diagnostic: copy rejections 297; receiver and call hints with the real call 153; the real index 91; the shared-handle `Cell[T]` advice 68; the closure, `Cell.get`, and discarded-statement wording 34).

## Review round 1 (`review-polish-1.md`)
- **F1 (P1), `rig clean` could delete a user's files.** Fixed as above: a relative `XDG_CACHE_HOME` or `HOME` is ignored, and the trim and `clean` remove only `CacheEntry`s, then the home only when empty. The review's two repros (`XDG_CACHE_HOME=.` beside `./rig/src`, `XDG_CACHE_HOME=$HOME` with `$HOME/rig`) are in `cache_trim.sh`, which fails on aea73c3f.
- **F2 (P2), the trim removed a running program's package.** A package holding `.started-*` is skipped by the trim and kept by `clean`; each package's time and `.started-*` are checked again just before its rename. (Round 2 replaced this check with a lock per package.)
- **F3 (P2), "`<p.o` to take it out" where the take is rejected.** The type checker records an optional part the take would reject (`noteTakeable`: the take's own check, `requireAccess(placeOf(e), .take)`, its diagnostics dropped) in `SemContext.untakeable`, which is no fact, so no facts dump changes. `reportAlias` offers `<` for a part only where it is not recorded. `reject/ownership/take_hint_where_take_allowed.rig` (through `?T`, `*T`, and a by-value parameter: no `<`; a local and a `!T`: `<`) and `behavior/ownership/take_hint_applied.rig` (every offered form, run).
- **F4 (P3), captured values.** The fix is chosen by `sema.cloneable` (`captureFix`): `+v` "for a clone" of an owner, `+h` "for another handle, or `~h` for a weak one" only for a `*T`, `+w` "for another weak handle" for a `~T`, nothing where there is no clone. "is a handle" became "is captured by the closure", and dropping a capture offers no fix. `reject/ownership/capture_fix_by_type.rig`.
- **F5 (P3):**
  - a generic callee's hint names the declared parameter type, `?T` or `?Vec[T]` (unknown, for a named argument: "make its parameter a read view"): `reject/ownership/copy_into_generic_param.rig`;
  - a comparison under `not` that spans lines is written on one line, its comments taken out: `reject/syntax/not_comparison_lines.rig`;
  - the future stamp, the trim's report, and "nothing to clean": above;
  - QUICK says a bare argument is read where the parameter is a read view, and that a bare owner to an owning parameter is rejected (`<v` or `+v`);
  - DESIGN: a count is added only where `*x` or `+x` is written, and released where `<x` drops a handle or its scope ends.
- **Not changed:** the copy hint inside a loop still lists `<v` first for an outer `v` (it predates this PR; the review grades it as such).

## Review round 2 (`review-polish-2.md`): cache deletion
The review found the deletion code safe for user data, and F1 fixed. Its two P2s and its P3s:
- **R1, concurrent runs after an idle week failed** (28 of 100). The trim read the clock once and counted a future time as old, and a run marked its package used only after writing it. Now a run takes its package's shared lock, and marks it used, before writing it; the trim removes a package only under its exclusive lock, re-reading its time against a fresh clock, with a future time fresh. The CLI test's 5 × 4 concurrent rounds pass; ac9dcd8a fails 6 of those 20 runs.
- **R2, Ctrl-C left a `.started-*` that pinned the package forever.** The trim no longer reads `.started-*` (a run still uses it to prove the program started): the lock is what marks a package in use, and the system drops it when rig ends, however it ends. Tested with `kill -9`.
- **S1.** `.trimmed` is removed only when it is rig's empty stamp; the home is removed only when it holds rig's tag and nothing else.
- **S2.** Lowercase hex only; the package's `rig` directory and `runtime.zig` are checked with no link anywhere on the path; `CACHEDIR.TAG` as the marker of a home rig made.
- **S3.** A cache home that is a link is refused by both the trim and `clean`, which says so; `clean` counts an entry another process removed first as removed. The `clean`-versus-build race is closed by the lock.
- **Decision:** the trim refuses a linked or untagged home silently, since it runs on every build, where a line would repeat; `rig clean` says why.

## Review round 3 (`review-polish-3.md`): locks, tag, recognizer
The review found no way for user data to be lost. Fixed:
- **N1 (P1), a Debug rig panicked on Linux NFS:** the lock file was opened write-only by a run and read-only by the trim, and NFS refuses a lock the open mode does not allow (EBADF, which Zig makes a Debug panic). Both now open it read and write (`openLock`). Every other lock failure fails safe: a run goes on unlocked; the trim and `clean` skip the package (or stop, with no file locks). Test: with `lsof` present, `cache_trim.sh` checks that a running `rig` holds its `.lock` open read-write (`u`); NFS itself is not testable here.
- **N2 (P3):** an existing home is tagged only when it holds a package or rig's stamp, and nothing else. Tests: a home holding only a `.trash-<hex>` directory with a user file is not tagged, and the file stays; an empty home is not tagged.
- **N3 (P3):** `holdPackage` retries (`continue`) where it gave up; a `.lock` that is a link is never followed (tested: the run succeeds unlocked, and the link's target is untouched); `lockForRemoval` re-checks the lock file's inode at the package's path after locking (a race, not testable deterministically).
- **Q3 (P3):** test/run's store prune re-reads `used` just before each move (a race, not testable deterministically).
- **Notes kept as notes:** SIGTERM to `rig` alone leaves its program running unlocked; a rig older than this PR neither locks nor marks its package, so a new rig may trim an old rig's running package once its time is 5 days old; on Windows the trim's own lock stops its rename, so nothing is removed there.

## Decisions to confirm
1. **`??` under `not` is left alone.** `not o ?? false` is `not (o ?? false)`; `(not o) ?? false` would not type-check, so it is not ambiguous the way a comparison is. The brief names comparisons only.
2. **The flip is offered only where it is exact**: not for a Float (NaN) or a generic `T`. The rewrite always writes the parentheses.
3. **The first trim after an upgrade is not capped**; it prints how many packages it removed. A cap would leave most of a 48 GB cache for later days.
4. **A package-named directory counts as rig's only if it holds `rig/runtime.zig`**, beyond the name the brief asks for.
5. **A shared handle is said to "own what it must release"** in the discarded-statement and `Cell.get` messages, as a `*T` releases its count.
6. **The cache home's directories are marked by their own time**, not a `used` file as the build store does: one `setTimestampsNow` per build.
7. **`rig test` trims too**, as it writes a package to the same cache home as `run` and `build`.
8. **A process that outlives `rig`** (rig killed while its program runs on) no longer holds the lock, so its package may be trimmed once old; the running program keeps its open executable either way.
9. **AGENTS.md's sigil table still lists `-x` as "drop now"**, which CORE §8 contradicts (`-x` always negates; a drop is a statement `<x`). Not changed here: AGENTS.md is the design owner's.

## Migration (v0.3.0 release notes)

| Old | New | What the compiler says about the old form |
|---|---|---|
| `not a == b`, `not x.n > 3`, `if not s >= t` | `not (a == b)` or `a != b`; `not (x.n > 3)` or `x.n <= 3` | write `x.n <= 3`, or `not (x.n > 3)`: `not` applies to the whole comparison |
| `not f > 0.5` (a Float) | `not (f > 0.5)` | write `not (f > 0.5)`: `not` applies to the whole comparison |
| `not done`, `not (a > b)`, `not a and b` | unchanged | (accepted) |
| a cache home grown large | nothing to do; `rig clean` empties it at once | (none) |

`.git/revamp/r3/polish/rewrite.py apply` makes the `not` rewrite in a checkout with the new compiler built (`bin/rig`); `scan` then reports 0 files.
