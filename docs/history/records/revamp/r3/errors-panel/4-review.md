# Review 4: an adversarial read of errors-spec.md

Read on main ace79d579 (`bin/rig` 0.2.9, Zig 0.17.0, aarch64 macOS).
Probes are in `scratchpad/review-probes/` (`lay.zig`, `ext.zig`, `q1`–`q10`,
`r1`–`r4`, `s1`–`s3`, `mods/`), run with `RIG_OUT_DIR` there. Nothing in
the repository was touched.

Ranked: 4 blockers, 8 majors, 10 minors, then the missing tests.

---

## Blockers

### B1. The one-page example is rejected by the SPEC's own rules (§1, §3.2, §12)

**Scenario.** `read_frame -> Frame?!ConnError` calls
`(!@stream).read(!@buffer, 4096)!`. `std/net.rig:51` declares
`pub fun read(!@, into: !String, max: Int) -> Int!`, which is any error.
§12 keeps it that way ("I/O stays `T!`"). §3.2 says "a `T!` callee
cannot propagate into a declared set". So the headline example fails with
"`read` may fail with any error, and `read_frame` declares
`Frame?!ConnError`".

The same rule shuts every declared-set function out of every waiting
point: `time.sleep` and `task.check` (`std/time.rig`, `std/task.rig`,
both `sub ...()!`), `time.within` (`-> R!` until R2.5), channel
`send`/`recv`, and `>t!` of a `Task[T!]`. Declared sets as specified
work only in pure code. That contradicts the mini-redis motivation and
the `ConnError = FrameError | net.NetError | task.Stop` union, which can
never be filled.

**Fix.** Pick one:
- (a) std's I/O and waiting points declare field-less sets:
  `sub sleep(ns)!task.Stop`, and `read -> Int!net.ReadError` with
  `error ReadError = NetError | task.Stop`. This costs nothing at run
  time, because a field-less set gets no `__out` (§7.1). It is the
  typed-binding break of §3.6, counted.
- (b) Change the example, and say plainly that declared sets are for
  pure code until std declares its sets.

Decision 10's reason against (a) ("one union per module adds names for
little gain") does not survive this.

### B2. A wait fails with `task.Stop` too, and the SPEC never puts `Stop` in its set (§3.3, §7.6, SPEC §18)

**Scenario.** `t: Task[Int!E]`, then `>t catch |e| match e` with one arm
per member of `E` and no `_`. Waiting on a fallible task is a waiting
point (SPEC §18): a canceled waiter, or one past its deadline, fails with
`Stop.canceled` or `Stop.timeout`. If the binding is typed `E`, as §3.3
implies, the match is exhaustive. Emit then lowers it with
`else => unreachable` (proposal §4, R2), and a `Stop` code reaches that
`unreachable`: undefined behavior in ReleaseFast, a wrong arm otherwise.

The same gap exists for:
- `>ts!`, `<ts.wait_first()`, and `task.all` on declared sets;
- an actor method declared `-> T!E` called through a handle: a
  withdrawn call fails with `Stop` (SPEC §18, Actors);
- `task.isolate(f)`, which fails with `Stop.panicked`;
- `>t!` inside an `!E` function: the subset check must count `Stop`.

**Fix.** One local rule: `Task[T!E]`, `Tasks[T!E]`, and an actor
method's declared set must contain `task.Stop`. Otherwise reject:
"a wait also fails with `task.Stop`: join it into `E`". `isolate`'s set
is `error`. Add a `seeds: 20` test that cancels a waiter on a
`Task[Int!E]` whose match has no `_`.

### B3. "A set's bytes are a prefix of `error`'s" is false in Zig (§7.2, §3.4)

**Probe `lay.zig`.**
- `struct { code: E, data: [16]u8 align(8) }` puts `code` at offset 16
  and `data` at 0.
- The `error` struct puts `code` at 24.
- A set whose data has alignment 1 puts `data` at 2, while `error` puts
  it at 0.

Zig's auto layout reorders fields. The backend's own prototype
(`anyerr.zig`) gives each set its own alignment, so the data offset
differs as well. **Probe `ext.zig`:** "extern structs cannot contain
fields of type 'anyerror'", so `extern` is no way out.

A narrowing `match e / g: E =>` "as a view of the same bytes" then reads
the code and the fields at the wrong offsets. Safe code reads corrupt
memory, which breaks North Star 2.

**Fix.**
- Represent the code as a `u16` (`@intFromError` / `@errorFromInt`) in
  an `extern struct { data: [N]u8 align(A), code: u16 }`, with every set
  using the program-wide `A`, so `data` sits at offset 0 everywhere.
- Or narrow as two named storages: the code copied, and a view of the
  `data` bytes only.

Add a test whose set aligns differently from `error`.

### B4. I2 ("dropping an error runs no user code") is false under the fact-based field rule (§4.1, §8, CORE paragraph)

**Scenario.** §4.1 checks fields "by the type's recorded facts, not by
its spelling".
- `*Actor[R]` holds no loan.
- It moves: SPEC §18 says actor handles cross tasks, counted atomically.
- It clones: `sema.cloneable` gives `.bump` for `.shared`, and
  `deepCloneable` is true for a `.shared` part.

So `error P / bad(a: *Actor[R])` qualifies. **Probe `q5`:** an enum with
a `*Actor[R]` field, where `R` has a `drop` body, accepts `+k`, and
dropping the last handle prints `drop 1`: user code ran.

`*Chan[T]` behaves the same way, since buffered `T`s drop when its last
handle goes. `*Cell[Int]` qualifies too: it is one word, so it moves,
and `+` shares it rather than copying it. The table's "`*T` … no" row is
spelling, which the facts contradict.

**Fix (it also dissolves a rule).** The field rule becomes: "holds no
loan, holds no handle (`*`, `~`) anywhere, and clones by copy, text, or
deep copy". Every type that fails "moves" is a handle, a `Cell` (only
behind `*`), a `Signal`, a function, or a `Task`/`Tasks`, and each of
those already fails "no handle" or "clones". So "moves" follows and
needs no fact of its own. Add a rejection test for `*Actor[R]`.

---

## Majors

### M1. "`+e` always works" is false across modules, and `Map` does not clone (§4.1, §9; CORE sentence 2)

CORE sentence 2 says a deep copy "of a type declared in another module
… is *planned*". `sema.fieldsCloneable` returns false for a proxy type.
- **Probe `mods/`:** `+b` of a `lib.Box2` holding a `String` is rejected:
  "a type from another module, has no clone".
- **Probe `q7`:** `+m` of a `Map[Int, Int]` is rejected.

What breaks:
- `+e` on a typed binding of another module's set with owning fields
  (Trig's semver set, caught in another file);
- `cause: lib.LibError`, or an object field from another module, which
  the field rule rejects;
- the table's `Map[K, V]` "yes" row.

**Fix.** Make cross-module deep copy (and `Map`'s `+`) a stated
prerequisite of R3 in §14, or restrict the field rule and say so. Strike
`Map` from the table until it clones.

### M2. The cost of every `T!` function is decided by code elsewhere (§7.1, §7.10, §12)

`__out` goes on every `T!` function, and on every function value, once
any module in the program declares a member with fields. R4 gives
std.json `JsonError.bad(kind, at)`, and Trig imports std.json (5 files
under `trig/src`). Trig has no `Bail` set (grep: none). So after R4,
every `T!` frame in Trig pays the measured 11–15% in instructions, and
every program using std.json loses the equiv gate.

§7.1's "keeps the cost off … Trig's `Bail` recursion" holds only for a
declared set that does not exist. Decision 12's `Stop.panicked(msg)`
would do the same to every program that uses std.task. This is a
non-local cost rule.

**Fix.**
- Trigger `__out` on `T!` by a recorded program-wide fact: "a member
  with fields can reach `error`". It holds only at a widening point: a
  `return E.m(...)` in a `T!` function, `!` or `return` from a set with
  fields into `T!`, or a coercion to `error`.
- Gate R4 on Trig's timing.
- Keep `Stop` without fields.

### M3. `.member` construction contradicts SPEC §13 and CORE 10 (§2.3)

§2.3 lets `.member(...)` make an error inside a function that declares
`!E`. SPEC §13 says "Failing always names the error set", and that a bare
`.name` where a `T!` is expected is a variant of `T`. With
`-> Color!Lookup` and `return .missing`, it could be `Color.missing` (a
success) or `Lookup.missing` (a failure). **Probe `r4`** confirms that
today it is the success.

**Fix.** Delete the sentence. `.member` stays for comparisons and
patterns only.

### M4. Runtime sites the SPEC does not list (§7.6)

`src/tasks.zig` holds or forwards Rig failures in places §7.6 omits:
- `waitTasks` (`task.all`, `var failure: ?anyerror`, line 349);
- `Tasks.wait_all` (`>ts`, about line 486);
- the winning select arm's `arms[k].f.call(...)` (about line 1407), a
  fallible user closure the runtime calls;
- `parRun`'s body closures;
- `supervise`'s `f`.

Where an actor reply's slot lives (the caller's frame or the message
record) is also unstated.

**Fix.** Two rules:
1. Every runtime site that calls a Rig function value passes it a slot
   it owns.
2. Every site that holds an `anyerror` holds the code and the data, and
   drops the data when it discards the failure.

Enumerate the sites with a test each: `task.all` with two payload
failures, a select arm failing with a payload, a `par.each` body.

### M5. Decision 12 contradicts A12, and makes `Stop` owning (§15.12)

`Stop.panicked(msg: String)` would be written by Zig runtime code. A12
says Zig-backed declarations fail only with sets that have no fields,
and §7.8's debug check enforces that. It also makes `task.Stop` owning,
which breaks every program that copies a caught `Stop` (§12's own rule).
And it triggers M2 for every concurrent program.

**Fix.** Keep the panic text in the report, or give `isolate` a separate
result. If it is kept, list it as an amendment of A12.

### M6. Zig-backed `T!` calls, and "emit decides nothing" (§7.1, §7.4)

§7.1 gives every named `T!` function `__out` in a program with fields.
Zig-backed declarations cannot take it, so direct calls to them must
pass nothing. The backend report says this; the SPEC does not.

Several things emit needs are not assigned to a pass: whether the
program has fields, `N` and `A`, which functions take `__out`, the
widening points (M7), and whether each slot is unwritten. North Star 4
needs them as recorded facts.

**Fix.** Exclude Zig-backed declarations explicitly. Name the pass:
modules.zig or symbols.zig for the program-wide facts, storage.zig for
the slots.

### M7. Coercions not specified (§3.2, §5.4, §7.2)

- `E` to `error`, and `E` to a union `L`: a re-layout of the code and a
  copy of the bytes.
- `^<e` of a typed `e: E` where `^error` is wanted (§4.2's own idiom):
  a box cannot be re-laid out in place.
- `List[E]` against `List[error]`: must be invariant.
- `Task[T!E]` added to `Tasks[T!]`.
- An API object's method set against an implementation's.
- A Zig-backed `-> T!E`, where the shim may return a code outside `E`.

**Fix.** State each one: containers are invariant; `^<e` boxes at the
expected type; implementations are covariant in their set; a Zig-backed
`T!E` is `@errorCast`, safety-checked.

### M8. The oracle's "independent derivation" covers named functions only (§10.1)

CORE sentence 7 says a function called as a value "names no `from` or
`keeps`, so nothing narrows its result or its stores". So "keeps nothing"
derives "no field holds a loan" only for named bodies. For closures and
function values, the oracle needs the field rule's type fact, so the
check is not independent there.

**Fix.** Say so, and add an oracle grid row: a closure that fails with a
`String` field built from a capture.

---

## Minors

- **m1 (§4.4, §6.3).** "Never calls a set's methods", but field types
  that name `Print` or `Eq` run user methods "at every level" (SPEC
  §3, Own meanings). Can `error E: Print` be declared? Decide, and say
  so.
- **m2 (§2.2).** Unions need rules for:
  - cycles (`L = A | M`, `M = L | B`);
  - `error` as a part;
  - a set holding a union that holds the set (inline size);
  - two parts with the same member name, for `.name` resolution on a
    binding of the union.
- **m3 (§4.1).** `List[error]` as a field is heap-held, with a finite
  size, but the "error inline: no" row reads as rejecting it. Say which
  applies.
- **m4 (§7.1 against §5.5).** "Writes it as its last act", yet the
  defers run after the write. Say "before the scope's exits run", as
  §9 does.
- **m5 (§8).** No desugaring is given for
  `return v if c else E.x(<s)`, or for a `match`-valued return: the
  write happens per branch, and the move is per branch. The proposal's
  §4 covers only the plain `return`.
- **m6 (§3.4).** Narrowing to a field-less set should copy the code,
  since the set is plain, not view it.
- **m7 (§7.8).** "Naming the Zig-backed function" needs run-time
  provenance once the error has passed several frames. Name the catch
  site's callee instead.
- **m8 (§4.5).** `error`'s size is set by code elsewhere. Make
  `--facts=storage` show `error`'s size and the member that sets it
  (the backend's suggestion) part of R3.
- **m9 (§4.3).** The bare-member rule changes `==` for enums too: a
  language change outside errors (decision 2). Alternative: test
  members with `match` or `as` patterns, which exist, and leave `==`
  alone.
- **m10 (§1).** "A program with no field anywhere compiles to exactly
  today's Zig" also needs "and declares no set". Otherwise state how a
  field-less declared set lowers (`anyerror` or a named Zig set), and
  where `else => unreachable` appears.

## What was checked and holds

- The `errdefer |e|` diagnostic is misleading today (r1).
- `catch |e| 6` is accepted today (r2).
- A `T!` shim works as a function value today (r3).
- `List` has no `==`, and an enum with a `List` field rejects `k == K.a`
  (q1).
- Variant fields take no defaults (q3), so a bare `E.m` is unambiguous.
- `return` of a view of an error is rejected (s1, s2).
- The slot invariants I1 and I2 hold for `catch`, `!`, the defers, and
  `main`, except for B4.

## Tests to add (beyond §11)

- B2: cancel a waiter on a `Task[Int!E]` that matches without `_`;
  `>t!` in an `!E` function without `Stop`, rejected.
- B3: narrow under `match e` when the set's alignment is not `error`'s.
- B4: a `*Actor[R]` field, `*Chan[T]`, and `*Cell[Int]`, rejected.
- M1: a set with a `String` field declared in another module: caught,
  `+e`, used as `cause:`.
- M4: `task.all` with two payload failures; a select arm failing with a
  payload; a `par.each` body failing; a `time.within` closure failing
  with a payload.
- M6: a direct Zig-backed `T!` call, and a shim used as a value, in a
  program with fields.
- M7: `^<e` of a typed `e` into `^error`; `List[E]` where
  `List[error]` is wanted, rejected.
- M3: `-> Color!Lookup` with `return .missing` means `Color.missing`.
- m2: a cyclic union, rejected.
- equiv: a program whose only fields come from an imported std.json.
