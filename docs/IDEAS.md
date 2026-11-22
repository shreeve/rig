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
- Goose, a memory-safe language with no heap, and Rig read the same way: [goose/](history/records/2026-11/goose/review.md).

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
- **A function's options as a type, `f.Options`.** A wrapper takes "whatever `connect` takes" and gains each option `connect` adds, as TypeScript's `Parameters<typeof f>` does for a whole list.
  - Form: `o = connect.Options(timeout: 5)`, `fun connect_logged(host: ?String, port: Int, ..o: connect.Options)`. When a function's options are exactly one group, `f.Options` is that group's type, not a new one, so wrappers do not build towers of identical, incompatible types.
  - A wrapper that forwards `..o: connect.Options` grows its public options whenever `connect` gains one, which a wrapper meant to restrict does not want.
  - Source: the options committee and its red team, 2026-11-22 ([named-options/](history/records/2026-11/named-options/README.md)); deferred from [design/options.md](design/options.md).
  - Needs: a wrapper that wants it, then a design round on its identity and on methods and generic functions.
- **Groups in APIs.** An API method takes options through a named group, `fun render(?@, ..o: RenderOpts) -> String`, so "a method meets its API exactly" compares one type, and a call through a bound takes keywords and spreads. Inline defaults in an API method stay refused.
  - Source: the options committee, 2026-11-22 ([named-options/](history/records/2026-11/named-options/README.md)).
  - Needs: a real API that wants options; then conformance and calls through API objects ([design/apis.md](design/apis.md)).
- **Function values that keep their options.** A function type names a group, `fun(?String, ..Net) -> Response!`, and a call through the value takes keywords and spreads, filling omitted fields from the group's defaults at the call. The compatibility rules are decided ([design/options.md](design/options.md), "Function types"); v1 refuses a function with options as a value.
  - Form: `cb: fun(?String, ..Net) -> Response! = fetch`, `cb(url, retries: 2)`; a closure that takes a group, `|u, ..net| ...`.
  - Source: the options committee and both red teams, 2026-11-22 ([named-options/](history/records/2026-11/named-options/README.md)).
  - Needs: a callback that wants options; `..T` in function types and closures.
- **Generic groups.** `..o: Opts[T]`, flattened for each instance.
  - Source: the options committee, 2026-11-22 ([named-options/](history/records/2026-11/named-options/README.md)).
  - Needs: a program that wants one; a group generic over "whatever `F` takes" stays out (row polymorphism).
- **Groups passed by pointer.** `..o: ?Net` passes a large options value as one read view instead of a field per argument; keywords build a temporary the call views.
  - Source: the Zig review of the options design, 2026-11-22, which measured the copy a large group costs ([named-options/](history/records/2026-11/named-options/README.md)).
  - Needs: a group large enough to spill, measured; it follows owners and read views in groups (ROADMAP).
- **Forwarding an API to a field.**
  - Form: `obj Counted: Writer by @out`; Crystal's `delegate`.
  - Source: the Crystal review (Swift).
  - Needs: a design round with docs/design/apis.md.
- **An identity test for shared handles.**
  - Form: `a.is_same(?b)`: whether two `*T` handles hold the same value.
  - Source: the Crystal review (Swift).
  - Needs: a name from the owner.
- **A List that never moves.** A grow-only list in reserved address space: a push never relocates it, so a view of an element survives later pushes, where today a live view of a List rejects the push and a program keeps an index or a `Slot` instead.
  - Form: a std type beside `List`, whose push is a write that ends no view of its elements.
  - The runtime already reserves address space for task stacks.
  - Source: the Goose review (grow-only arrays).
  - Needs: a CORE paragraph, since it changes what a push ends; then a design round.
- **No panic in normal code, for the language's own arithmetic.** std.time and std.datetime promise that no call panics on any value: each is total or returns `!` ([design/datetime.md](design/datetime.md), "Total or visible"). Rig's `Int` `+`, `-` and `*` still panic on overflow in every build, so a user's number that drives a program's own arithmetic can end the process: `n * 1000` with `n` read from a file, or `Int(f)` on a NaN, for which there is no checked conversion. Whether the language holds the same bar is open.
  - Forms it could take: fallible arithmetic by name beside the operators (as Zig's `std.math.add` beside `+`), a checked numeric conversion that returns `!`, wider integers where input is read, or none, with `Int`'s range left as the line between input and a bug.
  - Source: the datetime strategy's committee, 2026-11-22 ([datetime-strategy/](history/records/2026-11/datetime-strategy/README.md)).
  - Needs: the owner's call, then a design round; any change to the operators rejects or changes programs a release accepts.
- **A region freed at once.** Values made in a named region are views of it, and dropping the region frees them all in one step, for data that dies together: a file's tree, a parse's temporaries, one request's data.
  - Source: the Goose review (data stacks freed at scope exit). The benchmarks game's binarytrees port keeps its nodes in a `List[Node]` pool in place of Rust's bumpalo arena, and is 6% slower than Rust on pup ([compare/rig/benchmarksgame](../compare/rig/benchmarksgame/README.md)).
  - Needs: a CORE paragraph and a design round; first, a measure of the share of Trig's time and memory in data that dies together.
- **A result built where it lands.** A function that returns a large value, an array or an object holding one, writes it straight into the caller's place through any depth of calls, so a return never copies it. Goose promises this; Rig leaves it to Zig's code generation and promises nothing.
  - Form: no new syntax; a SPEC rule, and a test that returns a large array through several calls and checks that no copy is made.
  - Source: the Goose review (construction in place), weighed 2026-11-21; that record lists it among Goose's features but not among what Rig can take or set aside.
  - Needs: a measure of whether Rig's emitted Zig copies a large result today; if it never does, only the SPEC rule and the test.

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
- **A packed sequence of variant records.** Each value is stored at its own variant's size, not the largest one's; the sequence is walked, never indexed. Goose's one large win (`records`, about 2 times faster than Rust's enum on 4 times less memory) comes from it.
  - Form: a std type over an enum, built with `push` and read with `for`.
  - Source: the Goose review (variable-size enums).
  - Needs: a measured share first, in token streams, Trig's trees, or std.json's parsed form; then a design round.
- **A checked byte image of a Table.** A `Table` whose slots link by `Slot` means the same thing at any address, so it can be saved as its bytes and loaded with one read and a pass that checks every slot, tag, and length before the value exists.
  - Source: the Goose review (`to_bytes` and `from_bytes`).
  - Needs: a design round. It is not a way to ship Trig's libs pre-parsed, which the owner set aside.

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

- **One copy of the datetime makers' check.** The constant-argument rule's check of `Date.new`, `Time.new`, and `DateTime.new` lives twice, in std and in `sema.makerFault`. Once compile-time evaluation can run a std maker that returns an object or fails, the compiler's copy can go.
  - Source: the named-options rule's build, 2026-11.
  - Needs: compile-time evaluation of a function that returns an object or fails.
- **A function that must have no bounds checks.** A mark on a function makes any check left in its body, after `src/proofs.zig`, a compile error that names the check, so a hot loop in Trig, std.json, or the tables cannot regain a check after an unrelated change.
  - Source: the Goose review (`checkfree fn`).
  - Needs: a name from the owner; no CORE change.
- **A benchmarks page written by its scripts,** dated, naming its machines and build modes, its losses, and how any average is formed, so it cannot go stale by hand.
  - Source: the Goose review (`bench/results.md`, generated).
  - Needs: nothing but the work; it goes with the next measurement of docs/launch/benchmarks.md.
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
