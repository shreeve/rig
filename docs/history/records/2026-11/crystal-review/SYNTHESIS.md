# Crystal, through five lenses: what Rig could take

This review was read-only, on 2026-11-04, of Crystal 1.23.0-dev at `~/Data/Code/rig/misc/crystal` (c6965f222). It had five experts: Ruby, Zig, Rust, Swift and Go. Each read Crystal's compiler and stdlib and Rig's docs on origin/main. Nothing was built or timed. Their reports sit beside this file, with `path:line` citations: ruby.md, zig.md, rust.md, swift.md, go.md.

I checked against origin/main that none of the ideas below exists in Rig today:
- no `yields` functions;
- no `$fields`;
- no flag-set type;
- string literals end on their line (SPEC "String literals");
- `MADV_NOHUGEPAGE` is set on tables and large heap blocks, but not on task stacks.

## Scores (1–10)

| Area | Ruby | Zig | Rust | Swift | Go | Mean |
|---|---|---|---|---|---|---|
| Syntax | 8 | 8 | 8 | 7 | 8 | **7.8** |
| Standard library | 8 | 7 | – | 8 | – | **7.7** |
| Operators | 7 | 7 | 7 | 6 | 7 | **6.8** |
| Channels / select | 7 | 6 | 7 | 7 | 6 | **6.6** |
| Type system | 7 | 6 | 6 | 7 | 7 | **6.6** |
| Object system | 7 | 6 | 6 | 6 | 7 | **6.4** |
| Concurrency | 6 | 6 | 5 | 5 | 5 | **5.4** |
| Grammar | 5 | 5 | 5 | 5 | 5 | **5.0** |

Areas only one or two experts scored:
- C interop 8 (Zig)
- API design 7 (Swift)
- scheduler and engine 7 (Go)
- macros 7 (Ruby) and 5 (Zig)
- error handling 5 (Rust)
- tooling 5 (Go: formatter 9, compile speed 3)
- cost model 4 (Zig)
- safety 4 (Rust)
- memory per fiber 4 (Go)

**What they like:**
- Crystal reads like Ruby, with nil safety checked at compile time.
- Union types with flow typing feel dynamic.
- A stdlib whose every doc comment has a runnable example.
- Checked arithmetic, with explicit `&+` for wrapping.
- Good event loops (epoll, kqueue, io_uring, IOCP).
- An engine nearly line for line from Go.
- A formatter with no options.

**What they don't:**
- **Whole-program type inference:** slow builds, errors far from their cause, nothing checked one module at a time.
- **Unions** that widen silently and dispatch on a type id at run time.
- **Concurrency without ownership:** nothing prevents a race, and a race can tear a union into type confusion.
- **`spawn` with no owner:** an exception in a fiber is printed and dropped, and a block captures loop variables by reference (`55555`).
- **Silent copies:** a mutable struct passed to a method is copied, and the write is lost.
- **Global meaning:** open classes and `method_missing`.
- **Two languages in one:** text macros with `run` subprocesses.
- **A hand-written grammar:** a 6.6k-line parser where spacing decides parses (`foo -1` against `foo - 1`).
- **Hidden costs:** a GC, captured locals on the heap, and exception landing pads.

**Where Rig is already ahead:**
- Ownership and race freedom.
- Structured tasks.
- Failures as values with visible `!`.
- Sound field narrowing: `if ?@f as x` freezes the field. Crystal narrows only locals, so its own compiler calls `not_nil!` 213 times.
- No GC.
- A generated grammar with no LALR conflicts.
- One `match`.

## Ideas worth taking, by how many experts found them

| # | Idea | Found by | Rig form | Kind |
|---|---|---|---|---|
| 1 | **Inlined yielding functions:** user-written `for` sources whose body is inlined at each `yield` | Ruby, Rust (Zig: measure closure inlining) | `fun leaves(?@) yields ?Node` … `for n in t.leaves()` | language feature: design round, CORE paragraph |
| 2 | **`$fields(T)`:** a loop over an object's fields at compile time | Ruby, Zig | `for f in $fields(T)`, unrolled by Rig before the checkers run (not by Zig's `inline for`) | language feature: design round; std.json's typed decode needs it |
| 3 | **A flag set of an enum** | Rust, Swift | `a: Bits[Access] = Bits(.read, .write)`, `a.has(.write)`, `!a.add(.exec)`, `a \| b`, `for m in a` | new std type; the name is the owner's (`Bits`, `Flags`, `EnumSet`); Trig has 2,503 hand-written `flags & X != 0` tests |
| 4 | **A failure's trace, in debug builds** | Rust | `error: E.name` plus each `f()!` site it passed through (Zig's error return trace) | runtime and diagnostics; no syntax |
| 5 | **`dbg(e)`** | Ruby | prints `f.rig:12: a + b = 3`, one mechanism with the approved "assert with values" | small std/compiler item |
| 6 | **C structs and pointers through views** | Zig | in an `extern fun`, `!T` is `*T` and `?T` is `*const T`; `extern obj` for a C layout; a write view is an out-parameter (no `out` keyword) | builds the ROADMAP's extern item |
| 7 | **Indented text blocks** | Ruby | `'''`, with the closing line's indentation stripped | syntax: the owner's call |
| 8 | **Arithmetic operators for plain objects** | Swift | `obj Vec2: Add`, the mechanism that already sends `==` to `eq` and `<` to `order` | owner's call: touches "effects stay visible" |
| 9 | **A parameter with a default is passed by name** | Swift | rejects `format_int(255, 16, true)` | rejects accepted programs: migration script and Trig note |
| 10 | **Reuse a split build's unit when its code is unchanged** | Zig | edit-compile time | must clear the speed-feature bar |

Lower value, from Swift: forwarding an API to a field (`obj Counted: Writer by @out`), an identity test for handles (`a.is_same(?b)`), and a rendezvous channel `*Chan[T](0)`.

## Concurrency: folds into the approved plan, no new items

- **`MADV_NOHUGEPAGE` on task stacks** (Zig). Rig sets it on tables and large blocks but not on stacks (`sched.takeStack`). Under transparent huge pages set to `always`, the RHEL and Fedora default, a sleeping task might hold 2 MiB. Unverified: one pup run with that setting, in step A1, "measure first".
- **The syscall-handoff protocol** (Go). A fast call costs two atomics; only a slow one moves the stuck worker to a fresh thread (`scheduler.cr:100-133`, `monitor.cr:139-155`). This gives step C3 its design.
- **Free idle stacks gradually** (Go): halve the pool every 5 s, clear it when idle. An addition to step A2.
- **Cap the spinning workers** (Go). Check whether Rig limits idle workers spinning for work.
- **One internal protocol for select arms** (Go), so std can add `~a.on_down()` (D1) or a readable socket without a compiler case.
- **A "none ready" arm in `task.select`** (Ruby), Crystal's `select … else`.
- **Confirmed:**
  - Crystal reserves 8 MiB stacks and commits them lazily, and lands where Rig is today: about 16 KiB at rest, plus a GC'd fiber object. That supports small stacks with a proven bound (A3).
  - Crystal's `Isolated` context is the main-thread actor (D3). "Isolate" is taken in Rig (`task.isolate`), so it needs another name.

## Rejected by every expert, or nearly every one

- Whole-program type inference.
- Silent union widening.
- Open classes, monkey-patching, `method_missing`.
- Overloading by argument type.
- Text macros and `property`/`getter`.
- Exceptions.
- A GC.
- Unstructured `spawn`.
- Blocks that capture by reference.
- `?`/`!` in method names.
- `===` in `case`.
- Two forms of `case`.
- `not_nil!` and truthy `||`.
- Hidden string interpolation (it allocates).
- A second backend that interprets bytecode.
- Separate external and internal parameter names.
- Inheritance.
