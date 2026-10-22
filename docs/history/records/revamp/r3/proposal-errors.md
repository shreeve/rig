# Proposal: errors that carry data (Trig NEEDS 7)

This is a proposal for the owner, and no code has changed. Probes ran on
main 741526cb1 (`bin/rig` 0.2.9, Zig 0.17.0, aarch64 macOS) under
`cpuq --cores 2`, with a temporary `RIG_OUT_DIR`.

## 1. The problem, and what works today

Rig's errors are names. `T!` lowers to Zig's `anyerror!T`, a 2-byte code
next to the value, and `catch |err|` binds `err: error`, meaning any error.

| Probe, today | Result |
|---|---|
| after `catch \|e\|`: compare, `match` with `_`, print, `return e`, `saved = e` | works |
| `fun describe(e: error)`, or a field `err: error` | `unexpected keyword 'error'; expected a type` (a) |
| `error_text(e)` for an `e` caught from a `GlobError` failure | `type mismatch: expected 'GlobError', got 'error'` (b) |
| `!errs.push(e)` into a `List[A]` | the same mismatch (b) |
| `match e` with an arm for every member of the only set | `match on 'error' is not exhaustive; add '_ =>'` (b) |
| `error ParseError` / `eof(pos: Int)` | `only enums declare payload variants` (c) |

The evidence:

- **std.json builds its payload by hand.** `parse(!self, src) -> Bool`;
  the `Doc` keeps `pub error: Error` and `pub error_pos: Int`, and each
  internal step returns `-1` after `fail(e, at)` writes both.
  docs/json/DESIGN.md item 10 waits on this feature.
- **Trig's `src/glob.rig`** has `pub error GlobError` and
  `error_text(err: GlobError)` for Go's messages. PR #151 stopped here.
- **IDEAS 1.4:** `QError::Invalid(String)` and `PakError.too_many(count:
  Int)` have no spelling in Rig.
- **ts-rust's `catch_unwind` (d)**, counted in `crates/ts_goport/src`:
  116 call sites. 52 are in `#[cfg(test)]` modules, asserting a panic. Of
  the 64 in production code, 15 are crash reports in the binaries, 23
  isolate requests (`ipc`, `lsp`, `ls`, `api`, `project`,
  `contentmapper`, `fswatch`), 18 isolate per-file worker jobs
  (`emitter`, `program.rs`, `frontend`, `execute`, `gostd`), 4 emulate
  Go's `recover`, 3 are in `baseline` and `tracing`, and 1 is in
  `checker/` (the node builder catching port-only `unported!` panics per
  hover). The pure core that Trig ports needs about one.

**Measured cost.** `@sizeOf`: `anyerror!i64` 16 bytes, `anyerror!void`
2, `anyerror![]const u8` 24; a tagged `Result(i64)` whose error is
`{eof(pos), bad(pos, msg)}` is 40, even with `msg` a bare slice. A
micro-benchmark (`errors/bench.zig`, kept with the probes: ReleaseSafe,
three `noinline` frames, one failure per 1,000 calls; instructions retired per iteration, median of
5) gives **A**, today's error union, 78.22; **B**, the error union plus a
payload slot the catching frame passes down, 81.22; **C**, a tagged
`Result`, 79.24. The disassembly explains it. Zig already returns
`anyerror!i64` through memory (x0). B's callee and propagating frames
are A's instruction for instruction, with the slot pointer untouched in
x2 on success; B's 3 extra instructions are at the one `catch` site,
which passes the slot's address. C doubles the returned object, and
every propagating frame copies the payload (`ldur q0`, `str q0`, `ldr
x8` in `c1`).

## 2. Options and recommendations

### Q1. How a payload lowers

- **L1, a tagged `Result(T, E)` in place of `E!T`: rejected.** Every
  fallible return grows to `max(T, payload)` plus a tag, and `T!` must
  hold the program's largest payload. Every `!` frame copies the payload.
  It gives up Zig's `try` and `errdefer`, which `!` and `errdefer` lower
  onto.
- **L2, a global or thread-local side channel: rejected.** It is hidden
  mutable state the ownership checker cannot see. A `defer`, `errdefer` or
  `drop` body that catches its own failure while an outer one is leaving
  overwrites the outer payload, so its `String` leaks or the handler reads
  the wrong data. It also needs thread-local storage once threads come.
- **L3, a slot the catching frame owns, passed down as a hidden
  write-view parameter: recommended.** The failing frame writes the slot,
  and every `!` passes its own slot on. The return type is unchanged; the
  success path gains one pointer argument, which inlining removes. A
  failure writes once, a `!` copies nothing, and a `catch` reads once.
  This is Zig's own `Diagnostics` idiom (`std.json`, `std.zon`), made
  automatic. It allocates nothing, since the slot is a local of the
  frame that has the `catch`. Nested failures cannot overwrite it, since
  each `catch` has its own. It needs no thread-local state, so it suits
  threads and wasm32. A program that declares no error fields emits
  exactly today's Zig, which `equiv.py` can check.

### Q2. Ownership

A member's fields follow an enum variant's rules, plus two type rules.
**A field is never a view:** an error passes through frames that never
said where its views come from (`from` covers only the result), and
tracking them would need a second loan mechanism. `Static` is plain, so
it is allowed. **Every field clones,** so `+err` always works. Without
this, `error` would clone only when every set in the program clones, a
rule that depends on code elsewhere.

`catch |err|` gives the handler the error itself, **owned**
(recommended): it came from a frame that no longer exists. The
alternative, a view of the slot, would make the slot a loan that outlives
the call statement, for no gain. A `catch` that names no error **drops it
before its handler runs**, as `_ =` does.

### Q3. Error sets

- **S1, inferred per function as in Zig: rejected.** Trig's checker is
  mutually recursive, and Zig rejects inferred sets on recursion; function
  types need a spelled set; the ownership checker reads signatures only;
  and a callee's change would silently change a caller's exhaustiveness.
- **S2, declared only, `T!` removed: rejected.** It breaks every program,
  and `main`, callbacks and generic code want "any error".
- **S3, `T!E` declared where wanted, `T!` still any error:
  recommended.** It narrows wherever a set is declared (gap b).

**"Any error" (gap a) is spelled `error`:** diagnostics already print it,
it is a keyword, and no user type can collide with it (`Error` would:
std.json has `pub enum Error`). `anyerror` would be a second word.
**Sets compose by a named union, `error LoadError = IoError |
ParseError`.** Rejected: an inline `-> Int!(IoError | ParseError)` (a
second spelling, long signatures), and sets listing sets among their
members (names and sets in one list). A set is members or a union, never
both. **An `error` narrows to a set with an arm, `g: GlobError =>`,** with
`match`'s binding rules (a read `match e` views, `match <e` moves); an
error that doesn't match is not lost. Rejected: `GlobError.from(<e) ->
GlobError?`, which loses a non-member, and `if e as g: GlobError`, a
second narrowing form.

### Q4. Unwinding and `recover` (gap d)

**Rig never unwinds.** Zig has no unwinding. Building one into the
emitted Zig, with setjmp/longjmp or landing pads, would skip Zig's
`defer`s, so drops would not run and safe code would leak. It would add a
hidden exit at every call, which "every path out of a scope reports the
loans it discards" cannot see. It would cost the optimizer at every call.
And exception handling is not in baseline wasm32, Trig's destination. A
panic ends the program. What Trig does instead: (1) expected failures
use `T!E` and `!`; (2) a deliberate early exit from a deep walk uses a
declared `error Bail` set propagated with `!`, so every frame that can
bail says so; (3) bugs and the port-only `unported!` call `panic` (NEEDS
15, its own proposal), and on wasm32 the host sees a trap and restarts
the instance; (4) the 52 panic-asserting tests become tests of a `T!`
result; (5) request and worker isolation (41 sites) belongs to the native
extras, where the boundary is a process.

### Q5. Performance

Under L3 the callee and every `!` frame keep today's code (measured
above). A `catch` site pays 3 instructions per call and reserves the slot
on its stack: the declared set's largest payload, or the program's for a
`T!` call. std.json's hot paths are not fallible today (they return
`-1`), so `bench/json/guard.txt` cannot move until std.json migrates in
R4, which must pass `guard.py` within 2%; there `JsonError.unexpected(at:
i)` stores one `Int` where `fail` stores two fields. The queued
`coldpaths` round applies unchanged.

## 3. Syntax

```rig fragment
error ParseError                         # a member may carry fields, as an enum variant does
  empty
  bad(pos: Int, msg: String)
error LoadError = IoError | ParseError   # a union of named sets
fun parse(s: ?String) -> Int!ParseError  # declared; also `sub save()!E`, `?fun(Int) -> Int!E`
fun run() -> Int!                        # any error, as today
e: error                                 # any error as a type: params, fields, List[error]
return ParseError.bad(pos: i, msg: String("x"))   # one field may be positional: .eof(i)
match e
  g: GlobError => error_text(g)          # narrow an `error` to a set
  _ => pass
```

`E!` and `error!` stay rejected. Fields follow the payload-enum rules for
construction, patterns (`.bad(pos, msg)`, `ParseError.bad(pos, msg)`),
`==` (`err == ParseError.bad` tests the member; with fields it compares
them too) and printing (`ParseError.bad(pos: 3, msg: "x")`).

## 4. Semantics and desugaring (for docs/INTERNALS.md)

The checks, as a positive list. **Failing:** `return X.m(...)` in `-> T!S`
needs `X.m` in `S` (any member under `T!`). **Propagating:** `g()!` needs
`g`'s set inside `S`, so a `T!` callee cannot propagate into a declared
`S`. **Re-failing:** `return e` needs `e`'s set inside `S`, or `S` any.
**Function values:** `fun -> T!A` is accepted where `fun -> T!B` is
expected when `A ⊆ B`, and always where `T!` is. **Catching:** `catch
|err|` types `err` as the callee's declared set, or `error`.
**Exhaustiveness:** a `match` on a set needs no `_`; on `error` it does.
**Kinds:** a set without fields is plain and copies, as today; a set with
fields is plain or owning by its fields; `error` is owning (it moves, and
`+e` clones). **Leaving `main` or a `test`** prints the error with its
fields (`error: E.bad(msg: "x")`), drops it, and exits 1. **Zig-backed
declarations** fail only with sets that have no fields.

**The desugaring** uses forms the Core already covers: a write-view
parameter (sentence 9), an optional local, and `<` of an optional place
(§5). Names starting with `__` are hidden.

```rig fragment
# source                                  # desugared
fun f(a: A) -> T!S                        fun f(a: A, __out: !(error?)) -> T!   # code only, as today
  return S.m(x: e)                          __out = S.m(x: e)                   # drops the old `none`
                                            return S.m                          # the member's code
  g(a)!                                     g(a, !__out)!                       # g's set is in S
  v = h(a) catch |err| H                    __slot: error? = none
                                            v = h(a, !__slot) catch |_|
                                              err = <__slot                     # never none: h wrote it
                                              H                                 # err drops at the end unless moved
  w = k(a) catch H2                         __slot2: error? = none
                                            w = k(a, !__slot2) catch |_|
                                              _ = <__slot2                      # dropped before H2
                                              H2
```

The slot's type is `error?` everywhere, so every desugared call
type-checks with no new rule. The set is a fact on top: a slot holds only
what its callee writes, a member of the callee's set (checked at each
`return`), so `err` gets that set's type, and emit sizes the buffer by
it. The error is built before the scope's exits run, as a `return` value is,
so an `errdefer` that reads a moved name is rejected, as it is today. The
ownership checker walks exactly these statements, slot included. Emit
adds no temporary, drop or evaluation order of its own; it only chooses
how to represent them:

`__out` is a `[*]align(A) u8` parameter that every fallible function and
function type gets when the program declares any set with fields, and
none gets otherwise, so function-pointer types never differ by set.
`__slot` is a stack buffer sized for its set: zero bytes, and no argument
written, for a set without fields. `g(a, !__out)!` is Zig's `try g(a,
__rig_out)`, with no copy. A set's value is a Zig tagged union of its
members' field structs. `error` is `struct { code: anyerror, data: [N]u8
align(A) }`, with N and A from the program's largest payload, and its
drop glue switches on `code`. A `switch` on a declared set gets `else =>
unreachable`, which sema has proved.

## 5. The CORE paragraph

Add this after sentence 10 in docs/CORE.md §2:

> **A failure moves its error.** An error set's member may carry fields,
> as an enum's variant does, but never a view, and every field clones;
> an error is plain or owning by the enum rule (§1), and `error`, which
> holds an error of any set, is owning. `return E.name(...)` moves the
> error out of the function, `e!` passes the same error to the caller,
> and `catch |err|` makes it the handler's own binding, which drops when
> the handler ends unless the handler moves it on (`return err`, `<err`);
> a `catch` that names no error drops it before its handler runs. Reading,
> matching, printing, storing, and cloning an error follow its type, as
> for any value. *(planned)*

## 6. The tests that define it (all fail today)

**Doc examples.** Each goes in as a `rig pending` block followed by its
`output` block: P1 in CORE after the paragraph, P2–P4 in SPEC §13. The
suite counts them as pending today, since each is rejected, and the
round that builds the feature turns each into a plain `rig` block.

```text
# P1: fields move up through `!`; the handler owns them
error ParseError
  empty
  bad(pos: Int, msg: String)
fun parse(s: ?String) -> Int!ParseError
  return ParseError.empty if s.len == 0
  return ParseError.bad(pos: 0, msg: String("not a digit: ", s)) if s[0] < 0x30 or s[0] > 0x39
  s.len
fun twice(s: ?String) -> Int!ParseError
  parse(s)! * 2
sub main()
  print(twice("42") catch -1, twice("") catch -1)
  n = twice("x1") catch |err|
    print(err)
    match err
      .empty => -1
      .bad(pos, msg)
        print("at", pos, msg)
        -2
  print(n)
# output:
# 4 -1
# ParseError.bad(pos: 0, msg: "not a digit: x1")
# at 0 not a digit: x1
# -2

# P2: a declared set narrows (Trig's glob), and so does a `g: E` arm on an `error`
error GlobError
  bad_range
  star_star
fun error_text(err: GlobError) -> Static
  match err
    .bad_range => "bad range"
    .star_star => "star star"
fun parse(p: ?String) -> Int!GlobError
  return GlobError.star_star if p == "a**"
  return GlobError.bad_range if p == "["
  p.len
fun loose(p: ?String) -> Int!
  parse(p)!
sub main()
  for p in ["ab", "[", "a**"]
    n = parse(p) catch |e|
      print(error_text(e))
      0
    print(n)
  m = loose("[") catch |e|
    match e
      g: GlobError => print(error_text(g))
      _ => print("other")
    -1
  print(m)
# output, one per line: 2 / bad range / 0 / star star / 0 / bad range / -1

# P3: `error` as a type; a stored error moves
error Net
  timeout
error Disk
  full(path: String)
fun fetch(n: Int) -> Int!
  return Net.timeout if n == 1
  return Disk.full(path: String("/tmp")) if n == 2
  n
sub main()
  seen: List[error] = List()
  for n in [1, 2, 3]
    v = fetch(n) catch |e|
      !seen.push(<e)
      0
    print(v)
  for e in seen
    print(e)
# output: 0 / 0 / 3 / Net.timeout / Disk.full(path: "/tmp")

# P4: a union of sets; an exhaustive match with no `_`
error IoError
  closed
error ParseError
  bad(pos: Int)
error LoadError = IoError | ParseError
fun read(n: Int) -> Int!IoError
  return IoError.closed if n < 0
  n
fun parse(n: Int) -> Int!ParseError
  return ParseError.bad(n) if n > 9
  n
fun load(n: Int) -> Int!LoadError
  parse(read(n)!)!
sub main()
  for n in [3, -1, 12]
    v = load(n) catch |e|
      match e
        IoError.closed => -1
        ParseError.bad(pos) => -100 - pos
    print(v)
# output: 3 / -1 / -112
```

**Rejections.** Each is a `test/reject/` file. The same program also goes
in SPEC §13 as a `rig pending` block followed by an `error` block.

```text
# types/error_set_too_narrow.rig
error A
  x
fun loose() -> Int!
  1
fun narrow() -> Int!A
  loose()!
# error: `loose` may fail with any error, and `narrow` declares `Int!A`: catch it, or declare `-> Int!`
# types/error_member_not_in_set.rig
error A
  x
error B
  y
fun f() -> Int!A
  return B.y
# error: `B.y` is not in `A`, the error set `f` declares
# types/error_field_view.rig
error P
  bad(text: ?String)
# error: an error's field is never a view: hold a `String` or a `Static`
# types/error_field_unique.rig
obj Random unique
  seed: Int
error U
  bad(r: Random)
# error: an error's fields must clone, and `Random` is unique
# types/error_union_with_members.rig
error A
  x
error L = A
  extra
# error: a union of error sets lists no members of its own; declare a set for `extra` and join it
# ownership/error_binding_moved.rig  (also: error_binding_copied.rig, with `a = err` / `b = err`,
#   "`err` owns an `E`, which can't be copied by `=`: write `<err` to move it, `+err` to clone it, or `?err` to view it")
error E
  bad(msg: String)
fun f() -> Int!E
  return E.bad(msg: String("x"))
sub main()
  n = f() catch |err|
    keep = <err
    print(err)
    0
# error: use of `err` after move
```

**Behavior tests** (`test/behavior/effects/`, sanitizer-clean):
`error_payload_frames.rig` (a `String` field fails three frames down,
propagates by `!`, is caught and printed); `error_payload_unbound_catch.rig`
(`f() catch 0` on an owning payload, no leak); `error_payload_errdefer.rig`,
which L2 would fail (an `errdefer` whose own `catch` catches an inner
payload error while the outer failure's payload waits: prints `cleanup saw
E.bad(msg: "inner")`, then `caught E.bad(msg: "outer")`);
`error_payload_main.rig` (`# expect-panic: error: E.bad(msg: "x")`, exit
1, no leak); `error_payload_closure.rig` (a `*fun(Int) -> Int!E` and a
`?fun(Int) -> Int!E` fail with a payload). An `equiv.py` case checks that
a program with no error fields emits the same Zig before and after R3.

## 7. Plan by round

| Round | Content | Gates | Effort |
|---|---|---|---|
| **R1 `errtype`** | `error` usable as a type (params, fields, results, `List[error]`); `error` becomes owning, and `+e` clones it; P3 without the `full` field; the copied-binding rejection | typecheck kinds: full matrix | 1–2 days; first count the suite and corpus programs that copy an error |
| **R2 `errsets`** | `T!E`, `sub f()!E`, `fun(...) -> T!E`; `error L = A \| B`; subset checks at `return`, at `!`, and when a function value is coerced; the typed `catch` binding; exhaustive set `match`; `g: E =>` arms; P2, P4 and the type rejections. Emit adds `else => unreachable`; signatures stay the same | typecheck only | 3–5 days; unblocks #151 and Trig's glob |
| **R3 `errdata`** | member fields; the slot desugaring in sema and ownership; the owned `catch` binding; the drop at an unbound `catch`; printing; failure out of `main` and `test`; the field rules; P1, the behavior tests, the moved-binding rejection; the oracle learns the slot; the INTERNALS desugaring; the CORE paragraph marked *(built)* | ownership: full matrix, corpus, oracle | 1.5–2 weeks; a second soundness round stops it |
| **R4 `jsonerr`** | std.json: `parse(!self, src)!JsonError` with members like `unexpected(at: Int)`, and `!` in place of `-1`; closes DESIGN.md item 10 | std, plus `guard.py` within 2%, with `--update` committed | 3–4 days |

R2 shares typecheck's classification with R1, so it lands after R1. R3
follows R2. Trig moves glob, semver and jsnum to declared sets after R2,
and adds fields after R3.

## 8. Risks

- **Grammar:** `T!E` in type position beside the prefix `!T`, `g: E =>`
  as a pattern, and `error L = A | B`. Each new conflict is listed and
  justified in INTERNALS, or the spelling changes.
- **R1's kind change** rejects a program that copies an `error` into two
  bindings (fixed with `+e` or `<e`); R1 counts them before landing.
- **Slot size for `T!`:** one large payload enlarges every frame that
  catches a `T!` call. The docs advise boxing large payloads (`^T`);
  decision 15 covers a warning.
- **Shims as function values:** with error fields in the program, a
  Zig-backed std function used as a value needs a thunk that ignores the
  slot (R3).
- **Soundness:** the new path is a value leaving through the exit
  primitive. Fields are never views, so no loan travels with an error,
  and "leaving a scope never silently forgets a loan" needs no new rule.

## 9. Decisions for the owner

1. Lower a payload with **L3**, a slot the catching frame owns, passed
   down as a hidden write view; not a `Result` union, not a side channel.
2. An error's field is **never a view**, and every field **clones**.
3. `catch |err|` binds the error **owned** by the handler; a `catch` with
   no name drops it **before** its handler runs.
4. "Any error" is spelled **`error`**, usable wherever a type is.
5. `error` is **owning** in every program (moves; `+e` clones); a set is
   plain or owning by its fields.
6. Sets are **declared where wanted** (`T!E`, `sub f()!E`); `T!` stays
   any error; **no inference**.
7. Sets combine only by a **named union** `error L = A | B`; no inline
   unions; a set is members or a union, never both.
8. An `error` narrows to a set by a **`g: E =>` arm**.
9. Construction, patterns, `==` and printing **follow payload enums**.
10. **Subsets:** `!` and `return` need the callee's set inside the
    declared one; a `T!` callee cannot propagate into a declared set;
    function values are covariant in their set.
11. Failing out of `main` or a `test` **prints the fields**, drops them,
    and exits 1.
12. Zig-backed declarations fail only with **sets without fields**.
13. **Rig never unwinds**; no `recover`; a panic ends the program.
14. **Trig:** `T!E` for expected failures, a declared `Bail` set for
    deliberate deep exits, `panic` (NEEDS 15) for bugs and `unported`;
    panic-asserting tests become `T!` tests; no panic-expecting `test`.
15. **Payload size:** no limit, and the docs advise boxing large ones
    (alternative: a warning above 64 bytes).
16. Rounds **R1 → R2 → R3 → R4**; R2 alone unblocks #151.
17. std.json's fallible API is settled in **R4**, within the 2% guard.
18. The roadmap's **`try` block** stays reserved; nothing here needs it.
