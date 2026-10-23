# Errors that carry data: the SPEC

Status: a draft for the owner, not yet approved. It refines the design
approved on 2026-10-12 (`.git/revamp/r3/proposal-errors.md`, 18
decisions, cited here as A1–A18). R1 is built: `error` is a type, and
it is owning. Everything below is R2 onward.

Sources: three panel reports beside this file. `1-languages.md` (Rust,
Swift typed throws, Zig, Go, OCaml/Roc/Koka, Java, Midori, C++
`expected`, Erlang); `2-backend.md` (Zig 0.17 lowering, measured on
aarch64, x86-64 and wasm32; experiments in `backend-scratch/`);
`3-ownership.md` (soundness of every path, the oracle, Trig, std,
mini-redis; probes in `ownership-scratch/`). Probes run for this draft
on main ace79d579 are cited as "probe".

The panel overturned none of A1–A18. It found three holes the approval
did not see (fields must cross tasks; "never a view" must be the type
fact "holds no loan"; a task owns its slot), narrowed where the hidden
parameter appears, and fixed the layout. One conflict inside the
panel's own advice is settled in §4.3. An adversarial review
(`4-review.md`) then found four blockers in the first draft, all fixed
here: declared sets could not call std's waiting points (§3.7); a wait's
`task.Stop` was missing from typed sets (§3.8); Zig reorders struct
fields, so the layout is now explicit (§7.2); and a handle field could
run user code on drop (§4.1).

## 1. In one page

```rig pending
error FrameError
  incomplete                          # field-less: costs what an error costs today
  protocol(msg: String)               # built only when it happens

error ConnError = FrameError | net.NetError | task.Stop

fun Connection.parse_frame(!@) -> Frame?!FrameError
  check(!@cursor) catch |e|
    return none if e == FrameError.incomplete
    return e                          # e moves out; nothing is copied
  ...

fun Connection.read_frame(!@) -> Frame?!ConnError
  while true
    if (!@).parse_frame()! as f       # FrameError is inside ConnError: no conversion
      return f
    n = (!@stream).read(!@buffer, 4096)!
    if n == 0
      return none if @buffer.len == 0
      return FrameError.protocol(msg: String("connection reset by peer"))
```

What a reader needs to know:

- A member of an error set may carry fields, written and matched as an
  enum's variant is.
- A field holds data only: it holds no loan, holds no handle, and
  clones. `String`, `Static`, `Int`, `List[T]`, objects of such, `^T`,
  another set, and `^error` (a cause) qualify; views, `*T`, `~T`,
  closures, `Task`s, and inline `error` do not.
- A function may say which set it fails with (`-> T!E`, `sub f()!E`);
  `T!` stays "any error". Sets join only by a named union.
- The error moves up through `!` without a copy. `catch |e|` owns it;
  a catch with no name drops it before its handler. A task owns its
  error until someone waits for it.
- Failing out of `main` prints the fields: `error: FrameError.protocol(msg: "connection reset by peer")`, exit 1.
- A program that declares no set and no field compiles to exactly the
  Zig it does today; a program whose sets have no fields pays nothing
  at run time.

## 2. Error sets and members

**2.1 Declaration.** `error Name` at module level, members indented one
per line. A member is a name, or a name with fields in parentheses
(`bad(pos: Int)`, `full(path: String, code: Int)`), as an enum variant.
`pub error` exports the set. A set may declare methods as an enum may
(`fun FrameError.message(?@) -> Static`); nothing calls them implicitly
(§6.3).

**2.2 Union.** `error L = A | B | ...` names a union of sets. A union
lists no members of its own: "a union of error sets lists no members of
its own; declare a set for `extra` and join it". No inline unions
(`T!(A | B)` is not a form). A member belongs to exactly one declared
set; a union contains its parts' members. Unions may contain unions;
a set appearing twice is one set. A cycle of unions is rejected
("`L` joins itself through `M`"), and `error` is never a part (a union
names sets; `T!` already means any). Two parts may share a member name;
`.name` on a union binding is then ambiguous and must name the set
(`A.bad`).

**2.3 Making an error.** `E.member` or `E.member(args)`, with the enum
rules for arguments: one field may be positional (`ParseError.bad(n)`),
more are set by name. Failing always names the set (SPEC §13): a bare
`.name` where `T!E` is expected is a variant of `T`, never a member of
`E`. `.member` is for patterns and comparisons only.

**2.4 Codes.** Every member has one program-wide code, qualified by
module and set (`error.@"ma.ParseError.bad"`, as built today). The code
alone says which member, and so whether it has fields.

## 3. Declared sets (R2)

**3.1 Spelling.** `-> T!E` and `sub f()!E` declare that `f` fails only
with members of `E` (a set or a union). `-> T!` and `sub f()!` mean any
error, as today. There is no inference: an undeclared function is `T!`
(A6).

**3.2 Subsets.** At `x!` and at a failing `return`, the error's set must
be inside the function's declared set:

- `g()!` in a function declaring `!E`: `g`'s set ⊆ `E`. A `T!` callee
  cannot propagate into a declared set: "`loose` may fail with any
  error, and `narrow` declares `Int!A`: catch it, or declare `-> Int!`".
- `return B.y` where `B.y ∉ E`: "`B.y` is not in `A`, the error set `f`
  declares".
- `catch |e| return e`: `e`'s set ⊆ `E`.
- Function values are covariant in their set: a `?fun() -> T!A` may be
  passed where `?fun() -> T!L` is wanted when `A ⊆ L`, and anywhere a
  `?fun() -> T!` is wanted. An API object's implementation is covariant
  the same way.
- A value of set `E` widens to a union containing it, or to `error`,
  wherever that type is wanted (an argument, a `List[error]` push, a
  field): a code re-tag and a copy of the bytes, never a hidden call.
- Containers are invariant: a `List[E]` is not a `List[error]`, a
  `Task[T!E]` is not a `Task[T!]`. Push `<e` one at a time.
- `^<e` boxes at the expected type: where `^error` is wanted, `e: E`
  is widened first and then boxed.
- A Zig-backed `-> T!E` is cast to `E` at the call, checked in safe
  builds: a shim returning a code outside `E` panics.

No conversion runs at `!` (A10): no `From`, no hidden call. A union is
how a caller accepts several callees' sets.

**3.3 The catch binding is typed.** `catch |e|` gives `e` the callee's
set (`error` for a `T!` callee). A `match` on a declared set is
exhaustive without `_`; a `_ =>` that can never run is rejected, "this
arm never runs". Comparing with a member outside the set is a type
error.

**3.4 Narrowing.** On an `error` (or a union), an arm `g: E => ...`
matches when the error's member is in `E`, and binds `g: E`. For a set
with fields, under `match e` it is a view of the same bytes (§7.2);
under `match <e` it owns them. For a field-less set, `g` is a copy, the
set being plain. A member pattern from any set (`IoError.closed =>`)
also matches an `error`.

**3.5 Generic sets (R2.5, a later round).** A function may take its set
as a compile-time parameter bound only to error sets:
`sub each[E](xs: []?String, f: ?sub(?String)!E)!E`. Without it, declared
sets collapse to `T!` at the first callback, Java's checked-exception
failure, which Swift's typed throws fixed the same way. Not needed
until Trig moves its tree walkers to declared sets.

**3.6 What breaks in R2 (to count before landing).** When a callee
gains a declared set, callers that did not change can be rejected: a
dead `_ =>` arm; a comparison with a member outside the set; a typed
field-less binding is plain again, so `catch |e| 6` triggers the
unused-binding lint again (accepted since R1). R2 counts these over the
suite, corpus, docs, and Trig, as R1 did, and lists them in the release
notes. Declaring a std set is the same break for every caller of std.

**3.7 std declares the sets of its waiting points and I/O (R2).**
Without this, a declared-set function could call no `read`, `accept`,
`time.sleep`, or `task.check`, since a `T!` callee cannot propagate
into a declared set, and declared sets would work only in pure code.
The sets are field-less, so they cost nothing at run time (§7.1):

```rig pending
# std/task.rig
pub error Stop
  canceled
  timeout

pub sub check()!Stop

# std/net.rig
pub error NetError
  closed
  refused
  failed(code: Int)                   # plain: the OS code

pub error ReadError = NetError | task.Stop

pub fun Stream.read(!@, into: !String, max: Int) -> Int!ReadError
```

`time.sleep` declares `!task.Stop`; `std.file` declares `FileError`
(field-less, `failed(code: Int)`) and its waiting calls a union with
`Stop`. These are R2's std breaks, counted with §3.6.

**3.8 A wait also fails with `task.Stop`.** Waiting is a waiting point:
a canceled waiter, or one past its deadline, fails with `Stop`. So
`Task[T!E]`, `Tasks[T!E]`, and an actor method's declared set must
contain `task.Stop`, else: "a wait also fails with `task.Stop`: join it
into `E`". `task.isolate`'s set is `error`. Without this rule an
exhaustive `match` on `E` would meet a `Stop` code its `switch` never
names.

## 4. Fields

**4.1 The field rule.** Every field's type holds no loan, holds no
handle (`*` or `~`) anywhere inside it, and clones by copy, by text, or
by deep copy. Checked at the set's declaration, by the type's recorded
facts, not by its spelling:

| Field type | | Why |
|---|---|---|
| `Int`, `Float`, `Bool`, `U8`, plain enums | yes | plain; a set of only these is plain and copies |
| `Static` | yes | no loan, costs nothing: Go's `errors.New` |
| `String`, `List[T]`, objects of such | yes, when every part qualifies | own and deep-copy |
| `^T` | yes, when `T` qualifies | one owner; `+` copies into a new box |
| a declared set (`cause: IoError`) | yes | qualifies by these same rules |
| `^error`, `^E`, `List[error]` | yes | the cause chain, or several; heap-held, so finite size; drop and print recurse |
| `Map[K, V]` | not yet | `Map` has no `+` today (probe); yes once it clones |
| `?T`, `[]T`, `!T`, or anything holding one (`List[?String]`, `^?T`, an object with a view field) | no | "an error's field never holds a loan: hold a `String` or a `Static`" |
| `*T`, `~T`, `*fun`, `*Actor[R]`, `*Chan[T]`, `*Cell[T]`, or anything holding one | no | "an error's field holds no handle: `*Node` shares, and an error owns what it carries" |
| `Task[T]`, `Tasks`, `Signal`, closures, a `unique` type, a type with a `drop` body | no | "an error's fields must clone, and `Random` is unique" |
| `error` inline, or a set that holds this set inline (directly or through a union) | no | "a member holding `error` contains itself: write `^error`" |

Why each part, in one line each:

- **No loan.** An error leaves the frames it was made in; a view would
  outlive what it views. The type fact catches views nested in lists,
  boxes, and objects, which a syntax test (`is not ?T`) misses.
- **No handle.** A handle's count is not an error's to keep: dropping
  the last `*Actor[R]` or `*Chan[T]` runs `R`'s `drop` body or drops
  buffered values (probe), so an error holding one would run user code
  when it drops, and a `*T` whose count is not atomic could not cross
  threads.
- **Clones.** `+e` always works, and since a type with a `drop` body has
  no `+`, dropping an error never runs user code, so the order errors
  drop in is never observable.

These three give a fourth for free: **every error moves to another
task.** Each type that cannot cross threads (SPEC §18) is a handle, a
`Cell` (only ever behind `*`), a `Signal`, a closure, or a `Task`, and
each fails "no handle" or "clones". So `Task[T!]` and an actor's reply
carry any error, whatever another module declares: the property is
never decided by code elsewhere. Rust's ecosystem settled on the same
bound (`Box<dyn Error + Send + Sync>`).

**Cross-module clone.** A deep copy of a type declared in another
module is planned (CORE sentence 2) and rejected today (probe). R3
needs it: a set declared in one module and caught in another must
`+e`, and a field may be another module's object or set. It is a
prerequisite round (§14).

**4.2 Messages and causes.** A fixed message is a `Static` field
(`bad(expected: Static, found: U8)`), allocating nothing; a `String`
only when the text is built. Prefer structured fields and build text
where it is shown. A cause is a boxed field:
`read(cause: ^error, path: String)`. No `source` protocol and no chain
walking in the language: printing shows a cause as any field. Context
is added with `catch`, one mechanism, every allocation visible:

```rig fragment
text = file.read(p) catch |e| return Config.read(path: +p, cause: ^<e)
```

No `.context()` method; a std context set waits until a ported program
shows it is wanted.

**4.3 Comparing (settles a conflict).** Expert 1 asked that every field
also compare, so that `error == error` always works. Probe: `^T` and
`List[T]` have no `==` today, and an enum with such a field rejects even
`k == K.b`. So "fields compare" would forbid `cause: ^error`, and
"fields need not compare" would make `e == FrameError.incomplete` depend
on whether some set elsewhere has a `List`. The rule that dissolves both:

- A bare member, `e == E.member`, tests the member and never compares
  fields. It works on any error. (The same change for enums: a bare
  variant test needs no `==` on fields. Today it does.)
- `e == E.member(args)` compares that member's fields, and needs `==`
  on them; known locally.
- `a == b` on two values of a set follows the enum rule: the set has
  `==` when every field does. `error` has no whole-value `==`; match
  it, or compare members.

This changes `==` for enums too, a language change outside errors
(decision 2). The alternative leaves `==` alone and tests a member with
the patterns that exist (`match e`, `if e as FrameError.incomplete`),
at the cost of the shortest idiom.

**4.4 Printing.** Structural: `Set.member` or
`Set.member(field: value, ...)`, strings quoted, causes printed in
place. Every type the field rule admits prints. `print` and the exit
from `main` never call a set's methods, and a set may not declare its
own `Print` or `Eq` (one structural form for every error). A field
whose type has its own `Print` prints through it, as anywhere `print`
reaches it (SPEC §3, own meanings).

**4.5 Payload size.** No limit. A set's largest member sets the size of
every slot that may hold it, and `error`'s size is the program's largest
member. The docs advise `^T` for anything large. Whether to warn above
64 bytes is a decision (§15).

## 5. Handling

**5.1 Propagation.** `x!` passes the error up unchanged. Nothing copies;
the error already sits in the slot the caller lent (§7).

**5.2 `catch`.**

- `catch |e| H`: `e` owns the error; it drops when `H` ends unless `H`
  moves it (`return e`, `!list.push(<e)`, `^<e`).
- `catch H`, `catch |_| H`: the error drops before `H` runs. `|_|` means
  exactly what no name means.
- `catch return v`, `catch break`, `catch continue`, `catch none`: drop
  first, then jump; no jump can forget it.
- A handler that fails (`catch |e| g()!`) drops `e` as its region ends.

**5.2a Failing from a branch.** `return v if c else E.x(msg: <s)`, and a
`return` whose value is a `match` or `if` with failing arms, write the
slot on the failing branch only, and move `s` on that branch only; the
ownership checker treats each branch as its own exit, as it does
moves in branches today.

**5.3 `match`.** `match e` lends `e` for the arms: fields bind as views
of owning fields and copies of plain ones. `match <e` takes it: fields
bind owned, a whole-binding arm takes all of it, `_` drops it. As
payload enums, built.

**5.4 Storing.** `List[error]`, `x: error?`, a field `last: error` of an
object, all as any owning type: `<e` moves in, `+e` clones, dropping
runs `error`'s drop glue.

**5.5 `errdefer` and `defer`.** They run after the error is written,
cannot name it, and cannot propagate; a `catch` inside one owns its own
slot, so a nested failure never overwrites the one leaving. An
`errdefer` or `defer` that reads a name moved into the error is "use of
`s` after move", as today. `errdefer |e|` stays rejected, with its own
diagnostic ("`errdefer` cannot see the error leaving; catch it in the
caller") in place of today's misleading "closure parameter `e` needs a
type". Whether to reserve it as a read view is a decision (§15).

## 6. Leaving `main` and `test`

**6.1** A failure out of `main`: `main`'s drops and defers run, then
`error: Set.member(fields)` prints to stderr, then the error drops, then
the leak check runs, then exit 1. Printing late is safe because no field
views anything. The drop must precede the leak check, or every such
program reports a leak.

**6.2** A failure out of a `test` block: the same order; the runner
reports the printed form.

**6.3** No message method is called. `main`'s report shows the data.

**6.4** A `main` that fails with `task.Stop.canceled` because of an
interrupt prints nothing and exits 130 (see the Ctrl-C proposal).

## 7. Lowering (for INTERNALS)

**7.1 L3 stands, narrowed.** The catching frame owns a slot; each
fallible call is lent a hidden write view of it, `__out`; a failing
`return` writes it after the value is fully built and before the
scope's exits run; `e!`
passes `__out` on; `catch` reads it zero times, because the binding is
the slot. Measured alternatives: a tagged Result up to 31% slower; a
slot found through the fiber state unsound across `isolate` and slower;
a side channel overwritten by nested failures (L2's bug).

*Superseded 2026-10-22 (owner's decision on the design check,
errors-r3/design-check-u.md): `error` is always a `rig.ErrorValue`, and
every `T!` function and fallible function-value type takes `__out`,
which has no bits where no set has fields. The narrowing below, never
built, is dropped.*

Where `__out` appears (changed from A1's "every fallible function"):

- a named function declaring a set gets it only when that set has a
  member with fields;
- a named `T!` function gets it only when **a member with fields can
  reach `error`** in the program: some `T!` function fails with such a
  member (`return E.m(...)`), `!` or `return` passes one from a declared
  set into `T!`, or a value of such a set widens to `error`. A program
  can import std.json, whose set has fields, and pay nothing in its own
  `T!` frames as long as it catches what std.json gives or keeps it in
  a declared set;
- every function value type (`?fun`, `*fun`, a closure, an API object's
  methods) gets it on the same fact, so function-value types never
  differ by set; `FnRef.ofFn` thunks absorb Zig-backed callees;
- a Zig-backed declaration never takes it, and a direct call to one
  passes nothing (A12).

Each of these is a recorded fact, so emit decides none of them: the
program-wide facts (does a member with fields reach `error`; `N`; `A`;
which functions take `__out`) in `src/symbols.zig`, beside the
program's other whole-program facts; each slot and catch binding in
`src/storage.zig`. `rig check --facts=storage` shows `error`'s size and
the member that sets it.

Cost, measured: about 4 instructions and 16 bytes of stack per
propagating frame that makes more than one fallible call (11–15% more
instructions, 16% slower in ReleaseSafe on a recursion that does nothing
else); nothing where inlining removes the slot; wasm32 2–3 instructions.
The narrowing keeps the cost off field-less frames such as Trig's `Bail`
recursion.

**7.2 Layout.** A set without fields stays a bare Zig error set (2
bytes), named per set, so a `switch` on it is exhaustive with no
`else`; a field-less `T!` stays `anyerror`. A set with fields, and
`error` once a member with fields reaches it, is

```zig
extern struct { code: u16, data: [N]u8 align(A) }
```

with `code` the error's program-wide integer (`@intFromError`,
`@errorFromInt`), `N` the set's largest member (the program's for
`error`), and `A` the program-wide alignment for every such struct.
`extern` fixes the order: Zig's default layout reorders fields (probe:
`code` at offset 16 in one set, 24 in `error`), and an `extern` struct
cannot hold `anyerror`, hence the `u16`. So `code` sits at 0 and `data`
at `A` in every set, a set's struct is a prefix of `error`'s, and
narrowing (`g: E =>`) is a code test plus a view of the same bytes,
named by a storage fact. Rejected: a Zig tagged union per set (the code
translated at every catch) and a bare `union` (a hidden safety tag in
safe builds).

**7.3 The slot is data only.** The code stays Zig's error value. The
slot is written only for members with fields and read only after a
`switch` on the code says the member has them. A Zig-backed callee, a
cancel, or a field-less member never writes it, so a `Stop.canceled`
through a Rig frame is sound with an unwritten slot.

**7.4 Glue, generated once.** Emit writes `__rig_error_drop(code, *data)`,
`__rig_error_clone`, `__rig_error_eql` (member and field compare),
`__rig_error_print`, and the `N`, `A` constants into one program-wide
Zig file that every module imports, re-exported from the root so the
runtime reaches it through `@import("root")`; a zero-size stand-in when
no member has fields. Each is a switch on the code with `else => {}`.

**7.5 No automatic box.** An `error` holds its fields inline; boxing
per value would be a hidden allocation, on the failure path, where the
failure may be out of memory.

**7.6 Tasks.** A task owns its slot: `&` never lends the maker's
`__out`. The job record holds the slot beside the result; `start` passes
its address to `f` when `f` takes `__out`; `>t!` and `>t catch` move it
to the waiter inside `wait`, before `release` frees the record (the
job's end already orders the write before the read). Dropping a failed
task drops its error.

Two rules cover the runtime, and each site below gets a test:

1. Every runtime site that calls a Rig function value passes it a slot
   the site owns.
2. Every site that holds an `anyerror` holds the code and the data
   together, and drops the data when it discards the failure.

The sites in `src/tasks.zig` and `src/sched.zig`: `wait` and its cancel
path; `waitTasks` (`task.all`); `Tasks.wait_all` (`>ts`);
`wait_first`'s `last`; `ParState.fail` (first kept, later dropped; two
chunks failing at once each own a slot, and the winner moves in after
the `cmpxchg`); `parRun`'s body closures; the winning `select` arm's
call and `select`'s `dropAll`; `supervise`'s `f` and its restarts;
`time.within`'s closure. An actor reply's slot lives in the call's
message record, which the caller owns and waits on (a started method
runs to its end, through a cancel too), and moves to the caller's slot
as the reply is taken. `isolate` gives `f` a slot of its own and moves
it on only on a normal failure; after a panic it is reported as left by
the panic.

**7.7 `main` and tests.** The Zig `main` and `runTests` own the root
slots and call `failMain(code, data)`, which prints, drops, then lets
the leak check run.

**7.8 Debug check.** Debug builds tag a slot as written; a catch of a
member with fields whose slot is unwritten panics, naming the catch
site's callee (the shim is somewhere below it). Shims are trusted (A12); this
catches the one way they can break the invariant.

**7.9 Zig's error return traces.** Kept at Zig's default (Debug only,
measured null in ReleaseSafe and ReleaseFast), never printed. Mapping
their frames to Rig lines when a failure leaves `main` is a decision
(§15).

**7.10 Equivalence gate.** *Superseded 2026-10-22 (design-check-u.md):
the gate is the json instruction guard, with Trig's and std.json's
timing on both machines.*  `tools/equiv.py` shows no emit difference
for any program that declares no set (R2), and none for any program in
which no member with fields reaches `error` beyond the declared-set
functions that carry it (R3), including a program whose only fields
come from an imported std.json. The runtime plumbing
(comptime-gated on the root's declaration) lands first as its own
commit, so R3's runtime section is also unchanged against that base.

## 8. The two invariants

- **I1.** A slot holds at most one error, written once, as its call
  leaves. Only a failing `return` writes `__out`, after its value is
  built; the scope's exits then run, and none of them can name it or
  propagate. `return E.x(msg: g()!)`
  evaluates `g` first; if `g` fails, `E.x` was never made. A `catch`
  empties its slot.
- **I2.** An error holds no loan, and dropping it runs no user code. So
  no frame it passes through is limited by it, and drop order is never
  observable.

Every path in `3-ownership.md` §1 (21 of them, tasks and actors
included) rests on one of the two.

## 9. CORE paragraph (replaces "A failure moves its error")

> **A failure moves its error.** An error set's member may carry
> fields, as an enum's variant does; each field's type holds no loan,
> holds no handle, and clones, so an error never limits an owner, moves
> to any task, `+e` always works, and dropping one runs no `drop` body. An error is
> plain or owning by the enum rule (§1), and `error`, which holds an
> error of any set, is owning. Each call of a fallible function is lent,
> hidden, a write view of a slot of its caller's, which keeps nothing
> (sentence 7): `return E.name(...)` moves the made error into it before
> the scope's exits run, `e!` passes the slot on, and `catch |err|`
> moves the error into the handler's own binding, which drops when the
> handler ends unless the handler moves it on; a `catch` that binds no
> name, or `_`, drops it before its handler runs. A task's call is lent
> a slot its `Task` owns, so `>t!` and `>t catch` take the error from
> the task, and dropping the task drops it. Reading, matching, printing,
> storing, and cloning an error follow its type.

It fits CORE §10's one-paragraph test. As a CORE change it goes through
the CORE process (4–7 experts revise, then the final pass) before R3.

## 10. The oracle

The oracle is written from CORE alone, so the paragraph above must say
the slot, and it does. The oracle then learns:

1. `__out` as a hidden write parameter with no `keeps` on every
   fallible function and closure. For named functions, sentence 7 then
   derives "no field carries a loan" with no rule of its own, an
   independent check. A function value names no `keeps` (sentence 7),
   so for closures the oracle needs the field rule's type fact, and the
   check there is not independent; a grid row covers a closure that
   fails with a `String` field built from a capture.
2. `__slot` as a hidden owning local per catching call, lent to write
   for the call alone; on the failure edge moved into the binding, or
   dropped before the handler when it binds nothing or `_`. (Today
   `fallback` models `err` as a fresh make, which would hide a double
   take.)
3. `e!` stays an exit that fails and moves no variable.
4. Kinds: a set by the enum rule; `error` owning (built); the typed
   binding's kind is its set's.
5. Matching: sets with fields take the payload-enum path, read and
   take, plus `g: E =>`.
6. Tasks: a fallible `Task` owns its error (a rule for when the oracle
   lowers tasks).
7. No new abstentions; a grid row for a set with a `String` field in
   every context including `catch`; new rejections recorded in
   `test/oracle/rejections`; coverage floors do not drop.

## 11. Tests that define it (all fail today)

In `test/rig/errors-sets.rig.test` (R2), `errors-data.rig.test` and
`concurrency-errors.rig.test` (R3), sanitizer-clean, `seeds: 20` for
every task case. The proposal's own cases P1–P4 and its rejections stay,
and SPEC §13's `rig pending` blocks become `rig`.

R2:
- typed binding; exhaustive `match` without `_`; "this arm never runs";
- subset at `!`, at `return`, at `catch |e| return e`; `T!` into `!E`
  rejected; covariant function values;
- `g: E =>` narrowing; union of unions; "a union lists no members"; a
  cyclic union rejected;
- `-> Color!Lookup` with `return .missing` means `Color.missing`;
- `List[E]` where `List[error]` is wanted, rejected;
- std's waiting points under declared sets: `read`, `sleep`, `check`
  propagate into `!ReadError`-style unions;
- `>t!` inside an `!E` function whose `E` lacks `task.Stop`, rejected;
  cancel a waiter on a `Task[Int!E]` whose `match` has no `_`
  (`seeds: 20`).

R3, fields and handling:
- rejections: a field holding a loan (`List[?String]`); `*Node`,
  `*Actor[R]`, `*Chan[T]`, `*Cell[Int]`; a `unique` type; inline
  `error` ("write `^error`");
- a set with a `String` field declared in another module: caught,
  `+e`, used as `cause:`;
- narrowing under `match e` when a set's natural alignment differs
  from `error`'s;
- `^<e` of a typed `e` into `^error`;
- a direct Zig-backed `T!` call, and a shim used as a value, in a
  program with fields;
- cause chain `W.wrapped(msg: "load", cause: IoError.closed)`, cloned
  with `+e`, both drop;
- `return E.bad(msg: mk()!)` where `mk` fails: the inner error wins, no
  leak;
- `catch |_|` drops before its handler; `catch break`, `continue`,
  `return -1` with a `String` payload drop;
- `errdefer print(s)` then `return E.bad(msg: <s)`: "use of `s` after
  move";
- `match e` then `match <e`, narrowing read then take;
- bare member test on an error whose set has a `^error` field (§4.3);
- `List[error]` of mixed sets, printed.

R3, leaving and tasks:
- `main` fails with a payload: prints `error: E.bad(msg: "x")`, exit 1,
  leak check clean; the same for a `test` block;
- a task fails with a payload; a dropped failed task drops it;
- `wait_first` all failing; `par` with two chunks failing at once;
  `>ts` canceling the rest; `supervise` dropping each restart's error;
  `task.all` with two payload failures; a `select` arm failing with a
  payload; a `par.each` body failing; a `time.within` closure failing
  with a payload;
- `isolate` with a panic in a defer after the slot is written;
- an actor method failing with a payload across threads;
- a deadline leaving a wait early: no dangling slot;
- `code` case: a program with no fields emits today's Zig (no `__out`).

## 12. Use, std, Trig, and migration

**std.** I/O and waiting points declare field-less sets (§3.7), with
`failed(code: Int)` for the OS code at most: the caller has the path
and adds it with §4.2, and a field would allocate on the normal path of
probing files. Pure parsers declare sets too (json, `text.parse_float`,
`bigint.parse`). An owning field added to a `pub` set changes its kind
and is a release-note break. `task.Stop` stays field-less.

**std.json (R4).** `pub error JsonError / bad(kind: Error, at: Int)`,
plain, 16 bytes; `error_pos` and `fail` go; within the 2% guard, and
gated on Trig's timing too, since a Trig `T!` function that `!`s a
`JsonError` turns on `__out` for its `T!` frames (§7.1).

**No std message set.** "Fail with a message" is two lines a module
declares: `error Proto / bad(msg: String)`.

**Trig.** Nothing changes until it opts in. Then: glob and sourcemap
declare sets (R2; sourcemap's `_ =>` arm goes); semver's
`parse(orig_input: String)` (R3); the test harness's
`TestFatal.fatal(msg: String)` replaces the hand-built side channel
`TestingT.message`; 41 `isolate` sites want the panic's message, which
stays out of `Stop` (decision 12). About 336 fallible signatures, 97
`catch` uses, 17 bindings.

**mini-redis.** Section 1's sketch: unions replace Rust's `From`
conversions, and `protocol(msg: String)` replaces
`Other(Box<dyn Error + Send + Sync>)`.

**Migration.** R2 breaks callers silently in count (§3.6): counted,
listed, Trig warned with a script if any of its code breaks. R3 breaks
nothing until a set gains a field.

## 13. Out of scope

Unwinding and `recover` (A13: a panic ends the program); the `try` block
(A18, reserved); conversions at `!`; inferred sets; inline unions; open
sets (a set the system may grow keeps a catch-all member, and adding a
member to a `pub` set is a release-note break); a source/backtrace
protocol; errors generic over a type (`SendError[T]`: a give-back is a
result instead).

## 14. Plan

| Round | What | Size | Gates |
|---|---|---|---|
| R2 errsets | declared sets, unions, subsets, typed binding, narrowing, coercions, the `Stop` rule, std's sets (§3.7), the bare-member rule of §4.3 | 4–6 days | full suite; R2's breaks counted; Trig warned with a script; Trig builds |
| Ctrl-C | interrupt cancels `main` (separate proposal) | 1–2 days | pup in three modes, the four concurrency benches, Trig builds |
| clone | cross-module deep copy (CORE sentence 2, planned), and `Map`'s `+` | 2–4 days | full suite; Trig builds |
| R3a | runtime plumbing for slots, comptime-gated, no behavior change | 1–2 days | equiv.py shows nothing; pup; Trig builds |
| CORE | the paragraph of §9 through the CORE process | 1 day | owner accepts |
| R3 errdata | fields, slots, glue, tasks, main, oracle | 1.5–2 weeks | full suite; oracle silent; equiv for field-less programs; sanitizer; pup; Trig builds |
| R4 jsonerr | std.json's `JsonError` | 3–4 days | json within 2%, both machines; Trig's timing |
| R2.5 | generic error sets | 2–4 days | before Trig moves walkers |
| later | `isolate`'s panic message; trace mapping; `errdefer \|e\|` if wanted | small each | |

Ctrl-C goes before R3a because both touch the runtime's cancel path, and
the smaller one should settle it first. The clone round can run beside
R2; R3 needs both.

## 15. Decisions for the owner (default first)

1. **Field rule:** a field holds no loan, holds no handle, and clones,
   checked by type facts; crossing tasks follows. Amends A2, which said
   only "never a view, always clones". [yes]
2. **Comparing:** a bare member (`e == E.x`) tests the member and needs
   no field `==`, for errors and enums alike; `e == E.x(args)` compares
   those fields; `error` has no whole-value `==`. [yes] Alternative:
   every field must compare, which forbids `cause: ^error` and `List`
   fields until boxes and lists get `==`.
3. **Where `__out` appears:** on a declared-set function whose set has
   fields, and on `T!` functions and function values only once a member
   with fields reaches `error` somewhere in the program. Amends A1's
   "every fallible function". [yes]
4. **Layout:** `extern struct { code: u16, data }`, program-wide
   alignment, a set's struct a prefix of `error`'s; no automatic box.
   [yes]
5. **A task owns its error;** runtime combinators drop the errors they
   discard; `isolate` gives `f` its own slot. [yes]
6. **The CORE paragraph** of §9 goes through the CORE process before
   R3. [yes]
7. **`catch |_|` means `catch`:** drops before the handler. [yes]
8. **Payload size:** advice only, as A15 approved. [advice] Alternative:
   warn when a member exceeds 64 bytes, naming it and suggesting `^T`
   (expert 1 prefers the warning).
9. **`errdefer |e|`:** stays rejected, with a clear diagnostic. [rejected]
   Alternative: reserve it now as a `rig pending` read view, built after
   R3.
10. **std:** I/O and waiting points declare field-less sets in R2
    (`task.Stop`, `net.ReadError = NetError | task.Stop`, ...), so
    declared-set code can wait and read; no std message set. [yes]
    Alternative: std stays `T!`, and declared sets are for pure code
    until a later round.
11. **Generic error sets** (`[E]`) as R2.5, before Trig moves its
    walkers to declared sets. [yes]
12. **`task.Stop` stays field-less;** `isolate`'s panic message, if
    Trig needs it, comes by another route later, not
    `Stop.panicked(msg)` (which would break A12 and make `Stop`
    owning). [yes]
13. **Zig error return traces:** kept at Zig's default, never printed;
    mapping them to Rig lines is a later small change. [later]
14. **A wait's set contains `task.Stop`:** `Task[T!E]`, `Tasks[T!E]`,
    and an actor method's declared set must include it. [yes]
15. **Cross-module clone** (and `Map`'s `+`) is built as its own round
    before R3. [yes] Alternative: R3 rejects other modules' types as
    fields until then.
16. **Order:** R2 (+ clone beside it) → Ctrl-C → R3a → CORE → R3 → R4
    → R2.5. [yes]


---
Approved by the owner on 2026-10-21, in his words: "Approve the defaults in §15 of the errors SPEC and in the Ctrl-C proposal."
