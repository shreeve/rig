# Rig test suite

```bash
./test/run                 # everything (parallel)
./test/run ownership       # only tests whose id contains "ownership"
./test/run -v known/emit   # list each result, including known failures
./test/run --update ir     # rewrite IR snapshots after an intended grammar change
```

The summary line reads `N passed, M failed, K known`. The suite is green
when nothing fails and no known-failing test has started passing.

## Layout

| Path | Contract |
|---|---|
| `test/behavior/<area>/<name>.rig` | `rig run` exits 0, no leaks, stdout equals the `# expect:` block |
| `test/reject/<area>/<name>.rig` | `rig check` exits non-zero with a `file:line:col` diagnostic containing each `# error:` text |
| `test/known/<area>/<name>.rig` | a known bug, written as a behavior or reject test of the *correct* behavior |
| `examples/<name>.rig` | curated showcase programs; same contract as `behavior/` |
| `test/ir/<name>.rig` | raw and semantic IR snapshots (`<name>.raw.sexp`, `<name>.sem.sexp`) |
| `test/torture/<name>.rig` | bad input: must be rejected with a diagnostic, never crash the compiler |
| `unit` | `zig build test` |
| `parser` | `src/parser.zig` matches what Nexus generates from `rig.grammar` |

Areas: `syntax`, `types`, `effects`, `ownership`, `emit`, `runtime`, `modules`.
A multi-file test is a directory `<name>/` with an entry `main.rig`; the
directives go in `main.rig`.

One file per test, discovered automatically; there is no list to edit.

## Directives

Directives are whole-line comments.

```rig
sub main()
  print 42
  print "done"

# expect:
# 42
# done
```

- `# expect:` starts the expected-stdout block. Each following `#` line is
  one line of output (`# ` is stripped; a bare `#` is an empty line). The
  block ends at the first non-comment line. With no block, stdout must be
  empty.
- `# expect-panic: <text>` — the program must exit non-zero with `<text>`
  on stderr. An `# expect:` block, if present, still checks stdout.
- `# error: <text>` — makes the file a rejection test. Repeat the line to
  require several diagnostics.

## Leak checking

`rig run` builds in Debug mode, where the runtime allocates through
`std.heap.DebugAllocator`. The emitted `main` defers `rig.checkLeaks()`,
which prints each leaked allocation with a stack trace, then
`error: rig: memory leak detected`, and exits 1. Double frees panic in the
allocator. A behavior test therefore fails on any leak or double free.

## Known bugs

`test/known/` is the work queue. Each file is written as a behavior or
reject test of the correct behavior, and its header also says what goes
wrong today. Fix the bug, run the suite, and the test reports `FIXED`;
move it into `test/behavior/` or `test/reject/` under the same area in
the same commit, and drop the note about the bug from its header: tests
outside `known/` describe current behavior only.

## Output

`rig run` writes emitted Zig to `$RIG_OUT_DIR` when set. The suite uses
`.zig-cache/rig-test/<id>/`, so emitted code for a failing test can be
inspected there, and repeated runs hit Zig's build cache.
