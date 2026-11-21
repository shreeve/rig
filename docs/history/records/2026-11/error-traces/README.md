# A failure's trace in debug builds (2026-11-21)

The IDEAS.md entry "A failure's trace in debug builds" (the Crystal
review, Rust), built as the owner approved for the datetime library's
"total or visible" rule (docs/design/datetime.md §10.5): a failure that
leaves `main` printed only `error: E.name`, with no place.

## What it prints

```text
error: E.worse
  a.rig:6:3 in parse
  a.rig:10:7 in twice
  a.rig:14:22 in convert
  a.rig:19:9 in main
```

The `error:` line stays first and unchanged, so whatever reads it still
works. A line `  file.rig:L:C in NAME` follows for each site, innermost first:
the failing `return` where the failure began, each `!` that passed it on,
and, for a failure made in a handler (`twice(s) catch |e| return
E.worse`, line 14 above), the handled failure's sites before the
handler's `return`. Innermost first is Zig's own order (and a panic's
stack trace's), and it puts the line that matters most, where the
failure began, right under the `error:` line. A site is shown as Rig's
diagnostics and `panic` show a place, `file.rig:L:C` first, so
terminals and editors link it, then ` in` and the function it is in,
as Zig, Rust, and Go traces name theirs: `Box.take` for a method, `a
closure in main` for a closure, `test "name"` for a test, and a task's
function for its body. The owner chose the name over the bare place
(2026-11-21), after review; emit knows the function where it marks the
site, so the name rides in the sites table at no cost to the run.
`rig test` prints a failing test's trace after its `FAIL` line, on
stdout with it.

## How emitted Zig maps back to Rig

Zig 0.17 keeps an error return trace in debug builds
(`builtin.have_error_return_tracing`; `std.lang.StackTrace`, 32
addresses and a count): `std.lang.returnError` records the return
address of each `try` and each `return` of an error, and a `catch` (or an
`if`/`else` on an error union) restores the count when the failure is
handled. Probes (Zig 0.17.0, aarch64-macos) settled what it holds:

- `inline fn` bodies record their sites, and the debug information
  names the inlined site's own line and column, so Rig's inlined
  functions need nothing extra.
- A frame with a C calling convention starts a fresh trace: `main` runs
  on the runtime's stack from `onOwnStack`'s `callconv(.c)` frame, and
  each fiber from its own, so the trace of a failure leaving them must
  be kept there.
- Zig drops a failure's sites when a call's result is stored into a
  `var` or into memory (`var v = f();`, `v = f();`, `x.result = f();`)
  and keeps them for a `const`. Emit wrote every call that reaches an
  inlined fallible function as `var __rig_v = f(); _ = &__rig_v;` (to
  keep the result a run-time value, `emitCallDirect`), which lost the
  callee's sites; it now writes `const __rig_c = f(); var __rig_v =
  __rig_c;`, and the runtime keeps a result in a `const` before storing
  it.

Each address's Zig line and column come from the debug information,
read as Zig's own traces read it (`SelfInfo.getSymbols`). The Rig place
of each Zig line and column comes from a table each module carries,
one line `L:C file.rig:L:C in NAME` per site. Emit
marks each site in its text, `\0file.rig:L:C in NAME\0` before the `try` or the
`return` (a zero byte, which Zig source never holds), and the marks stay
until `writePackage` writes the file, after the last change to its text:
an `$embed`'s directory, a batch's rewritten import paths, and
`RIG_MAP_TRACE`'s wrappers all shift columns on their lines, so
taking the marks out any earlier would name wrong columns. Only the
modules emit wrote are read (`PackageFile.module`): an embedded file
is its bytes, zero bytes among them.

The table is `__rig_sites` at the module's end (`emit.writeSiteTable`):
the text, and a function of the module's own, `__rig_sites_anchor`,
whose address the debug information names the module's file by,
exactly as it names a trace's addresses, so a site is found in the
table whose anchor names the same file. The root names the program's
other modules (`__rig_sites_of`); a batch's root and `rig test`'s
driver name the programs (`__rig_site_programs`), and a split build's
unit reaches its program through `__rig_program`; `rig.siteTables`
gathers the tables when the program is compiled, and a release build,
which never reads them, compiles none.

The first build wrote the sites beside each module in the package, in
`X.zig.sites`, and read them from there. Review found that wrong: an
executable `rig build` made keeps its code and debug information, but
the package directory is rewritten by the next build of the same root,
so an older executable printed the newer source's places
(test/cli/trace_build.sh). The table travels with the executable, so
that cannot happen. The objections first raised against a table did not
hold: a release build compiles none of it, and the registry is a list
in the root.

A site is matched by its exact Zig line and column in its module's own
table; an address in the runtime, Zig's library, or a shim matches
nothing and is left out, so a wrong place cannot be shown, only a
missing one.

## Across stacks

Zig's trace stops at each frame that starts a stack, so a failure a task
gives its waiter carried no sites from the task. `rt.TaskTrace` carries
them: the task's `Control` keeps a copy of its trace as the task ends with
a failure (`Runner.run`, heap-allocated only then, and only in a debug
build: in release the field has no bits), and the waiter appends those
addresses to its own trace where it takes the failure (`keepFailure`),
outside any `if`/`else` on the failure, which would restore the count
and drop them. `dropResult` frees a kept copy. The same carries a
failure out of `task.isolate`, `task.supervise`'s last run, a set's
`wait_first` (its last failure), and `par.map`, `par.each` and
`par.workers` (the first failure, kept where it is caught). An actor's
method failure needed nothing: it reaches the caller through a task or
inline. A split build (`--units=N`) calls a fallible function another
unit owns through that unit's exported C thunk, a fresh trace too: the
thunk keeps a failure's sites in a thread-local, and `split.call` adds
them to the caller's (test/cli/units.sh found it: three units printed
fewer sites than one).

Review found a fork run on its waiter's stack (`sched.runHere`, which
the threaded scheduler uses and `--seed` does not) printed its sites
twice per level of nesting: its runner shares the waiter's trace, so
the sites it kept were already there when the waiter added them. The
runner now keeps only what its trace recorded since it began
(`rt.traceIndex`), and a waiter does not add sites kept from its own
trace, where they stayed (`KeptTrace.shared`); `par`'s chunk run by the
caller is caught there, so its sites are added. errors-trace has the
nested case with and without seeds.

`failMain` reads no trace when an interrupt canceled `main`, which
ends with nothing shown: in a debug build reading the debug
information takes about 70 ms.

## Build modes

A release build (`--release`, Zig's safe mode) leaves Zig's traces out,
and so prints the `error:` line alone. Turning them on there
(`-ferror-tracing`) was measured on std.json's guard (instructions per
byte, macOS, the branch's `bin/rig`):

| File | release | release with traces |
|---|---|---|
| twitter | 6.2383 | 6.4993 (4.2% more) |
| twitterescaped | 7.4879 | 7.5854 (1.3% more) |
| canada | 14.8482 | 14.8729 (0.2% more) |
| citm_catalog | 6.0627 | 6.3667 (5.0% more) |
| gsoc-2018 | 2.9121 | 2.9841 (2.5% more) |
| github_events | 5.2841 | 5.4262 (2.7% more) |

Up to 5% more instructions on std.json, past the 2% bar every change to
it must meet, and LLVM may merge the `returnError` calls of an optimized
function, which would give several sites one place. Recommendation,
built: debug builds only, as the idea said. The runner drops the
trace's lines from a case's expected stderr in release.

## Cost when nothing fails

Release builds, main (75a6c7b5e) against the branch, macOS:

- `rig check` (bench/check/guard.py, alternating, fewest of 4 each):
  main 2,182,176,218 instructions, the branch 2,170,990,277 (the
  committed baseline 2,157,462,149, which main is above too). Level.
- std.json (bench/json/guard.py, instructions per byte): main
  6.2297, 7.4057, 14.7809, 6.0375, 2.8974, 5.2552; the branch 6.2310,
  7.4062, 14.7812, 6.0374, 2.8992, 5.2568: within 0.1% on every file.
- The built-in tables (bench/hash/guard.py): every row within 0.1% of
  `guard.txt` but `Map` churn, 0.6% and 1.2% fewer.
- std.text (bench/text/guard.py): every row within 0.1% of `guard.txt`.

The release code changes only where emit gives an inlined fallible
call's result to a `const` before its `var`; a probe's ReleaseSafe and
ReleaseFast assembly for that form is the same instruction for
instruction, and tools/emit-diff shows no other change to the modules'
Zig (below).

Debug builds, the same two compilers, interleaved under a timing claim:

- std.json parsing twitter.json 150 times (bench/json's program, built
  by `rig build` in debug), fastest of 12 each: main 897.8 ms, the
  branch 898.1 ms. Level.
- The worst case, a loop of nothing but an inlined fallible call
  (`t = step(t)!`, 200 million times), fastest of 15 each: main 1.288 s,
  the branch 1.452 s, 12.7% slower: Zig's Debug copies the `const` into
  the `var` at each call, which an optimized build removes. A program
  that does anything in its loop does not see it (std.json above).

A failure itself costs reading the debug information and the sites
files when it is shown, once, as the program ends.

## Tests

- New: test/cli/trace_build.sh, an executable's places after a later
  build of the same root, and embedded zero bytes; test/rig/errors-trace.rig.test, twelve cases: the sites of a
  plain failure (debug and release), `catch` dropping a handled failure
  and keeping one made in a handler with `errdefer` between, a closure
  and the function calling it, a task, a set's `wait_first`,
  `task.isolate`, `par.map`, an actor's method, nested tasks with and
  without seeds, the `(N more)` line, and a `defer` that catches. A unit
  test of `placeSites`.
- Updated to the new output: four cases' `stderr:` (errors-data
  467 and 478, runtime-misc 681, runtime-stack-guard 9), test/cli's
  exit_status.sh (two), std_shims.sh (one) and test_blocks.sh (three
  `rig test` reports), emit_shapes.sh's shape of an inlined fallible
  call, the ```stderr``` block of docs/learn/03-errors.md, and the `rig
  test` report in docs/learn/09-tests.md. SPEC §13's new example checks
  a trace through two functions.
- test/rig.rip: a case run in release expects its stderr without the
  trace's lines.
- Trig's tests read no Rig failure's output (grep of ~/Data/Code/trig's
  tests and tools for `error: `, read only).

## Verification

On the Mac, through `tools/heavy`, at the branch's last commit:

- `zig build` and `zig build test` pass.
- The areas touched (errors-trace, errors-data, runtime-misc,
  runtime-stack-guard, the docs SPEC, learn 00, 03 and 09, INTERNALS,
  the scripts exit_status, std_shims, test_blocks, units and
  emit_shapes) with `oracle` and `unit`, then the whole core suite,
  pass. The core suite's first runs found three of test/cli's reports
  to bring up to date, a split build that dropped the owner unit's
  sites (fixed, above), and units.sh's removing the objects a kept
  build's debug information lives in, so a second run printed no trace.
- After review: each finding has a case that failed first
  (test/cli/trace_build.sh for the older executable's places and the
  embedded zero bytes, which crashed `rig`; errors-trace's nested tasks
  without seeds; the deep trace and the `defer` that catches, which
  pass as SPEC now says), and the same gates passed again with the
  fixes and the function names.
- The release guards were measured before the review's fixes; those
  add nothing to a release build: the tables and `__rig_sites_of` are
  compiled only where traces are kept, and the runtime's new code is
  behind the same test.
- tools/emit-diff against main (a27de8024, whose changes since the base
  are docs only) differs in 36 of 38 programs, every difference
  explained: a table of sites (`__rig_sites`) at the end of each module
  with a site, and the list of modules (`__rig_sites_of`) in the root; the
  runtime's own files (rig/runtime.zig, rig/tasks.zig, rig/split.zig);
  and, in the modules, only `var __rig_v_N = f(...)` written as `const
  __rig_c_N = f(...); var __rig_v_N = __rig_c_N;` for each call that
  reaches an inlined fallible function (std.time's waits, ten lines in
  every program that uses it; one to eleven lines in a program's own
  module). The release guards above show that form costs nothing.
- Trig's tests read no Rig failure's output (grep of ~/Data/Code/trig,
  read only), so the trace's lines break none of them.

## Limits

- A trace needs the debug information: `rig build --strip` has none,
  and on the Mac it lives in the objects Zig left in the package, so an
  executable whose package was removed shows the `error:` line alone,
  as its panics show no Zig trace.
- Zig's trace holds 32 returns, the runtime's among them; a failure
  that made more shows the first 32 (the innermost) and a count, and
  in deep recursion `main`'s line is among those counted
  (errors-trace's deep case).
- A `defer` or `errdefer` that handles another failure with `catch` as
  the failure leaves drops the place it began: Zig's own trace does the
  same (a plain Zig program shows it), and SPEC §13 says so.
