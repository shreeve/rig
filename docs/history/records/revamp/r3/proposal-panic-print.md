# Proposal: `panic`, `warn`, and `dbg` beside `print`

Design study, 2026-10-16, for Trig NEEDS 15 (*"A `panic`. `go_panic` indexes
an empty array as a stand-in."*) and the owner's question: settle on `print`
and `panic`, plus what? Nothing here is built, and nothing is decided. Every
spelling is the owner's to choose. Any change to `docs/CORE.md` goes through
the owner's expert process.

Five reviewers answered independently:
- a language designer;
- a Rust/Zig systems programmer;
- a Ruby/Python/Perl programmer;
- a reader of typecheck and the ownership checker;
- a compiler engineer on the Zig 0.17 lowering.

Their reports are in the session scratchpad, `reports/panic/{designer,systems,scripting,ownership,compiler}.md`, and their probes are in `probes/panic/<role>/`. Every probe ran against `a5a991366` with Zig 0.17.0 on the Mac, and nothing ran on Linux. Examples marked *proposed* use forms that do not exist yet and were not run.

---

## 1. Recommendation

**Four names, each with one job.** All five reviewers reached the same set
independently.

| Name | Job | Writes | To | Gives back |
|---|---|---|---|---|
| `print(a, b, ...)` | program output (unchanged) | values, spaces, newline (SPEC §17) | stdout, buffered | nothing |
| `warn(a, b, ...)` | a note to the person running it; the program goes on | exactly `print`'s line | stderr, after flushing stdout | nothing |
| `panic(a, b, ...)` | a bug: stop now | `file.rig:L:C: panic: ` then `print`'s line | stderr, after flushing stdout | never (`noreturn`) |
| `dbg(e)` | look at one value without disturbing it | `file.rig:L:C: <source of e> = <value, quoted>` | stderr, after flushing stdout | `e` itself |

**`print` does not cover Ruby's `p`.** All five reviewers say so, and the probes show four reasons:
- it returns nothing, so `x = print(1)` is rejected and `print` cannot wrap a subexpression;
- a top-level string is unquoted, so `print("1")`, `print(1)`, `print("none")` and `print(none)` look alike, and `print("")` vanishes;
- it writes to buffered stdout, mixed with the program's real output;
- it shows neither where it was called nor what expression it printed.

`dbg` is the owner's combination of `p` and `dbg!`:
- from `p`, the quoted, readable value;
- from `dbg!`, the location and the source text;
- from both, the argument handed back.

**Nothing else.** These were all considered and left out:
- `abort`, `die` and `fail`: `panic` covers them, and `fail` already means a `T!` failure in Rig.
- `exit(n)`: `fun main() -> Int` already gives a status, and an exit in mid-program would skip drops and the leak check.
- `assert`: `panic("n must be positive:", n) if n <= 0` already parses through the postfix guard. An `assert` would also raise a debug-only-or-always question that Rig has no other reason to answer.
- `unreachable`: it is undefined behaviour in Zig's fast mode (probed: it silently returned the wrong value), so Rig must never take the name or the lowering.
- `todo` and `unimplemented`: write `panic("todo: ...")`.
- `p` and `pp`: see decision 1.
- `@dbg` and `@line`: "`@` asks the compiler about a type", and these do work at run time.

**Every panic is the same event.** That covers a user's `panic(...)` and the runtime's own (an index out of range, overflow, a bad cast, running out of memory). Each one:
1. flushes stdout;
2. writes one report to stderr;
3. runs no drop, no `defer` and no leak check;
4. ends the process with one status, the same in every build mode.

The status is decision 3.

**Two rounds, after three small prerequisites (§7).** Round A is `panic` and `warn`. Round B is `dbg`, which changes typecheck's classification of expressions, so it runs the full matrix and is the only ownership branch open while it runs.

---

## 2. The owner's decisions

Each decision gives the options and a recommendation. The spellings are the
owner's.

### Decision 1: the debug form's name. Recommend `dbg`.

- **`dbg`.** It collides with no name in the repo or in Trig. Its odd spelling is useful: it marks a line that is meant to be deleted, and a grep finds every leftover. Rust (`dbg!`) and Elixir (`dbg/2`) mean the same thing by it.
- **`p`.** It is Ruby's name, and two letters long. But `p` is one of the most common local names in Rig code (`p = Point(...)`). By the reviewers' counts:

  | Where | Bindings named `p` |
  |---|---|
  | this repo | about 1,750–1,950 |
  | Trig | about 100–125 |

  Built-ins are "called by name unless a declaration hides it" (sema.zig:4096). So `p(x)` would fail in exactly the parser and checker code where it is most wanted, with "`p` has type `Point` and cannot be called". If `dbg` becomes a reserved form (decision 6), `p` would have to be reserved too, which breaks every one of those programs.

All five reviewers recommend `dbg`.

### Decision 2: `print` and `warn`, or `stdout(...)` and `stderr(...)`. Recommend the verbs.

- **The case for the verbs.** `print` and `warn` say what the call is for. `stdout` and `stderr` name places, and a name for a place reads as a value: `stdout(x)` looks like a conversion, and `stdout.write(x)` is what a reader would expect it to be.
- **Where the place names belong.** They are better kept for `std.os` stream objects: `os.stdout.write(bytes)` for raw bytes, flushing, and binary output, none of which `print`'s formatting serves.
- **Precedent.** Ruby and Perl mean exactly this by `warn`.
- **One caution, which SPEC should state in a sentence.** In Python (`warnings.warn`) and in log APIs (Zig's `std.log.warn`), `warn` is a filtered level. In Rig it is "`print` to stderr", with no level, filter or once-only behaviour.

The foreman gave the owner the same view.

### Decision 3: a panic's exit status. Recommend 101, by a 1–4 split (see §3).

These are the options:
- **134 (SIGABRT, an abort).** This is what runtime panics give today in debug builds, and four reviewers favour it:
  - a parent can tell a signal from any status `main` returns;
  - a debugger stops at the abort;
  - crash reporters record it;
  - `test/README.md` already defines a Rig panic as "an abort (signal 6) after its `panic:` report".
- **101 (an exit after flushing).** Rust uses this status when it unwinds. The compiler reviewer favours it, with measurements:
  - Each abort on macOS writes a crash report. 196 `__rig_main-*.ips` files already sit in `~/Library/Logs/DiagnosticReports` from test runs.
  - `rig run` prints "the program was killed by signal 6" after every panic.
  - Dying takes 14.1 ms by abort and 6.0 ms by exit.
  - An exit cannot hit the release-mode segfault in §7, because no unsafe stack walk runs.
- **1** is rejected by all five. It already means an error that left `main`, a leak, or a failed test.
- **2** is rejected by all five. It is the common status for a usage error.

**Recommendation: 101, for every panic, in every mode.** The reasons:
- A panic is a reported, deliberate stop, not a crash.
- The crash-report noise is real. Every expected-panic test in the suite produces one.
- One status in every mode and on every platform is the simpler rule.

The costs, stated plainly:
- A debugger needs a breakpoint on the runtime's `fail` and `panicAfterFlush`.
- `fun main() -> Int` could return 101 itself.
- `test/run` (lines 455–461), `matrix.py` and `test/README.md` must change in the same round as the runtime.

If the owner prefers 134, the rule must still hold in `--release`, which today it does not (§7).

### Decision 4: `panic`'s arguments. Recommend `print`'s list.

The owner wrote `panic("msg")`. All five reviewers recommend `print`'s argument list: `panic("bad kind:", k)`, one or more values, formatted as `print` formats them.
- `panic("msg")` is the one-argument case, so the owner's form is unchanged.
- Rig has no string interpolation. Trig builds `go_panic(String("path must be rooted: ", path))` at 8 sites, allocating a String only to stop.
- `print`, `warn` and `panic` then share one argument rule (`checkFormatArgs`) and one set of rejections.
- `panic()` with no arguments is rejected by four of the five: "`panic` needs a message: say what went wrong". The systems reviewer would allow it.
- `warn()` should write an empty line, as `print()` does, because the owner's rule is that `warn` is identical to `print`.

### Decision 5: user functions that never return. Recommend none.

All five reviewers recommend this. It means no `-> Never` type, and no wrapper like `go_panic` that the checker treats as stopping.
- **No silent control flow.** A call `fail(msg)` that never returns looks exactly like a call that does. `panic` is the one visible word, as `return` is.
- **The structure.** "This statement leaves" would come to depend on a callee's signature, perhaps in another module. That fact would then be threaded through `shapeOf`, emit's terminators and the oracle.
- **Trig does not need it.** Its `go_panic(...)` calls become `panic(...)`, and its 10–11 `go_panic` declarations are deleted. Go's `AssertNever`-style helpers become helpers that *return the message*: `panic(bad_kind_msg(node))`.
- **Today's wrappers stay `Void`.** typecheck.zig:12860 maps a noreturn body to Void, so a kept `go_panic` wrapper would still need its dummy return values.

If a real program later fails for want of one, the design is a written `-> Never`, with a body proof.

### Decision 6: is `panic` a keyword or a call? Recommend a reserved form with its own IR node.

The reviewers split three ways.

| View | Who | Consequence |
|---|---|---|
| A keyword form `panic(...)`, with its own IR node like `return` | ownership | "leaves" stays a fact of syntax |
| A built-in call, reserved (it cannot be declared) | systems | name resolution must recognise it at each site |
| A built-in call that a declaration hides, as `print` is | scripting, designer, compiler | a user `sub panic` silently changes which code is unreachable |

**Recommendation: the keyword form.** The ownership reviewer found ten sites that decide "this statement leaves" from syntax kind:
- sema: `shapeOf`/`yieldsValue`;
- typecheck: `yieldsNoValue`, the last-statement exemption in `checkBody` at :723, and `hasEffect`;
- ownership: `checkAfterJump`;
- emit: `isTerminatingStmt`, `emitValueBody` and the jump arm;
- the oracle: two sites.

A call-shaped `panic` needs a fact threaded to every one of them. As a form it needs one line, `.panic => .jump` in `shapeOf`. Those sites should also be folded into one `sema.leaves(s)`, so siblings cannot drift. That is fixing the class.

The written form is exactly `panic(...)` either way. `x.panic` stays a legal member name ("every keyword but `if` may name a member"). One existing test declares `fun panic(n: Int)` (test/behavior/emit/emitter_reserved_names.rig) and would change.

`warn` stays an ordinary built-in that a declaration hides, as `print` is. `dbg` follows decision 7: reserved if it is a form, hidden by a declaration if it is a call.

### Decision 7: what `dbg(e)` means for ownership. Recommend "`dbg(e)` is `e`".

This is the main disagreement.

**(a) The generic identity** (scripting, designer, compiler).

`dbg(e)` is checked as a call to `fun dbg[T](x: T) -> T`. Three reviewers ran a user-written identity function, and it behaves as wanted:
- `dbg(3)` copies;
- `dbg(<v)` moves through;
- `dbg(?v)` lends.

It needs no new ownership rule. The cost is that a bare owner is rejected everywhere, as a statement too. `dbg(xs)`, the most common debug line there is, draws "write `dbg(?xs)` to look at it, or `dbg(<xs)` to move it through". That is Rust's `dbg!(&x)`.

**(b) `dbg(e)` is its operand** (systems, ownership).

`dbg(e)` is a one-leaf branching form: Hands `.branches`, and one entry in `sema.valueParts`. It hands over what `e` hands over:
- A statement `dbg(xs)` only reads, under CORE sentence 1 ("a bare name only reads"), so Ruby's `p xs` habit just works.
- `print(dbg(v).len)` reads in place.
- `y = dbg(v)` is rejected exactly as `y = v` is.
- `dbg(<v)`, `dbg(+v)` and `dbg(?v)` mean what they say.

It changes a soundness classifier. Lowering a place needs its address computed once, as a recorded storage fact, so that `xs[f()]` does not call `f` twice. One corner follows from CORE §3's branch rule: `size(dbg(v))`, for a `?List` parameter, asks for `dbg(?v)`, although `size(v)` needs no `?`.

**Recommendation: (b).** The user's rule is then one sentence: **`dbg(e)` means `e`, and also writes a line to stderr.** It also matches the owner's mental model: `dbg` is `print` that gives its value back, and `print(xs)` needs no `?`. Under (a), `dbg(xs)` fails where `print(xs)` works, and that is the surprise the owner's POLS rule warns against.

(b) costs a classifier round, so:
- it lands as its own round, with the full matrix and a new grid over `dbg(e)` for every form and context;
- if it needs a second soundness round, it stops (AGENTS) and falls back to (a), which is already proven by probes.

Both views agree on these points:
- `dbg` takes exactly one value;
- `dbg(!v)` is rejected;
- `dbg(...)` is a value, not a place;
- `dbg` stays in every build mode. Stripping it would change what runs, and rejecting it would make `rig check` depend on the mode.

### Decision 8: where a panic may stand. Recommend a positive list.

**Recommendation (ownership, compiler, systems): as a statement, or as a value leaf.** The value leaves are the set `sema.valueLeaves` already defines:
- the right side of `??`;
- a `catch` handler;
- an `if`/`else` branch, block or ternary;
- a `match` arm;
- a block's or function's last value.

Everywhere else it is rejected: an argument, an operand, a binding, a `return` or `break` value, a list element. The message would be: "`panic` ends the program and gives no value, so it stands as a statement or as a branch's value".

Zig itself rejects `return @panic(..)`, `const y = @panic(..)` and `break :blk @panic(..)` as "unreachable code". The designer and the scripting reviewer would allow `panic` wherever a call can stand.

**A side question.** `n if c else panic("neg")` would be accepted, but `n if c else return 0` is a parse error today (INTERNALS `NULLISH_JUMP`). For least surprise, `return` might join `panic` there. That would be a separate small change; I recommend asking it after round A.

### Decision 9: the report's shape. Recommend Rig's diagnostic shape.

**The recommended shape (scripting, designer, compiler):**
- `main.rig:12:5: panic: bad kind: .ident`
- `main.rig:9:16: width(?cfg) = 3`

**The alternatives (systems, compiler):** `panic: msg` followed by `  at main.rig:12:5`, and Rust's `[main.rig:9:16] width(?cfg) = 3`.

The `file:line:col:` prefix matches Rig's own diagnostics, and terminals and editors open it with a click.

**The Zig stack trace.** Two reviewers recommend printing it in debug builds only, with the safe unwinder, and printing none in release. A trace names emitted Zig lines, never Rig lines, and in release the unsafe unwinder is what segfaults. A `RIG_BACKTRACE=1` switch can come later if wanted.

Runtime panics don't know their Rig location yet (ROADMAP, "Traces in Rig terms"). They print `panic: index out of bounds` as today, without Zig's `thread N` prefix.

---

## 3. Where the experts disagree

| Question | Positions | Recommendation |
|---|---|---|
| Exit status | 134 (designer, systems, scripting, ownership); 101 (compiler) | 101 for every panic (decision 3) |
| `dbg` and ownership | identity call (scripting, designer, compiler); "is its operand", a one-leaf branch (systems, ownership) | "is its operand", with identity as the fallback (decision 7) |
| `panic`'s shape | keyword form (ownership); reserved call (systems); a call a declaration hides (scripting, designer, compiler) | keyword form (decision 6) |
| CORE sentence placement | end of sentence 3 (designer, ownership); beside `defer` in §7 (systems); sentence 10, "a panic is not a failure" (scripting, compiler) | end of sentence 3 (§5) |
| Where `panic` may stand | statement or value leaf (ownership, compiler, systems); anywhere a call can (designer, scripting) | statement or value leaf (decision 8) |
| `panic()` with no arguments | rejected (four); allowed (systems) | rejected |
| Location format | `f:L:C: panic: msg` (three); `panic: msg` plus `at f:L:C` (systems); `[f:L:C]` for `dbg` (systems, compiler) | `f:L:C:` everywhere (decision 9) |
| Can `dbg` be hidden by a declaration? | reserved (ownership); hidden (scripting, compiler) | follows decision 7: reserved if it is a form |
| `print`'s nested strings | escape them (scripting, compiler); leave `print` alone (designer) | escape them, as a small separate round (§7) |

**Where the reviewers disagreed with the brief:**
- **"Rig has no stderr output" is true only for user code.** The runtime already writes `error: Set.name` and its panic reports to stderr.
- **"FullPanic aborts" is true only in debug** (§7).
- **The dummy return values need direct calls.** They go away only where Trig calls `panic` itself; a kept `go_panic` wrapper stays `Void` (decision 5).
- **The message is lost today.** Trig's `go_panic` never prints its message, so every Trig panic today reports only "index out of bounds".

---

## 4. The desugaring

These are written for `docs/INTERNALS.md`, which requires that a feature touching ownership states its desugaring into existing forms.

**`panic(a, b, ...)`** is a jump that leaves the program:
- It is a form `(panic args...)`. Its type is the existing `noreturn`, and its Hands kind is `.jump`, as for `return`, `break` and `continue` (typecheck.zig:4057).
- It already fits the type rules:
  - `meets()` accepts `noreturn` for any expected type (typecheck.zig:13162);
  - a join takes the other side's type (:12426);
  - `checkBody`'s last-statement exemption (:723) becomes "the last statement leaves".
- The arguments are walked exactly as `print`'s are (ownership.zig ~4342): read in place and held for the call. A moved argument is accepted, as `print(<s)` is.
- Then `reachable = false`, with **no `exitTo`**: no defers are re-checked and no loans reported. This is not a path out of a scope; no code runs after it. `join` already ignores an unreachable side (ownership.zig:1491), so `w = if c: <v else: panic(..)` followed by `print(v)` is "use of `v` after move", as it is today with `return` (probe r03).
- A statement after it is rejected: "unreachable code: this statement follows a `panic`" (ownership.zig:6014's rule, keyed on `leaves`).
- Lowering: `rig.fail(comptime "main.rig:12:5", .{ a, &b })`, through `emitPrintArgs` so it follows `print`'s by-address rule. `fail` is `noinline` and `@branchHint(.cold)`. It does the following, in order:
  1. writes `FAIL test "x": panic` if a test is running;
  2. flushes stdout;
  3. locks stderr through `std.debug.lockStderr` with a 1 KiB stack buffer;
  4. writes the location, `panic: `, and the arguments with `print`'s loop factored out (`writeArgs`), then a newline;
  5. exits with decision 3's status.

  It allocates nothing. In ReleaseFast its hot-loop cost is identical to `@panic`'s: one test and one branch (probed, asm). It never lowers to Zig `unreachable`.
- **`defer` and closures.** `panic` is allowed inside `defer` and `errdefer`, as Zig allows `defer @panic(..)`. The ownership reviewer names a `defer` that panics only on a condition, checked at every kind of exit, as the case to test hardest. A closure body that is only a panic infers `Void`, as one that is only `return` does. Generics and `raw` need nothing special.

**`warn(a, b, ...)`** is `print` with another writer. It is checked by `checkFormatArgs`, walked as `print` is, and lowered as `rig.warn(.{...})`, which:
1. flushes stdout;
2. writes one locked, buffered line to stderr.

The flush keeps `prog 2>&1` in program order, which Ruby, Python and Perl all get wrong (probed). Without it Zig reorders the output (probed). It costs nothing on a tty, where `print` has already flushed. In the worst case, a `warn` after every `print` into a pipe, it is 84% slower (probed).

**`dbg(e)`**, as recommended in decision 7, is a one-leaf branch over `e`:
- **`e` fresh** (a call, a literal, `<x`, `+x`): `t = e; show(?t); <t`. The temporary is the checker's own, so emit adds none.
- **`e` a place, read in place:** its address is computed once (a storage fact the checker walks as a hold), its value is shown, and the place is read.
- **`e` a lend** (`?x`): the view is shown through.

Lowering: `rig.dbg(comptime at, comptime src, ...)`. `src` comes from the span (`diag.textOf`, as `spanText` in ownership.zig:4720), and emit needs the module's path (`em.path`, main.zig:731).

The value is written in `print`'s nested form, with escaping (§7). The compiler reviewer rejected a `&place` lowering that reads the place twice, because it breaks "the checker checks exactly what is emitted". The storage-fact lowering above avoids that. Under fallback (a), the lowering is the generic call `rig.dbg(at, src, T, arg)`.

---

## 5. Core impact

CORE never mentions a panic, and SPEC does not say what a panic skips. Yet every runtime panic already behaves as follows (probed by all five):
- stdout is flushed;
- no drop or `defer` runs;
- no leak check runs.

That gap exists without this proposal.

**Recommended: one sentence, at the end of sentence 3 (drop points).**

> A panic ends the program where it stands: its output is flushed, and no
> drop, `defer`, or leak check runs.

Sentence 3 is where a reader asks when values are dropped. Sentence 3's own rule stays true, because a panic does not end a scope; it ends the process.

The alternatives:
- **Sentence 10:** "A panic is not a failure: it cannot be caught". This rightly separates `panic` from `e!`, but sentence 10 is about failure, and a panic is not one.
- **§7, beside `defer`:** this placement answers "does my `defer` run?" where the reader looks.

Either could carry a cross-reference.

The following go with it. None of them is a Core change.
- **SPEC §1:** "Everything `main` owns is dropped, its output flushed, and the leak check run before the program exits" gains "unless it panics".
- **SPEC §17** becomes "Printing and stopping" and documents all four names.
- **SPEC §13** gets one line: a panic is not an error, and `catch` never sees it.
- **AGENTS, "runs clean":** a program that panics is judged by `# expect-panic:`, never as leak-free. A panic must never read as a way to hide a leak.
- **CORE §9 and INTERNALS:** the jumps are `return`, `break`, `continue` and `panic`, and AGENTS' "leaving a scope never silently forgets a loan" does not apply to a panic, because no code runs after it.
- **`dbg`:** under decision 7 (b), `dbg` is an instance of CORE §3's "a branch is a value, never a place", with one leaf. It adds no Core sentence, only its desugaring in INTERNALS.

---

## 6. Size

| Round | Contents | Size (reviewers' estimates) | Gate |
|---|---|---|---|
| 0a | Fix the release-mode segfault (§7) | small; under way as its own round | fast gate |
| 0b | Record "is this `print`" once as a fact. Today it is matched by name at five sites: typecheck ×2, storage.zig:78, ownership.zig:4725, and the oracle. | ~30 lines | full matrix: a classifier |
| 0c | Harness: `# expect-stderr:` for tests and a ```` ```stderr ```` fence for doc examples. Today only `# expect-panic:` reads stderr. | ~40 lines | fast gate |
| A | `panic` and `warn`: grammar form; `sema.leaves`; typecheck (positions, `checkBody`, diagnostics); ownership; emit; runtime `fail`/`warn`/`writeArgs`; storage; oracle; decision 3's status in `panicAfterFlush` and the harness; docs; about 15 behaviour and 12 reject tests | 170–450 lines. The low figure is code only, the high one includes tests and docs; ~250 code plus tests is the middle | full matrix (it touches ownership.zig) |
| B | `dbg`: a `valueParts`/Hands entry, a storage fact, emit, runtime, a grid over `dbg(e)` for every form and context | 110–200 lines | full matrix; the only ownership branch open |
| C | `print` escapes nested strings (`std.zig.fmtString`); `dbg` needs it | ~5 lines plus doc outputs | fast gate |
| — | `rig test`: a panic prints its FAIL line and a summary before it exits (today it gives neither) | ~10 lines | fast gate; can ride with A |

**Risks named by the reviewers:**
- **A missed "leaves" site.** Zig then reports "unreachable code" for a program Rig accepted, which breaks Rule 2. Fold the sites into one `leaves` function, and add a matrix form for panic in each value leaf and each context.
- **A `defer` that panics only on a condition**, at every kind of exit.
- **A temporary made only on the panic path,** as in `o ?? panic(String("bad ", k))`: its alive flag and its never-run drop.
- **The status change.** It must land together across the runtime, `test/run`, `matrix.py` and the corpus expectations.
- **`dbg`'s place lowering.** It must evaluate the place once, without a temporary the checker did not walk.

---

## 7. Findings outside the design, to fix regardless

1. **A runtime panic in `--release` can segfault (exit 139), not abort.** This was found by the systems and compiler reviewers and confirmed again here.
   - What happens: Zig's `defaultPanic` unwinds with `allow_unsafe_unwind = true` (std/debug.zig ~603), and the walk faults on the program stack the runtime maps (`onOwnStack`, runtime.zig:3108). lldb shows `EXC_BAD_ACCESS` in `debug.writeCurrentStackTrace`.
   - With `own_stack = false`, the same program gives 134.
   - The fault depends on the panic site:

     | Panic | `--release` exit |
     |---|---|
     | `List` index (`v[i]` past `v.len`) | 139 |
     | fixed-array index (`xs: [0]Int`, `xs[k]`) | 134 |
     | overflow | 134 |

   - So test/README's "a Rig panic is an abort (signal 6)" is false in release today, and a `# release` + `# expect-panic` test can pass on a segfault.
   - The foreman says a fix round is under way. Either status in decision 3 removes the cause: exit 101 runs no unsafe walk, and 134 needs the safe unwinder or no trace in release.
2. **`print` does not escape nested strings.** `print(["a\"b", "c\nd"])` writes raw quotes and a raw newline, so the nested form is not yet unambiguous. Round C above.
3. **Trig's `go_panic` never prints its message,** so every Trig panic today reports only "index out of bounds".
4. **"Is this `print`" is decided by name at five sites.** Round 0b; it should come before three siblings join it.
5. **macOS crash reports.** Each abort writes a `.ips` file, and 196 have built up from test runs. This is relevant to decision 3 whichever way it goes.

---

## 8. What it unblocks for Trig

- **NEEDS 15 closes.** By my count there are 144 `go_panic(` calls in 30 files under `trig/src` (155 with `tools/`). They become `panic(...)`, and the 10–11 duplicated `sub go_panic` declarations are deleted.
- **The dummy return values go.** About 40 directly follow a `go_panic` (my heuristic; the reviewers' fuller count is about 60), such as `RootedPath(String())`, `""` and `0`. Once the calls are `panic`, each dummy becomes "unreachable code: this statement follows a `panic`", so the compiler lists every one to delete.
- **The messages get cheaper.** The 8 `go_panic(String("...: ", x))` messages become `panic("...:", x)`, with no allocation.
- **Panics say what went wrong.** Today Trig's panics report "index out of bounds" from inside `go_panic`. With `panic` they report `file.rig:L:C: panic: <message>`.
- **Compact optionals get their fallback.** `n ?? panic("...")` is the honest fallback for the `deref`/`deref_list` sites in proposal-compact-optionals.md, with no dummy `Node(id: 0)`.
- **`match` defaults read naturally.** `_ => panic("printer: unexpected MemberName", kind)` reads as Go's does.
- **Diagnostics can go to stderr.** `warn` gives Trig's command-line driver stderr output without `raw`.
- **Porting gets `dbg`,** which can wrap any subexpression while debugging a port against Go's output.
- **Two notes for Trig's future:**
  - `docs/lexer/NOTES.md` says "a pure core must not print". A panic's report is the runtime's, not the core's, so this is no conflict.
  - On a later `wasm32` target (NEEDS 9), `fail` needs a host hook in place of stderr and exit. That is a runtime detail, and nothing in this design blocks it.

## Owner decision, 2026-10-16: the exit status is 134

A panic exits with 134 (abort, SIGABRT) in every build mode, matching Zig's `@panic` (probed: Debug, ReleaseSafe and ReleaseFast all exit 134) and C's `abort`. 101 is rejected. The macOS crash-report noise is handled separately, in the test harness or cpuq, not by changing the status.
