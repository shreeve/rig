# Errors that carry data: a languages survey, and the approved design measured against it

Expert 1 (languages). Read: SPEC §13 (9085–9711), CORE §2 "A failure
moves its error", `.git/revamp/r3/proposal-errors.md` (18 decisions,
approved 2026-10-12), `pr-errors-r1-notes.md`, Trig NEEDS 7, mantras,
SPEC §6 defer/errdefer, §17 printing, §18 tasks (moves/shares table,
`Tasks`, `isolate`), and std's sets (`file`, `net`, `task.Stop`).

## 1. Survey

Each language answers six questions: where the data lives, how sets
compose, how one converts to another, how context is added, how the
error is shown, and how it is compared or narrowed.

### Rust
- **Data:** `Result<T, E>`, `E` any type, usually an enum with fields.
  The payload travels in the return value, so every `?` frame copies it
  and `Result` grows to `max(T, E) + tag` (the reason the proposal
  rejects L1, and why Rust code boxes big errors).
- **Composition and conversion:** `?` calls `From::from` on the error.
  Very ergonomic, and it is a hidden function call at every `?`; the
  conversion that ran is not visible at the site. thiserror's
  `#[from]` writes those impls. A wrapper enum per layer is the norm.
- **Two camps:** libraries use thiserror (closed enums, matchable);
  applications use anyhow/eyre (`Box<dyn Error>` plus a context chain,
  `.context("reading config")?`, `bail!("msg")`). The split exists
  because enumerating errors through every layer is laborious, and most
  application code only wants "fail with this message, keep the cause".
- **Chains:** `Error::source()` returns the cause; reporters walk it.
  It is a protocol every type must implement correctly, and many get it
  wrong (printing the cause in `Display` *and* returning it from
  `source`, so it prints twice). The lesson: a chain protocol is easy to
  get wrong and is mostly used for printing.
- **Display vs Debug:** two traits; `Display` is the user message.
  `#[error("expected {expected}, got {found}")]` derives the message from
  fields, which keeps fields structured and composes text only when shown.
- **Evolution:** `#[non_exhaustive]` forces a `_` arm outside the crate,
  so adding a variant is not breaking.
- **`std::io::Error` carries no path** (the fs-err crate exists to add
  one). The reason is cost and layering: the caller has the path.

### Swift (typed throws, SE-0413)
- Untyped `throws` is `any Error` (boxed existential); `throws(E)`
  declares one concrete type. The proposal's own guidance: use typed
  throws in closed, internal code, or where allocation matters (embedded);
  prefer untyped at API boundaries, because a typed signature freezes the
  set. Exactly Rig's `T!` vs `T!E` split.
- **Generic over the error:** `func map<E>(_ f: () throws(E) -> T)
  throws(E)`. `rethrows` becomes sugar for this. Without it, higher-order
  code collapses to `any Error`. This is the piece Java lacked.
- Every `try` is visible at the call; no conversion on propagation
  (`throws(E)` requires the callee's error to *be* `E`; you convert in a
  `do/catch`).

### Zig
- **Error sets are codes only;** `anyerror` is the global set; sets merge
  with `A || B`; inferred sets (`!T`) per function; recursion breaks
  inference. No payloads by design: Andrew's position is that the
  payload is a *side channel the caller asks for*, the `Diagnostics`
  idiom (`std.json.Diagnostics`, `std.zon`): the caller owns a struct,
  passes a pointer, the callee fills it. L3 is this idiom made automatic
  and owned.
- **errdefer |err|** sees the code. **Error return traces** (debug
  builds): each `try` a failure passes through is recorded at near-zero
  cost, so "where did this come from" needs no context strings. This is
  the most underrated answer to the context problem.

### Go
- `error` is an interface (`Error() string`). Sentinel values
  (`io.EOF`), typed errors (`*fs.PathError{Op, Path, Err}`), and wrapping
  with `fmt.Errorf("reading %s: %w", p, err)`.
- **errors.Is / errors.As** walk the `Unwrap` chain: test identity, or
  narrow to a type. Rig's `err == E.name` and `g: E =>` arm are these,
  minus the walk.
- Lessons: message-string errors are the default and are a failure for
  matching (people match on `err.Error()` text); `%w` made chains easy
  and made every error's API include its chain; `PathError` carries the
  path because Go's syscalls know it, at an allocation per failure.

### OCaml, Roc, Koka
- **OCaml polymorphic variants** (`[> `Not_found | `Parse of int]`):
  open, inferred unions that compose without declaring a union type;
  types become unreadable in errors and signatures.
- **Roc:** tag unions inferred and accumulated through `try`; the best
  ergonomics in the survey, bought with whole-program inference Rig has
  ruled out (signatures only; recursion; the ownership checker reads
  signatures).
- **Koka:** exceptions are an effect (`exn`), polymorphic in function
  types, handled by handlers. The lesson Rig already took: the effect is
  in the type and at the call (`!`).

### Java checked exceptions (the failure)
- Why they failed: (1) no polymorphism over the throws clause, so
  lambdas and streams cannot carry them; (2) every layer must re-declare
  or wrap, and wrapping churn (`throws Exception`) killed precision;
  (3) the catch site is far from the throw and invisible at the call;
  (4) they are used for bugs (IOException vs NPE confusion).
- Rig avoids (3) and (4) already (`!` at each call; `panic` for bugs),
  and (2) by keeping `T!` as the default. (1) is open: see D7.

### Midori (Joe Duffy, "The Error Model")
- Bugs **abandon** (fail-fast, the process or isolate dies); recoverable
  errors are **declared and checked**, and every call that can fail is
  marked `try` at the call site. The audit found that most "exceptions"
  were bugs. Typed errors stayed few and closed.
- Rig's model is Midori's almost exactly: `panic` is abandonment,
  `isolate` the boundary, `!` the visible `try`, `T!E` the declared set.
  Rig is in good company.

### C++ `std::expected<T, E>` and Erlang
- `expected` is Rust's `Result` without `?`: the payload in the return
  value, copies at each frame, no propagation sugar (the C++26 `try`
  proposals add it).
- Erlang: `{error, {badarg, X}}` tagged tuples, open atoms, matched by
  pattern, with "let it crash" for the rest. `error` (any) plus `match`
  is the same, typed.

### Lessons distilled
1. **Payload placement decides cost.** In-return payloads (Rust,
   `expected`) tax every frame; side channels (Zig Diagnostics) tax only
   the catch site. L3 is right.
2. **Implicit conversion at propagation is the convenience everyone
   loves and the hidden call no one sees.** Rust's `From` is fine for
   Rust; it breaks "effects stay visible".
3. **Two needs, two tools:** a closed, matchable set for code that
   reacts (library); "fail with a message, keep the cause" for code that
   reports (application). Every language that forced one tool for both
   grew a second (anyhow, `%w`, `Box<dyn Error>`).
4. **Higher-order code must be generic over the set,** or the set
   collapses to "any" at the first callback (Java's fatal flaw; Swift's
   fix).
5. **Context is mostly "where" and "which input".** Return traces
   answer "where" for free; a field answers "which input". A chain
   protocol (`source`, `Unwrap`) is needed only for generic walking,
   which is rare and easy to get wrong.
6. **Messages are best composed at display time from structured
   fields;** a stored `String` costs an allocation on the failure path
   and cannot be matched.
7. **Closed sets break callers when they grow;** the fix is either an
   explicit "may grow" marker (Rust, Swift resilience) or a catch-all
   member by convention.
8. **The OS layer should not allocate per failure** (io::Error's
   choice), because some failures are the normal path (probing paths).

## 2. The approved design against these lessons

### What it gets right
- **L3** (decision 1): Zig's Diagnostics, made automatic, owned, and
  per-catch. Measured: callee and `!` frames unchanged, 3 instructions
  at the catch site. Better than every in-return design surveyed.
- **No implicit conversion** (decision 10, union-only subsets): `!`
  never runs hidden code. Conversion is a `catch` that fails with a new
  error, visibly. Right for Rig.
- **`T!` default, `T!E` opt-in, no inference** (decision 6): Swift's
  split, avoiding Java's churn and Zig's recursion trap.
- **Fields never views, always clone** (decision 2): the error outlives
  every frame it passes, so no loan can travel with it. Dissolves the
  problem.
- **Owned `catch` binding; unbound `catch` drops first** (decision 3).
- **`g: E =>` narrowing** (decision 8) is `errors.As` without the walk,
  and loses nothing that does not match.
- **Bare `.member` tests only the member** (SPEC §4 equality, inherited
  by decision 9): `err == FileError.not_found` is Go's `errors.Is` for a
  member even when it carries fields. Good.
- **No unwinding, panic is abandonment, `isolate` is the boundary**
  (decision 13): Midori's model.

### What it misses
1. **Recursive fields.** A member with a field of type `error`, or of a
   set that contains this set, makes `error` (sized by the program's
   largest payload) contain itself. The proposal has no rule. This is
   exactly the field people write for a cause (`read(path, cause:
   error)`). It needs a rejection, and `^error` as the boxed form.
2. **Errors crossing tasks.** "What a task gives must move" (§18).
   Decision 2 says fields clone, not that they move. A field holding a
   `*T` (if `+` on a handle counts as a clone) would make `error`
   non-moving, so every `Task[T!]` would be rejected, by code elsewhere:
   the same flaw decision 2 was written to prevent for cloning. Also
   unspecified: under L3 the catching frame of a task is the task itself,
   so the `Task` object must own an `error?` slot, `>t!` moves it into
   the waiter's `__out`, and `>ts` / `wait_first` must drop the errors
   they discard (the losers and the canceled).
3. **Comparison of two `error`s.** "`==` follows payload enums" means
   `error == error` needs every field of every set to be equatable: again
   a property of code elsewhere. A `List[Int]` field (no `==`) would
   silently take `==` away from `error`. Needs a rule.
4. **Generic error sets.** `sub each(xs, f: ?sub(?String)!)!` is the
   only spelling; a caller passing a `!GlobError` closure gets back `!`
   (any), and must narrow with a `_` arm. Trig's visitors and walkers are
   higher-order. Java's lesson says this decides whether `T!E` survives
   contact with real code.
5. **The common case, "fail with this message",** has no blessed form.
   Each module declares its own one-member set. That is two lines and
   arguably fine, but the docs should show the pattern, and printing
   should make it read well.
6. **errdefer cannot see the error.** Zig's `errdefer |err|` can. Under
   L3 the error is already written to `__out` when the errdefers run, so
   a read view is free and sound.
7. **User-facing messages.** Printing is structural
   (`ParseError.bad(pos: 3, msg: "x")`), and there is no Display hook
   (and Rig's taste, "a method named `eq` is never called by `==`",
   argues against one). Trig's Go messages and mini-redis's
   `"protocol error; expected array, got X"` are written by a function
   the program calls. That is fine; it should be said, with the method
   name settled (note: plain enums have a `.text` member giving the
   variant's name, so an error set's method should not be `text`).
8. **Decision 12 vs the motivating use.** "Zig-backed declarations fail
   only with sets without fields" is right, and it means std.file and
   std.net add fields only in their Rig wrappers. The more important
   question is *whether* they should (lesson 8): Trig's module
   resolution probes many paths that do not exist; a `path: String`
   field allocates on each probe. The path belongs to the caller.

### What I would change
- Nothing in the 18 decisions needs overturning. Two need tightening:
  decision 2 (add "every field moves" and "equatable", and the
  recursion rule) and decision 15 (I would take the alternative, a
  warning above 64 bytes, since one large payload silently grows every
  `T!` catch frame and every `List[error]` element in the program: a
  hidden cost the programmer did not write at that site).
- Add four things: tasks' slot semantics (spec text, not a decision
  change), `^error` causes, generic sets, and `errdefer |e|`.

## 3. Recommendations, as decisions (default first; each could go into SPEC)

**D1. Messages.** A message field is `Static` when the text is fixed and
`String` only when it must be built; prefer structured fields
(`unexpected(at: Int, found: U8)`) and build text where it is shown.
*Default: yes, as doc guidance in SPEC §13 and STD.* Reason: no
allocation on the failure path, and fields stay matchable.

**D2. An error's fields are data.** Each field must move (the task rule,
§18), clone, compare (`==`), and print; never a view, a `*T`, `~T`,
`Cell`, `Signal`, closure, or `List` (box a list's data in an object that
compares, or omit it). *Default: yes, rejected at the set's declaration:
"an error's field must move, clone, and compare: `X` does not".* Reason:
every `error` then crosses tasks, clones, and compares, whatever other
modules declare; decision 2's own argument, applied to the other three
operations.

**D3. Causes are a boxed field, `cause: ^error` (or `^S` for a set).**
A field of type `error`, or of a set that holds this set inline, is
rejected: "an error cannot hold an error inline; box it: `^error`".
Printing shows the cause as any field: `Config.read(path: "/etc/x",
cause: FileError.not_found)`. *Default: yes; no `source` protocol, no
chain walking in the language.* Reason: a cause is just a field; the
box makes the allocation visible; a chain protocol is mostly used for
printing, which structural printing already does.

**D4. Context is written with `catch`.** `read(p) catch |e| return
Config.read(path: +p, cause: ^(<e))` (box spelling as Rig writes it).
No `.context()` method, no conversion at `!`. *Default: yes; revisit a
std set like `error Context / at(what: Static, cause: ^error)` after
the mini-redis port shows whether one is wanted.* Reason: one mechanism,
every allocation and move visible.

**D5. Conversion at `!` is by subset only** (as approved). No `From`.
*Default: keep decision 10.* Reason: `!` never runs hidden code.

**D6. "Fail with this message" is a one-member set the module declares**
(`error Proto / bad(msg: String)`, `return Proto.bad(String("expected
array, got ", k))`); no built-in message set. *Default: yes, shown in
SPEC §13 and the Learn journey.* Reason: two lines buys a named,
matchable, printable error; a built-in set would be a second mechanism
and would print under a name no module chose.

**D7. A function may be generic over its error set:** `sub
each[E](xs: []?String, f: ?sub(?String)!E)!E`, with `E` bound only to
error sets (unions included), and `T!` still accepted for a callback.
*Default: yes, in a round after R2 (R2.5), before Trig moves walkers to
declared sets.* Reason: without it, declared sets collapse to `!` at the
first callback (Java's flaw; Swift's fix in SE-0413).

**D8. Sets are closed, and growth is by convention.** A set that the
system may grow (std's `FileError`, `NetError`) keeps a catch-all member
(`failed(code: Int)`); adding a member to a `pub` set is listed in the
release notes as a change that rejects programs. No `open` keyword.
*Default: yes.* Reason: Rig compiles the whole program, so a break is a
diagnostic, not a silent ABI bug; a keyword would be a second meaning
for `match`.

**D9. Printing stays structural; messages are a method the program
calls.** An error set may declare methods, as an enum may; `print` and
the exit from `main` never call one. Suggested name for the convention:
`message` (not `text`, which plain enums use for the variant's name).
*Default: yes.* Reason: no method is called by an operator in Rig;
`main`'s report should show the data, not a message that may hide it.

**D10. Comparing:** a bare member (`err == E.bad`) tests the member,
fields ignored (as built for enums); a member with arguments compares
the fields too; `error == error` compares set, member, and fields
(sound by D2). *Default: yes.* Reason: Go's `errors.Is` for members,
with exact equality available.

**D11. Tasks hold their error.** A `Task[T!]` owns an `error?` slot (or
its set's) in the task's own storage; the task's body is its catching
frame; `>t!` moves the error into the waiter's slot; `>t catch |e|`
owns it; `>ts` and `wait_first` drop every error they do not give,
including `Stop.canceled` from the tasks they cancel. *Default: spec
text in §18, built in R3, a `seeds: 20` case with a `String` field
failing in a task, and a sanitizer case for the dropped losers.*
Reason: L3 names the catching frame; for a task that frame is the task.

**D12. `isolate` reports the panic as data:** `Stop.panicked(msg:
String)`. *Default: yes, after R3.* Reason: Trig's request and worker
isolation (41 sites) wants the message, and the report is already
written.

**D13. `errdefer |e|` gives a read view of the leaving error** (typed
by the function's declared set, else `error`); it cannot move or drop
it. *Default: reserve now (rig pending), build after R3.* Reason: under
L3 the error is already in `__out`, so the view is free and cannot
dangle; Zig has the same form.

**D14. std.file and std.net carry no path.** Members stay field-less
except `failed(code: Int)` for the OS code; the caller, who has the path,
adds it with D4 when it reports. *Default: yes.* Reason: no allocation
on a failure that is the normal path (probing paths); Rust's `io::Error`
made the same choice for the same reason, and decision 12 already keeps
the shims field-less.

**D15. Payload size:** warn when a set's largest member exceeds 64
bytes, naming it and suggesting `^T`. *Default: the warning (the
proposal's alternative).* Reason: one large payload grows every catch
frame of a `T!` call and every `List[error]` element in the program, a
cost not written where it is paid.

**D16. Keep Zig's error return trace** in debug builds and map its
frames to Rig source lines when a failure leaves `main` or a `test`.
*Default: yes, a small follow-up.* Reason: it answers "where did this
come from" for free, which is most of what context strings are for.

## 4. The motivating programs under these decisions

```rig pending
error Frame
  incomplete                          # the hot path: no field, no allocation
  bad(expected: Static, found: U8)    # message composed when shown

error Proto
  bad(msg: String)                    # the "Other(String)" case, built only on failure

error RedisError = Frame | Proto

fun get_u8(src: !Cursor) -> U8!Frame
  return Frame.incomplete if src.done()
  src.next()

fun check(src: !Cursor) -> Int!Frame
  b = get_u8(!src)!
  return Frame.bad(expected: "array", found: b) if b != 0x2a
  1
```

std.json: `JsonError.unexpected(at: Int)`, plain, one `Int` (R4). Trig
glob: field-less `GlobError` plus a `message` function returning `Static`
(R2 suffices). std.file: `FileError.not_found` field-less; a CLI that
reports wraps it, `Config.read(path: +p, cause: ^(<e))`.
