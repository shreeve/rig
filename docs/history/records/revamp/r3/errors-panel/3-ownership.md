# Expert 3: ownership and real error use

Panel on the approved errors design (`.git/revamp/r3/proposal-errors.md`,
approved 2026-10-12; R1 landed). Read on main ace79d579, `bin/rig` 0.2.9.
Probes are in `errors-panel/ownership-scratch/` (p1-p15), run with
`RIG_OUT_DIR` under the scratchpad. Nothing in the repository was touched.

## Verdict

The design is sound in its core idea, and it fits CORE in one paragraph,
with three amendments the approval did not see:

1. **Fields must also move to another task**, not only clone and hold no
   view. `error` is owning *in every program* so that its kind never
   depends on code elsewhere; the same argument applies to whether it
   crosses threads. SPEC §18's table says what a task gives "must move".
   If one set anywhere may hold a `*T` (whose count is not atomic, and
   which `+` clones, so the approved rule admits it), then `error` does
   not move, and every `Task[T!]` in the program becomes local. That is
   exactly the "depends on code elsewhere" rule the proposal rejected
   for cloning.
2. **"Never a view" must be the type fact "may hold no loan"** (CORE §9),
   not the syntax "is not `?T`". Otherwise `List[?String]`, `^?String`,
   an object holding a `?String`, or a `*Node` whose `Node` holds a view
   all get in, and each carries a loan out of a frame that no longer
   exists.
3. **A task owns its slot.** The §4 desugaring passes `!__slot` to the
   call. For `h(a)&` that would make every fallible task "lent to
   write", so it could not be moved, put in `Tasks`, or returned, and a
   waiter that leaves early (cancel, deadline) would leave the task
   writing into a dead frame. The task's failure lives in the `Task`
   value; `>t!` moves it on, and dropping the task drops it.

The rest of the approved decisions stand. I would overturn none; I
sharpen 2, 3, 11 and 12.

## 1. Soundness: every path an owning error takes

Two invariants carry every case below:

- **(I1) A slot holds at most one error, written once, as its call
  leaves.** Only a failing `return` writes `__out`, after its value is
  fully built, and then the function returns at once. A `catch` empties
  its slot with `<`. So nothing double-drops and nothing overwrites.
- **(I2) An error carries no loan, and dropping it runs no user code.**
  No field may hold a loan, so no frame it passes through, and no owner
  in any of them, is limited by it. Every field clones, and a type with
  a `drop` body has no `+` (sentence 2), so no error holds a value with a
  `drop` body. Dropping an error therefore runs no `drop` body, and the
  order errors drop in is never observable.

| Path | What happens | Hazard | What prevents it |
|---|---|---|---|
| `return E.x(f: <s)` | `s` moves into the made error; the error is stored in `__out`; then the scope's exits run | an `errdefer` or `defer` reading `s` sees moved data | sentence 1 as today: `defer print(s)` then `<s` is rejected, "use of `s` after move" (p13); the oracle already orders the value before the regions (`retValue`) |
| `return E.x(f: g()!)` | `g` fails into the same `__out` while `E.x` is half-built | emit building `E.x` in place in `__out`, then `g` overwriting it: a leak or corrupt slot | the desugaring `__out = E.x(...)` evaluates the fields first; a temporary of the statement drops on `g`'s failure (§3). Needs a test (T6) |
| `return v if ok else E.x(msg)` | the slot is written only on the error branch | a path that writes and goes on | I1: the slot is written only where the function leaves with it |
| `e!` through frames | the same `__out` passes down; nothing copies | a frame's locals dropped while the error views them | I2 |
| `catch \|err\|` | `err = <__slot`, owned, drops at the handler's end unless moved | double drop | `<` leaves the slot `none` (§5) |
| `catch H`, `catch \|_\|`, `catch return -1`, `catch break`, `catch continue`, `catch none` | the error drops before the handler runs | a leak along a jump | dropping first means no jump forgets it; `\|_\|` must mean the same as no name (decision 4 below) |
| `catch \|e\| return e`, `catch return err` | moves into the enclosing `__out` | an error outside the declared set | R2's subset check at `return` |
| a handler that fails, `catch \|e\| g()!` | `g` fails into the enclosing `__out`; `e` is a local of the handler | `e` leaks | the exit primitive drops the handler's region |
| `errdefer` and `defer` while an error is in flight | they run after `__out` is written; they cannot name it (`errdefer \|e\|` is rejected, p2), cannot propagate, and a `catch` in them has its own slot | a nested failure overwriting the outer payload (L2's bug) | L3: each `catch` owns its slot. The proposal's `error_payload_errdefer` test covers it |
| failure out of `main` | `main`'s drops and defers run, then the error prints, drops, exit 1 | printing fields that view dropped locals | I2: no field views anything. The leak check must run after the error drops (T9) |
| failure out of a `test` | as `main`, reported by the runner | a false leak report | the same order (T10) |
| `List[error]` | elements are whole errors, moved in with `<e`, cloned with `+e`, dropped by `error`'s glue | a bare `push(e)` duplicating | `error` is owning (R1, built) |
| `match <e` | arms bind fields owned; a whole-binding arm takes all of it; `_` drops it | partial moves (Trig NEEDS 26) | payload enums already move fields out of a moved subject (p1) |
| `match e` | arms bind views of owning fields, copies of plain ones; `e` is lent for the arm | moving `e` in an arm | the header's read loan (§3) |
| `g: E =>` | under `match e`, `g` sees `e`'s payload as an `E`; under `match <e`, `g` owns it | a view of a Zig temporary made by converting `error` to `E` | layout rule below (decision 9): one byte layout, so narrowing is a view of the same bytes, a storage fact |
| `>t!`, `>t catch \|e\|` | the error moves from the task's own slot to the waiter's `__out` or handler | the task writing a waiter's frame after the waiter left (cancel or deadline) | the task owns its slot (amendment 3); a `Task` drop waits for the task to end, so the slot outlives every write |
| `<t` of a failed task, `<t.cancel()` | the task's error drops, or is given back | a leak | the `Task`'s glue drops its slot (T12) |
| `Tasks`: `>ts!`, `wait_first`, `task.all`, `par.each`, `supervise` | the runtime (Zig) keeps one error and discards the others: `wait_first` keeps the last (`tasks.zig` `last = err`), `par` the first (`ParState.fail`), `supervise` drops each failure it restarts after | leaks in Zig code no checker sees | decision 12 is incomplete: these are Zig code that *forwards* user errors. Emit gives the runtime `error`'s drop glue; every discarding site calls it (T13-T16). Two chunks failing at once each own a slot; the winner moves its error in after the `cmpxchg`, and the loser drops its own |
| `task.isolate` | `f` fails: the error passes on. `f` panics: `isolate` fails with `Stop.panicked` | the in-flight error in the caller's slot, written by `f` before a later panic | `isolate` gives `f` a slot of its own and moves it on only on a normal failure; after a panic it stays allocated, reported as left by a panic, as `f`'s frames are |
| an actor's method fails | it writes the caller's slot | the caller gone | SPEC: "A method that started runs to its end, and its caller waits for it, through a cancel too"; a withdrawn call fails with `Stop`, which has no fields. The error crosses threads, so its fields must move (amendment 1) |
| a Zig-backed function fails | it does not write the slot; the returned code names a member with no fields | a shim returning a code whose member has fields: the glue drops garbage | decision 12, plus a debug check (decision 12 below) |

**Where the slot's "none" lives.** The checker reads `__slot: error?`.
At run time there is no tag: a slot holds a value exactly when the
returned code names a member with fields. That is why a Zig-backed
function that fails with `Stop.canceled` through a Rig `T!` frame is
sound with an unwritten slot. Codes are already qualified by module and
set (`error.@"ma.ParseError.bad"`, probe p15/mods), so a code names one
member in the program, and `error`'s glue is a switch on it with
`else => {}`.

**Does it fit one paragraph (CORE §10)?** Yes, with the amendments. Its
rules follow the type (fields by their kind facts; `error` owning
always), it desugars into a write parameter that keeps nothing
(sentence 7), an optional local, and `<` of an optional place (§5), and
the task case is a value a `Task` owns. My text is under decision 1
below.

## 2. The field rules

Right in spirit; two gaps (amendments 1 and 2). Per type:

| Field type | Verdict | Why |
|---|---|---|
| `Int`, `Bool`, `Float`, plain enums | yes | plain; a set holding only these is plain and copies |
| `Static` | **yes** | it carries no loan, it moves, and it costs nothing: `bad(msg: Static)` is Go's `errors.New`, allocating nothing |
| `String`, `List[T]`, `Map`, objects of such | yes, when every part qualifies | own, clone, move |
| `^T` | yes, when `T` qualifies | one owner; `+b` copies into a new box |
| `?T`, `[]T`, `!T`, anything holding one (`List[?String]`, `^?T`, an object with a view field) | **no** | "may hold a loan": a view would outlive the frames it came from |
| `*T`, `~T`, `*fun`, `Cell`, `Signal`, `Tasks` | **no** | they never move to another thread (SPEC §18), so `error` would stop moving |
| `Task[T]`, a `unique` type, a type with a `drop` body | **no** | no `+` |
| a declared set, `cause: IoError` | yes | an error of a set qualifies by these same rules |
| `error`, inline | **no** | `error` holds every set, so a member holding it contains itself: write `^error` |
| `^error`, a cause chain | **yes** | `wrapped(msg: String, cause: ^error)` clones, moves, carries no loan; drop and print recurse |

The cause-chain case needs its own diagnostic. Today a recursive enum
says "hold it through a shared handle (`*Chain`)" (p3), which would be
wrong for an error, since `*` does not move. For an error it should say
`^error`. `^Chain` already works for enums (p3b).

Should cloning be dropped instead, to let an error give back what it
took (Rust's `IntoInnerError`, `SendError(T)`)? No. Error sets are not
generic, so `SendError[T]` cannot be written anyway. A give-back is a
result (`send(<v) -> V?`) or two results. "Every field clones" also gives
I2, that dropping an error runs no user code.

## 3. What the oracle must learn

The oracle is written from CORE alone, so CORE must state the slot (my
paragraph does). Then:

1. **`__out` as a hidden write parameter with no `keeps`**, on every
   fallible function and closure. A failing exit stores the error
   through it. The oracle's existing sentence-7 machinery (a store
   through a write parameter carries only the loans its signature keeps)
   then *derives* "no field carries a loan" without a rule of its own. A
   compiler bug that let a view into a field would show up as a
   difference. This is the best independent check available.
2. **`__slot` as a hidden owning local per catching call**, lent to
   write for the call alone. On the failure edge it is moved into the
   binding (`make` becomes a move from the slot), or dropped before the
   handler when the catch binds nothing or binds `_`. Today `fallback`
   models `err` as a fresh `.make`; with owning payloads that hides a
   double take.
3. **`e!`** stays an exit with `fails = .yes` that moves no var. The
   error is already in `__out`.
4. **Kinds:** a set's kind by the enum rule over its fields
   (`kinds.zig`); `error` stays owning (built); the typed catch
   binding's kind is its set's.
5. **Matching:** sets with fields take the payload-enum path, both read
   (alias bindings) and `<` (owned bindings), plus the `g: E =>` arm:
   alias under a read, owner under `<`.
6. **Tasks:** a fallible `Task` owns its error; `&` lends no slot. The
   oracle lowers no tasks today, so this is only a rule for when it
   does.
7. **Coverage and the matrix:** no new abstention on member
   constructors with fields in `return`, on `return x if c else E.m(..)`,
   or on catch bindings. A grid row for a set with a `String` field, in
   every context including `catch`; the new rejections are listed in
   `test/oracle/rejections`; the coverage floors do not drop.

## 4. Real use

**std.json (R4).** Do not give every member an `at: Int`. Keep the plain
`Error` enum as the kind, without `.ok`, and use one member:

```rig fragment
pub error JsonError
  bad(kind: Error, at: Int)          # plain: copies, 16 bytes in the slot
pub sub Doc.parse(!@, src: ?String)!JsonError
  ...
  return JsonError.bad(kind: .unexpected, at: i)
```

`error_pos` and `fail` go away. The position stays an `Int`, since a
view of `src` is forbidden, and rightly. **Awkward:** a field shared by
every member is spelled as one member that holds a kind enum.

**std.net, std.file.** Keep `NetError` and `FileError` without fields.
The caller knows the path or address, a field would allocate on every
failure, and adding the first owning field to a `pub` set is a breaking
change: the set's kind changes, and every copy of a caught one is then
rejected. **Awkward:** every waiting point also fails with `task.Stop`,
so a declared set for `read` is `error ReadError = NetError | task.Stop`.
One union per module adds names for little gain. Default: std's I/O
stays `T!` (any error), and only pure parsers declare sets (json,
`text.parse_float`'s `ParseError`, `bigint.parse`).

**Trig.**
- glob (R2): `parse(...) -> Glob!GlobError`; `error_text(e)` takes the
  typed binding.
- sourcemap (R2): declare `!SourceMapError`, and delete the `_ =>` arm of
  `error_text`, which becomes "this arm never runs" (p8).
- semver (R3): `parse(orig_input: String)`; `SemverParseError.error()`
  reads the field.
- harness: `TestFatal.fatal(msg: String)` replaces `TestingT.message`,
  a hand-built side channel (L2 by hand) that R3 retires.
- `core.must[E]` keeps `catch |_| none`, and can `panic(e)` once NEEDS 15
  lands.

**mini-redis.** Its `frame::Error { Incomplete, Other(Box<dyn Error +
Send + Sync>) }` maps to:

```rig fragment
error FrameError
  incomplete
  protocol(msg: String)
error ConnError = FrameError | net.NetError | task.Stop

fun Connection.parse_frame(!@) -> Frame?!FrameError
  check(!cur) catch |e|
    return none if e == FrameError.incomplete
    return e                          # a re-failure; e leaves for good
  ...
fun Connection.read_frame(!@) -> Frame?!ConnError
  while true
    if (!@).parse_frame()! as f       # FrameError is in ConnError: no From
      return f
    n = (!@stream).read(!@buffer, 4096)!
    if n == 0
      return none if @buffer.len == 0
      return FrameError.protocol(msg: String("connection reset by peer"))
```

Better than Rust: unions replace `From` conversions. Rust's own
ecosystem settled on `Send + Sync + 'static` for errors (anyhow,
`Box<dyn Error + Send + Sync>`). That is amendment 1 plus "no loan".
**Awkward:** adding context means `catch |e| return Ctx.wrap(msg: ...,
cause: ^<e)`. `^<e` boxes, and is fine.

**"Fail with a message."** Served by a `String` field (allocates once,
on failure) or a `Static` one (free). Default: no std-provided set in
R3. A program declares `error Fail / msg(text: String)` in two lines.
Revisit after Trig's semver and harness use fields. A std set would need
a name from the owner, and `main`'s printed form (`error:
Fail.msg(text: "...")`) is fine for a first cut.

## 5. Migration

- **R1, done:** one corpus probe copies an error.
- **R2 (typed binding) breaks callers, silently in count.** When a
  callee gains a declared set:
  - a `match err` that names every member and has `_ =>` is rejected,
    "this arm never runs" (p8);
  - `err == Other.x`, with `Other` not in the set, is a type error;
  - a field-less typed `err` is plain again, so the unread-binding lint
    returns: `catch |e| 6` (p14, accepted since R1) is rejected again.

  R2 counts these over suite, corpus, docs and Trig, as R1 did. Declaring
  a std set is the same break, for every caller of std.
- **R3:** no existing set has fields, so nothing changes until a set
  gains one. The ABI flip (`__out` on every fallible function once any
  set has fields) is whole-program; `equiv.py` checks the no-field
  programs.
- **Docs:** SPEC §13's `rig pending` blocks (P2-P4 and the rejections)
  become `rig`; CORE's P1 too. SPEC §18 gains "a task owns its error".
  STD's json section moves to R4.
- **Trig needs:** 17 `catch |` sites and 97 `catch` uses in `src`, about
  336 fallible signatures. It needs nothing until it opts in. The opt-in
  list is under §4 above. A migration note and script are needed only
  for std sets declared in R2.

## 6. Decisions

Each has a default and a reason, written so it can go into SPEC or CORE.

1. **The CORE paragraph** (replaces §5 of the proposal). Default:

   > **A failure moves its error.** An error set's member may carry
   > fields, as an enum's variant does; each field's type holds no loan,
   > clones, and moves to another task, so an error never limits an
   > owner, `+e` always works, and dropping one runs no `drop` body. An
   > error is plain or owning by the enum rule (§1), and `error`, which
   > holds an error of any set, is owning. Each call of a fallible
   > function is lent, hidden, a write view of a slot of its caller's,
   > which keeps nothing (sentence 7): `return E.name(...)` moves the
   > made error into it before the scope's exits run, `e!` passes the
   > slot on, and `catch |err|` moves the error into the handler's own
   > binding, which drops when the handler ends unless the handler moves
   > it on; a `catch` that binds no name, or `_`, drops it before its
   > handler runs. A task's call is lent a slot its `Task` owns, so
   > `>t!` and `>t catch` take the error from the task, and dropping the
   > task drops it. Reading, matching, printing, storing, and cloning an
   > error follow its type.

   Reason: one paragraph covering every path, the task path included.
2. **Field rule: holds no loan** (the per-type fact), not "is not a
   view". Reason: it catches `List[?String]`, `^?T` and views nested in
   objects.
3. **Field rule: moves** (SPEC §18's table); `*T`, `~T`, `*fun`, `Cell`,
   `Signal` and `Tasks` are rejected. Reason: so `error` always crosses
   tasks, whatever other code declares.
4. **`catch |_|` is `catch`:** it drops before the handler. Reason: one
   meaning for "binds nothing".
5. **`Static` allowed; `^error` allowed; inline `error` rejected** with
   "a member holding `error` contains itself: write `^error`". Reason:
   cause chains with a finite size, and a move across tasks.
6. **A task owns its slot.** `&` never lends the maker's `__out`; `>t!`
   moves the error into the waiter's slot. Reason: without it, a task
   is "lent to write", and a waiter that leaves early leaves a dangling
   slot.
7. **Runtime combinators drop what they discard** (`wait_first`, `>ts`,
   `task.all`, `par`, `select`, `supervise`), using glue emit gives the
   runtime; `isolate` gives `f` a slot of its own. Reason: decision 12
   covers shims that fail, not runtime code that forwards errors.
8. **Exit order for `main` and `test`:** drops and defers, then print,
   then the error's drop, then the leak check. Reason: no false leak,
   and I2 makes the late print safe.
9. **One layout:** every error value is `{code, bytes}`, a set's bytes
   being a prefix of `error`'s. A read narrowing `g: E =>` is a view of
   the same bytes, named by a storage fact. Reason: no view of an
   unnamed Zig temporary (weak-spots).
10. **`errdefer |e|` stays rejected,** with its own diagnostic in place
    of today's "closure parameter `e` needs a type" (p2). Reason: no
    real program asks for it yet. It would be a read view of the slot,
    sound under L3, if one ever does.
11. **The oracle learns `__out` as a write parameter keeping nothing**,
    and `__slot` as an owning local taken on the failure edge. Reason:
    it derives the field rule from sentence 7 independently.
12. **Debug builds tag the slot as written**, and a `catch` of a member
    with fields whose slot is unwritten panics, naming the Zig-backed
    function. Reason: shims are trusted; this catches the one way they
    can break I1.
13. **std's I/O stays `T!`;** only pure parsers declare sets in R2; no
    std set gains an owning field without a release note. Reason: an
    owning field changes a `pub` set's kind, and every waiting point
    adds `task.Stop`.
14. **No std "message" set in R3.** Reason: two lines in user code;
    revisit after Trig's first users.
15. **R2 counts its breaks** (dead `_` arms, out-of-set comparisons,
    the lint returning) before landing, as R1 did. Reason: the typed
    binding changes callers that did not change.

## 7. Tests that define it (all fail today)

They would sit in `test/rig/errors-data.rig.test` and
`concurrency-errors.rig.test`, sanitizer-clean, with the proposal's
P1-P4 and rejections kept. These add the paths above.

```text
fail "error field holds a loan", "an error's field never holds a loan"
  error P
    bad(names: List[?String])
fail "error field shared handle", "moves to another task"
  obj Node
    n: Int
  error P
    bad(node: *Node)
fail "error holds error inline", "write `^error`"
  error W
    wrapped(cause: error)
test "error cause chain", 'W.wrapped(msg: "load", cause: IoError.closed)'
  error IoError
    closed
  error W
    wrapped(msg: String, cause: ^error)
  fun read() -> Int!
    return IoError.closed
  fun load() -> Int!
    read() catch |e| return W.wrapped(msg: String("load"), cause: ^<e)
  load() catch |e| print(+e)            # +e clones the chain; both drop
test "error field built from a failing call", "E.other(msg: \"inner\")"
  error E
    bad(msg: String)
    other(msg: String)
  fun mk() -> String!
    return E.other(msg: String("inner"))
  fun f() -> Int!
    return E.bad(msg: mk()!)            # the inner error wins; no leak
  f() catch |e| print(e)
test "catch underscore drops before handler", "0"
  error E
    bad(msg: String)
  fun f() -> Int!
    return E.bad(msg: String("x"))
  f() catch |_| 0
test "catch jump drops", "3"
  # catch break, catch continue, catch return -1 with a String payload
fail "errdefer reads a name moved into the error", "use of `s` after move"
  error E
    bad(msg: String)
  fun f() -> Int!
    s = String("x")
    errdefer print(s)
    return E.bad(msg: <s)
bomb "main fails with a payload", "error: E.bad(msg: \"x\")"   # exit 1, leak check clean
test "test block fails with a payload"  # runner reports E.bad(msg: "x"), no leak
test "narrow read then move", seeds: 1  # match e / g: E => views; match <e / g: E => owns; print after
test "task fails with a payload", seeds: 20, 'E.bad(msg: "t")'
  t = f()&  ;  >t catch |e| print(e)
test "dropped failed task drops its error", seeds: 20    # <t of a failed task; no leak
test "wait_first all fail with payloads", seeds: 20       # the last error returned, the others dropped
test "par two chunks fail at once", seeds: 20             # one error out, the other dropped
test "sets first failure cancels the rest", seeds: 20     # the others fail with payloads too; no leak
test "supervise drops each restart's error", seeds: 20    # restarts: 2; the third error comes out
test "isolate panic after failure write"                  # panic in a defer after the slot is written: Stop.panicked, the leak reported as left by a panic
test "actor method fails with a payload", seeds: 20       # crossing threads; sanitizer-clean
test "cancel during wait leaves no dangling slot", seeds: 20
  # time.within(5 * time.MS, |<t| >t!) where t later fails with a String payload
code "no fields emits today's Zig"      # equiv: no __out when no set has fields
```
