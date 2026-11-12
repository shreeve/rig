# Ideas

Ideas worth keeping that the owner has not decided. An idea comes here from a review, a panel, or the owner. It moves to the [ROADMAP](ROADMAP.md) when the owner approves it, and leaves this file. An idea he rejects leaves it too, with the reason in its record.

Each entry gives:
- the idea, with the form it would take;
- where it came from;
- what it needs before work can start: a design round, a name, a CORE paragraph (CORE §10), or a migration.

Forms are written in plain text, not `rig` blocks, since none of them runs yet.

The reviews these ideas come from:
- Crystal through five lenses, Ruby, Zig, Rust, Swift, and Go: [crystal-review/](history/records/2026-11/crystal-review/SYNTHESIS.md).
- Rig's concurrency against Rayon, Tokio, Go, Swift, and Erlang: [concurrency-review/](history/records/2026-11/concurrency-review/SYNTHESIS.md).

The concurrency plan the owner approved from that review is on the ROADMAP, under "Concurrency".

## Language

- **Yielding functions, inlined at each `yield`.** A user-written `for` source whose body is spliced in place, as Crystal does for every method that yields: no closure, no captures, no allocation, and `break` and `return` belong to the caller.
  - Form: `fun leaves(?@) yields ?Node`, then `for n in t.leaves()`.
  - The yielded view lives only in the inlined body, so it needs no `from` or `keeps`.
  - Recursion is rejected, with a Rig diagnostic.
  - The yielder's `defer`s run on a `break`.
  - It would also let a chain's stages be written as library code.
  - Source: the Crystal review (Ruby and Rust, separately).
  - Needs: a design round and a CORE paragraph, since it yields views.
- **A loop over an object's fields at compile time.** Each copy of the body is checked for its field, like Zig's `inline for`. std.json's typed decode needs it.
  - Form: `for f in $fields(T)`, unrolled by Rig before the checkers run, never left to Zig's `inline for`, so the checkers walk what is emitted.
  - Source: the Crystal review (Ruby and Zig, separately).
  - Needs: a design round.
- **Arithmetic operators for plain objects,** by the mechanism that already sends `==` to `eq` and `<` to `order`.
  - Form: `obj Vec2: Add`, `a + b`.
  - Only plain objects qualify, so `+` can never hide an allocation.
  - Source: the Crystal review (Swift).
  - Needs: the owner's call, since it touches "effects stay visible".
- **A parameter with a default is passed by name.** Rejects `format_int(255, 16, true)` for `format_int(255, base: 16, upper: true)`.
  - Source: the Crystal review (Swift).
  - Needs: the owner's call. It rejects programs a release accepts, so a migration script and a note to Trig come first.
- **Forwarding an API to a field.**
  - Form: `obj Counted: Writer by @out`; Crystal's `delegate`.
  - Source: the Crystal review (Swift).
  - Needs: a design round with docs/design/apis.md.
- **An identity test for shared handles.**
  - Form: `a.is_same(?b)`: whether two `*T` handles hold the same value.
  - Source: the Crystal review (Swift).
  - Needs: a name from the owner.
- **`task.all` over tasks that give no value.**
  - Form: `task.all(f()&, g()&)!`, one visible wait for several subs, the first failure canceling the rest.
  - Today `task.all` rejects a task that gives nothing.
  - An implicit wait at a scope's end was set aside: it would hide a failure point at a dedent.
  - Source: the owner, 2026-11-03.
  - Needs: a failing case first; it accepts more programs and rejects none.

## Libraries

- **A set of an enum's variants,** held as one integer, apart from the enum, so `match` stays exhaustive (Crystal's `@[Flags]` loses that).
  - Form: `a: Bits[Access] = Bits(.read, .write)`, `a.has(.write)`, `!a.add(.exec)`, `a | b`, `for m in a`.
  - Trig has 2,503 hand-written `flags & X != 0` tests, and docs/STD.md's own example keeps a raw `flags: U32`.
  - Source: the Crystal review (Rust and Swift, separately).
  - Needs: a name from the owner (`Bits`, `Flags`, or `EnumSet`); a new std type.
- **`dbg(e)`, a print that shows its source.**
  - Form: `dbg(a + b)` prints `f.rig:12: a + b = 3`; Crystal's `p!`.
  - One mechanism with the approved assertions that print their values.
  - Source: the Crystal review (Ruby).
  - Needs: a design round together with those assertions.
- **std.json beyond the parser:**
  - a writer;
  - a streaming reader for input larger than memory or from a socket;
  - typed decode into Rig objects, generated at compile time (on the field loop above), with custom codecs that take the decoder itself, as Go's `UnmarshalerFrom` does, never bytes to scan again;
  - skipping the values a program never reads, as simdjson's On-Demand does;
  - whether to reject duplicate keys, as Go's json/v2 does, once typed decode can let one silently overwrite a field.

  Its speed items are docs/design/json.md's "Open items".
  - Source: Go's json/v2 (go.dev/blog/jsonv2), 2026-11-04.
  - Needs: the writer first; a design round for typed decode. Every step keeps `bench/json/guard.py` within 2%, with a standing table against yyjson, simdjson, and Go's json/v2 on the Mac and pup.
- **A rendezvous channel,** whose send waits for its receive.
  - Form: `*Chan[T](0)`; today a channel has at least one slot.
  - Source: the Crystal review (Swift).
  - Needs: the owner's call.
- **A shared cell with read-modify-write operations,** for a parallel search that wants other tasks' results mid-run: a best cost lowered with `fetch_min`, a counter raised with `fetch_add`, never a separate read and write. Check first what std's synchronized types already offer.
  - Source: Rayon's FAQ, 2026-11-04.
  - Needs: that check, then a design round.

## Concurrency, beyond the approved plan

- **A protocol for leaving a slow system call.** A fast call costs two atomic operations; only a slow one moves the stuck worker to a fresh thread, as Crystal's `Fiber.syscall` and its monitor do. Tasks pinned to their thread stay on it. This is the design for the plan's handoff of a stuck worker.
  - Source: the Crystal review (Go).
- **Freeing idle stacks gradually:** halve each worker's pool of free stacks every 5 s, and clear it when the program is idle.
  - Source: the Crystal review (Go).
- **A cap on spinning workers.** Check whether Rig limits the idle workers that spin looking for work, as Crystal counts its own.
  - Source: the Crystal review (Go).
- **One internal protocol for `select` arms,** so std can add an arm (a monitor's `~a.on_down()`, a readable socket) without a new case in the compiler, while the arm types stay one positive list.
  - Source: the Crystal review (Go).
- **A main-thread actor** for GUI toolkits: an actor whose methods run on the process's first thread, as Swift's `@MainActor` and Crystal's `Isolated` context do.
  - Source: the concurrency review (Swift).
  - Needs: a name from the owner; "isolate" is taken by `task.isolate`.

## Compiler, runtime, and tooling

- **A failure's trace in debug builds.** When a failure leaves `main`, print each `f()!` site it passed through, not only `error: E.name`, from Zig's error return trace. No syntax.
  - Source: the Crystal review (Rust).
- **C structs and pointers through views.** In an `extern fun`, `!T` becomes `*T` and `?T` `*const T`, and `extern obj` declares a C-layout object. A write view is then an out-parameter, with no `out` keyword. Today Rig passes only integers, floats, and `Bool` to C. This carries the ROADMAP's C-ABI-friendly `extern` types.
  - Source: the Crystal review (Zig).
  - Needs: a design round with the ROADMAP's raw pointers.
- **Reusing a split build's unit when its code has not changed,** so one edit does not rebuild every unit.
  - Source: the Crystal review (Zig).
  - Needs: it must clear the speed-feature bar on edit-compile time.
- **An LLVM backend,** written directly from Rig's IR, Zig kept for the runtime longest. In stages:
  - a lowered IR between `src/facts.zig` and the backends, useful to the Zig emit too;
  - a second backend behind a flag, compared byte for byte with the Zig one over the suite, Trig, and loco.

  What it could gain: `noalias` from ownership facts, no Zig analysis of emitted code at build time, and debug info in Rig's terms.
  - Source: the owner, 2026-11-04, for December 2026.
  - Needs: first, a measure of the share of `rig build` that Zig spends analyzing emitted code.
