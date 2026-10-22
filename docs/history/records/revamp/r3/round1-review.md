# PR #292 review, round 1 (head 82ff55a6e)

Reviewed: `git diff 8d41f719a 82ff55a6e` (warn, panic, nested quoting,
shortest floats, stdout flush before stderr, stack overflow abort).
Symbols ignored. Built in a detached worktree; every probe run with
`RIG_SANITIZE=1 bin/rig run`, and the output ones also built with
`--release` and `--release=fast`.

## Blocking

None found.

## Minor

### M1. `panic` as a name: a breaking change with uneven diagnostics (minor to medium)

`panic` is now a keyword. Fields, methods, and payload fields named
`panic` still work, and a parameter gets a clear message. Every other
position fails with a parser message that does not say why:

```rig
enum Level            # k1: "unexpected keyword `panic`; expected a member..."
  info
  panic
```
```rig
sub main()            # k3: "unexpected `=`; expected `(`"
  panic = 3
```
```rig
sub main()            # k16: "unexpected keyword `in`; expected `(`"
  for panic in [1, 2]
    print(1)
```
```rig
enum E                # k19: constructing works, the pattern fails
  a(panic: Int)
sub main()
  e = E.a(panic: 1)
  match e
    .a(panic) => print("x")
```
Also: a closure parameter `|panic: Int|` gives a bare "unexpected keyword
`panic`"; `use panic` (a module file `panic.rig`) gives "expected a name".
The enum variant case was supported before: the PR edits
`print_renamed_names.rig`, which used `K.panic`/`P.panic`. Only
`fun panic` has a reject test (`panic_reserved`). Fix: one
"`panic` is a keyword and cannot name a ..." message for each name
position (the parameter path already has one), with reject tests, or
allow `panic` as an enum variant like a field.

### M2. The panic location keeps a `./` prefix (minor)

```rig
# loc/a/b/main.rig
sub main()
  panic("here")
```
`cd loc/a/b && rig run ./main.rig` reports `./main.rig:2:3: panic: here`;
`rig run main.rig` reports `main.rig:2:3:`. A module does the same
(`loc2/main.rig` does `use m`, `m/b.rig` panics) and prints `./m/b.rig:2:3:`.
Cause: `fromPackageRoot` in src/main.zig returns the path unchanged when
the root is `.`. SPEC says the file is named from the package root.

### M3. A printed F32 max does not read back (minor)

```rig
sub main()
  a: F32 = 3.4028235e38      # rejected: "float literal does not fit in F32"
  b: Float = 1.7976931348623157e308
  print(a, b)
```
`print` of F32's largest value writes `3.4028235e38`; the runtime comment
on `writeFloat` says the output reads back as a Rig literal of the same
value. Either the literal check should round to F32 first (3.4028235e38
rounds to F32 max) or the comment should drop the claim.

### M4. `flushOutput` is dead, and its comment describes code that does not exist (minor)

`pub fn flushOutput` in src/runtime.zig has no caller. Its comment says the
standard library flushes stdout before it reads stdin or starts a
process; std does neither. This breaks AGENTS rule 7. Remove it, or add it
with its first caller.

### M5. `warn` with stderr closed ends the program silently (minor)

```rig
sub main()
  print("a")
  warn("w")
  print("b")
```
`rig build` then `./prog 2>&-`: prints `a`, exits 1, no message, `b`
never prints. `stderrFailed` exits 1 on any error but a broken pipe. SPEC
§Output describes only stdout failures, and no test covers this. `fail`
ignores stderr errors, so `warn` and `panic` treat a lost stderr
differently. Decide (ignore the error, as `fail` does, or exit 1 as now),
then document and test it.

### Note (not a regression)

`rig run` still prints `error: rig: the program was killed by signal 6`
after every panic. The harness strips it (`stderr_shown`); a user sees it.

## Verified clean

- panic as a statement, ternary and if/match branch, block match arm with
  a panic tail, right of `??`, `catch |e|`, destructuring fallback, while
  and for value-loop `else`, guard form, inside `raw`, stack and owned
  closures, compile-time-parameter funs, a fun's tail, `-> (Int, Int)`.
- Rejections: panic as a value, an argument, a `return` operand, a module
  constant, in `defer`/`errdefer`; `panic()` ("needs a message"); a
  generic T holding `[]U8` in panic and warn (`printable` requirement).
- Ownership: moves in panic branches, use-after-move after them still
  caught; owned locals, defers, drops in loops and labeled continues:
  no leaks or freed-memory use under the sanitizer.
- Debug, `--release`, `--release=fast` print the same for nested quoting
  (List, object, enum payload, box, shared, Cell, deep arrays,
  `String(...)`) and floats (0.1+0.2 constant and runtime, F32, -0.0,
  subnormals, the 1e21 and 1e-6 edges).
- Stack overflow: status 134 in every mode, with a trace only in debug.
- panic in a `test` block: FAIL, the count, status 134; `rig test` paths
  are from the package root.
- A user `sub warn` hides the builtin. A field or method named `panic` works.
- test/run: ```` ```stderr exit=N ```` doc blocks become
  `# expect-stderr:`/`# expect-exit:`; the new SPEC and STD claims about
  stderr and exit status are each checked by a doc block or a cli test.

Probes: `$SP/p/` (k*, f*, w*), `$SP/loc/`, `$SP/loc2/`, where
`$SP=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad`.
