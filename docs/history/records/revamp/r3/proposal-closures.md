# Proposal: closures as values (Trig NEEDS 5)

Status: design for the owner's decision. No code changed. Probes ran on
main at ad195ccff in a detached worktree (`rig-closprobe`) under
`cpuq run --cores 2` with a temp `RIG_OUT_DIR`; ids below (p1, q9, ...)
name them, and the sources are in this session's scratchpad.

## 1. The problem

### Evidence from ts-rust (Trig `docs/research/02-rust-census.md`, own grep of `misc/ts-rust`)

| Shape | Count | Example |
|---|---:|---|
| closure passed to a call, `&mut dyn FnMut` | 494 | `for_each_child(self, v: impl FnMut(Node) -> bool)` |
| Go func param, checker passed in | 93 | `f: &mut dyn FnMut(&mut Checker, TypeId) -> TypeId` (`checker_p31.rs:370`) |
| stored, `Rc<dyn Fn*>` / `Box<dyn Fn*>` | 156 / 105 | `TypeMapperFn = Rc<dyn Fn(&mut Checker, TypeId) -> TypeId>` (`checker/mapper.rs:28`) |
| stored `FnMut` | ~8 | `Box<dyn FnMut(TextRange) -> bool>` over an owned `Vec` and an index (`format/span.rs:127`) |
| stored `FnOnce` | ~40 | save/restore cleanups, `Box<dyn FnOnce(&mut Checker)>` (`nodebuilder_scopes.rs:137`) |

The stored signatures, by frequency: `Fn(&str) -> Path/String/bool`,
`Fn(&mut Checker[, TypeId|Node…]) -> TypeId/SymbolId/Diagnostic`,
`Fn(Node) -> …`, `Fn(Vec<FileEvent>)`, `Fn(Options) -> Rc<dyn Resolver>`.
The stored closures capture owned values (`name.to_string()` moved in),
a `Cell` cache, or an `Rc` handle; none can capture a borrow (`'static`).
So the stored callbacks need **write-view, read-view, and owning
parameters, and owning and handle results** — not new capture forms.

### What works today

| Need | Today | Probe |
|---|---|---|
| a callback lent to a call, invoked with another write view | `sub walk(!self, f: ?sub(!Checker, Int))` calling `f(!self, i)`, with `\|!seen, k, n\|` | p1, q8, q9 run clean |
| capturing what the call writes (a literal lends its captures for the call only) | `(!c).walk(\|!c, n\| …)` rejected: "cannot lend `c` to write while a read loan is live" | p2 |
| function values with view params in fields, Lists, generic `T` | `f: fun(!Checker, Int) -> Int`, `List[fun(!C, Int) -> Int]`, `self.hooks[0](!self, 2)` | q2, s1, s2 |
| owned closures stored and called | `*fun` fields, `List[*fun]`, generic `T`, `self.cb(x)`, `?*fun` params | tests `function_field_call`, `lend_path_function_field`, `generic_holds_owned_closure`, `owned_closure_through_view` |
| owned closures returned, capturing by move or clone | `*\|<owned, n\| owned.len + n`, `make_counter` | p5, SPEC §11 |
| mutable state in a stored closure | a captured `*Cell` | p9 |
| the callee of a call held while later arguments run | `c.cb(reset(!c))` rejected: "while the callee's read of it is in use" | s3 |
| a result viewing an owned closure's environment | rejected: "cannot return a view of `s`, which this function was not lent" | r1 |

### What fails

`*sub(!Checker, Int)` (p3), `*fun(?String) -> String` (p4),
`*fun(Int) -> List[Int]` and `*sub(List[Int])` (p10, p14): "an owned
closure takes [returns] plain data … is not one". `(+self.cb)(x)` (r5):
"a temporary that owns a resource, and nothing would drop it". And, by
design, `|<v, n| !v.push(n)` (p8): "captures are fixed".

The gap is one restriction (SPEC §18, "an owned closure taking or
returning an owning value"), which also bars views, plus a temporary
callee. The restriction is historical, not a soundness rule: it came in
with `ec54dc3f0` as "plain Copy values cross the type-erased form", and
the 2026-09-25 triage deferred "owned closures with non-Copy params" to
the roadmap (ledger, Phase 4). `rig.FnRef`, which callable views use,
already carries any parameter and result through the same erased tuple.

## 2. Options and recommendations

**Q1. What may an owned closure take and return?** A: plain data
(today); Trig would replace 261 stored callbacks with enums. B: owners
and handles too, no views (ROADMAP's line); still blocks every
`Fn(&mut Checker, …)` and `Fn(&str)`. **C (recommended): anything a
function's signature may hold.** The desugaring (§4) makes an owned
closure a method on its environment, so sentences 4 and 7 apply as is.

**Q2. How does a write view reach a stored closure?** **A
(recommended; today for captures): only as an argument, for one call**;
the environment is a no-loan home (sentence 9). B: `*|!x|` captures it,
putting a write view inside a value (Core §5): not done.

**Q3. Mutable environment (stored `FnMut`, ~8 sites).** **A
(recommended): none.** State lives in a captured `*Cell`, or comes in
as a `!` argument each call: mutation is never data. B: a unique `^fun`
called `!f(x)`, whose body writes its captures; sound (the write loan
on `f` excludes re-entry), but a new kind for ~8 sites.

**Q4. Call-once closures (stored `FnOnce`, ~40 sites).** **A
(recommended): none;** call, then `<f`. A body that must give a captured
owner back takes it from a `*Cell[T?]` with `replace`; most ts-rust
cleanups are save/restore pairs, which port as a saved value and a plain
`restore(!c, <saved)`. B: `<f(x)`, a consuming call on a `^fun` that may
move its captures; defer with Q3B.

**Q5. Type spellings.** **A (recommended): keep** `fun(A) -> R`/`sub(A)`
(a function value), `*fun`/`*sub` (owned), `~fun` (weak), `?fun`
(callable view); Q1C only widens `A` and `R`. B: a new `Fn[…]` family,
a second spelling for nothing.

**Q6. A function name where a `*fun` is expected.** **A (recommended;
today): write `*|a| f(a)`**, so the `*` shows the allocation. B: accept
`*f`, reopening `owned_closure_from_function.rig`.

**Q7. Calling a closure held in what the call writes,
`self.hook(!self)`.** **A (recommended; today's callee hold, s3):
reject**, since the callee could replace `self.hook` and free the
running environment; the diagnostic gains the hint "clone the handle
first: `f = +self.hook`, then `f(!self)`" (Rust's `Rc::clone`, one
count). B: hold a count implicitly, which is hidden refcount traffic.

**Q8. A temporary callee, `(+self.hook)(!self)`.** A: keep rejecting;
bind first. **B (recommended): a value made to be called is a
temporary, dropped where its statement ends.** Core §3 already says so
of a call's result and `+x`, and the callee is read. This reverses
`test/reject/types/temporary_owned_closure_call.rig` and the last error
of `receiver_sigil_field_element.rig`.

**Q9. May an owned closure's result view its environment?** **A
(recommended; today, r1): no**; it views only what the call lent, or a
`Static`, as a function's does. B: yes, with a read loan on the handle
var: sound, but no stored ts-rust closure returns a borrow.

**Q10. Closures as `Map` values.** No closure-specific work: a `*fun`
is a handle and goes wherever a `T` goes (`generic_holds_owned_closure`).
It waits on NEEDS 2 (`Map`). Recommended: nothing here.

## 3. Syntax

No new syntax. Q1C widens what `A` and `R` may be in `*fun(A) -> R`
and `*sub(A)`; §6's examples show every form. Each effect stays marked:
captures by `<`, `+`, `~`; the argument's write by `!c` at each call;
the count by `f = +self.mappers[m].f`.

## 4. Semantics and desugaring

**An owned closure is a method on its own environment.** Given
`*|<a, +b, p, q|` checked against `*fun(P, !Q) -> R`:

```rig fragment
obj Env                          # fields: what sentence 9 allows (no view)
  a: A
  b: B

  fun invoke(?self, p: P, q: !Q) -> R from p, q   # the parameters whose
    body                                          # types could hold R's views
                                                  # (`from static` if none);
                                                  # never `self`
h = *Env(a: <a, b: +b)           # `*S(...)`: a new counted handle
```

- The body reads `a` as `self.a`: through `?self`, so captures are fixed
  (SPEC §11) and a re-entrant call is one more read view.
- `h(x, !y)` is `h.invoke(x, !y)`: the receiver lends `h` to read for
  the call (a `*T` lends only read views, Core §4), so sentence 5 makes
  `x.hook(!x)` a conflict (Q7). The existing callee hold is exactly this
  read.
- Parameters follow sentence 4 and the result sentence 7, by the
  function rule: a view parameter lasts the call; an owning one is taken
  (`sum(<v)`) and dropped, returned, or stored through a write
  parameter; `from` never names `self`, so the result never views the
  environment (Q9), and storing a view of `self.a` into `q` stores a
  local's loan into a parameter, rejected as for any function (t1).
- `*fun(P, !Q) -> R` is `*Env` for some `Env` with that `invoke` and no
  view; the checker needs only that it carries no loan, needs cleanup,
  and never copies. Emit erases it (`rig.Closure`). A function type's
  parameters and result are not parts of its value, so
  `List[*sub(!Checker)]` holds no write view (Core §5).
- A stack closure lent to a call is unchanged: `|!x|` is `w = !x` then
  `|<w|` (INTERNALS); a literal's last use is the call.
- A temporary callee (Q8B): `(+h.f)(a)` is `t = +h.f`, a temporary of
  the statement, then `t(a)`; `t` drops at the statement's end on every
  exit (Core §3).

## 5. CORE text

**§7, replace the "Closures" paragraph with:**

> **Closures.** A closure captures each name with a sigil: `?x` lends
> `x` to read for the closure's life, `!x` lends it to write, `<x` moves
> it in, and `+x` captures what `+x` gives, read through a view: a copy
> of a value that copies, a new count of a handle, or a deep copy of an
> owner. Captures are fixed: the body reads them, and writes only
> through a captured write view. A closure's life ends at its last use,
> so a closure literal lent to a call lends its captures for that call.
> A stack closure may be lent (`?fun`) but not stored. *(built)*
>
> **An owned closure is a function with its own environment.** `*|...|`
> moves or clones its captures into a value behind a counted handle,
> `*fun(A) -> R` or `*sub(A)`, which is stored, returned, cloned, and
> dropped like any `*T`. The environment holds no loan (sentence 9), so
> an owned closure captures owners, handles, and plain data, never a
> view. Its parameters and result are any a function's may be, and
> follow sentences 4 and 7 as a function's do: a view it is given, read
> or write, lasts the call; what it is given to own, it drops, returns,
> or stores through a write parameter; its result views only what the
> call lent it. So a write view reaches a stored closure only as an
> argument, for one call: mutation is never data. Calling a closure
> reads what holds it until the call returns (§6), so a closure held in
> `x` is not called with `!x`: clone its handle first, `f = +x.f`, then
> `f(!x)`. *(built* for plain-data parameters and results; *planned*
> for the rest.*)*

**§5, after "Write views are not stored." add:** "A function type's
parameters and result are not parts of a value of that type:
`List[*sub(!Checker)]` holds no write view. *(built* for `fun`;
*planned* for `*fun`.*)*"

**§3, "Reading" list, add** "the value a call calls". **"What counts
as a temporary", add:** "A value made to be called (`(+h.f)(x)`) is a
temporary too. *(planned)*"

Sentence 9 is unchanged; §10's checklist is met (one paragraph, no
exception list, a desugaring into §1–§6 forms).

## 6. The failing tests

### `rig pending` doc examples (land in CORE §7 / SPEC §11 now; all rejected today for the planned reason)

```rig pending
obj Checker
  n: Int

sub main()
  c = Checker(n: 1)
  step = 10
  bump: *fun(!Checker, Int) -> Int = *|+step, k, t|
    k.n += step
    k.n + t
  a = bump(!c, 1)
  b = bump(!c, 2)
  print(a, b, c.n)
```

```output
12 23 21
```

```rig pending
obj Mapper
  f: *fun(!Checker, Int) -> Int

obj Checker
  calls: Int
  mappers: List[Mapper]

  fun map(!self, m: Int, t: Int) -> Int
    f = +self.mappers[m].f
    f(!self, t)

sub main()
  c = Checker(calls: 0, mappers: List())
  double: *fun(!Checker, Int) -> Int = *|k, t|
    k.calls += 1
    t * 2
  !c.mappers.push(Mapper(f: <double))
  r = (!c).map(0, 21)
  print(r, c.calls)
```

```output
42 1
```

```rig pending
obj Checker
  lookups: Int

  fun global_type(!self, name: ?String) -> Int
    self.lookups += 1
    name.len

fun resolver(name: ?String) -> *fun(!Checker) -> Int
  owned = String(name)
  cache: *Cell[Int?] = *Cell(none)
  *|<owned, <cache, c|
    if cache.get() as v
      return v
    n = (!c).global_type(?owned)
    !cache.set(n)
    n

sub main()
  c = Checker(lookups: 0)
  array = resolver("Array")
  a = array(!c)
  b = array(!c)
  print(a, b, c.lookups)
```

```output
5 5 1
```

```rig pending
sub main()
  shout: *fun(?String) -> String = *|s| String(s, "!")
  sum: *fun(List[Int]) -> Int = *|v|
    t = 0
    for x in v
      t += x
    t
  v: List[Int] = List()
  !v.push(2)
  !v.push(3)
  print(shout("hi"), sum(<v))
```

```output
hi! 5
```

```rig pending
obj Checker
  n: Int
  hook: *sub(!Checker)

  sub run(!self)
    self.hook(!self)

sub main()
  bump: *sub(!Checker) = *|k| k.n += 1
  c = Checker(n: 0, hook: <bump)
  (!c).run()
```

```error
cannot lend `self` to write while the callee's read of it is in use
```

```rig pending
obj Hooks
  on: *fun(Int) -> Int

sub main()
  h = Hooks(on: *|x| x + 1)
  print((+h.on)(1))
```

```output
2
```

### Reject tests (files; they fail today with the plain-data message, so they land with Round 1)

`test/reject/ownership/owned_closure_stores_env_view.rig`:

```rig fragment
# An owned closure's captures are its own locals: a view of one stored
# through a write parameter would outlive the call.

obj H
  s: ?String

sub main()
  t = String("x")
  set: *sub(!H) = *|<t, k| k.s = ?t
  h = H(s: "a")
  set(!h)
  print(h.s)

# error: 9:28: cannot store a view of `t` in `k.s`: `k` outlives it
```

`test/reject/ownership/owned_closure_call_stores_arg.rig`:

```rig fragment
# A call of an owned closure stores what its type's origins say: here
# the `?String` argument into what `!H` reaches.

obj H
  s: ?String

sub main()
  put: *sub(!H, ?String) = *|h, s| h.s = s
  h = H(s: "a")
  t = String("x")
  put(!h, ?t)
  !t.add("y")
  print(h.s)

# error: 12:3: cannot lend `t` to write while a read loan is live
```

`test/reject/ownership/owned_closure_callee_write_self.rig`: the
`self.hook(!self)` program above, plus a `List` element
(`self.hooks[0](!self)`), a `?*fun` view bound from `?self.hook`, an
`if self.opt as f` binding, and a generic `H[T]` field callee, each with
`# error: … while the callee's read of it is in use` or "while a read
loan is live", and the Q7 hint text.

`owned_closure_result_views_env.rig` (passes today; the Q9 guard):
`*fun() -> ?String = *|<s| ?s`, "which this function was not lent".

### Behavior tests (Round 1)

- `test/behavior/runtime/owned_closure_owning_values.rig`: the programs
  of `test/reject/types/owned_closure_resource_values.rig`, which goes.
- `test/behavior/runtime/owned_closure_failure_drops.rig`: an obj
  `Gone` whose `drop` prints; `check: *fun(Gone) -> Int!` failing on
  `n == 1`, and `skip: *fun(Int, Gone) -> Int = *|a| a` omitting its
  owning parameter; `check(Gone(n: 1)) catch -1`, `check(Gone(n: 2))
  catch -1`, `skip(3, Gone(n: 4))` print `drop 1`, `-1`, `drop 2`, `2`,
  `drop 4`, `3`.
- `test/behavior/runtime/owned_closure_write_param_reentrant.rig`: a
  stored `*sub(!Checker, Int)` that calls, through its parameter, a
  second handle to itself (`f = +k.hook; f(!k, n - 1)`), recursing three
  levels: proves re-entry is read-only on the environment.
- `test/behavior/types/owned_closure_in_generic.rig`: `List[*sub(!C)]`
  and `H[*fun(?String) -> String]` (§5's new sentence).
- Round 2: `test/reject/types/temporary_owned_closure_call.rig` becomes
  `test/behavior/runtime/temporary_owned_closure_call.rig` (prints `2`),
  and `receiver_sigil_field_element.rig` loses its line-22 error into a
  behavior test of `P(…).handlers[0]()`.

## 7. Implementation plan

**Round 1, `owned-sigs` (M: ~150 lines of compiler change, ~400 of
tests and docs; 1–2 days).**
1. `resolve.checkOwnedClosureType` and the lambda checks in
   `typecheck.zig` (~11853, and the inferred result): replace the
   plain-data checks by the signature rule (`misplacedAt(.signature)`);
   delete `sema.isClosureValue`/`isClosureResult`.
2. Generic bodies: a `T` in an owned closure's *signature* records no
   `PlainRequirement`; a `T` stored in its *captures* keeps `.view`
   (`checkViews`).
3. Ownership: confirm a `*fun` call takes its type's `Origins`
   (`result` and `stores`) on every callee path, and that the callee
   hold covers each form in the reject grid. Add the Q7 hint at the
   callee-hold diagnostic.
4. Emit: `rig.Closure.invoke` moves owning arguments (no caller drop);
   a failing body drops them once; trailing omitted owning parameters
   drop after the body (#117); an owning result is a temporary.
5. Docs: CORE text above; SPEC §11 "Owned closures" from §4, its §18
   row deleted; INTERNALS gets the §4 desugaring; ROADMAP's line goes;
   the pending blocks flip to `rig`.
6. Gates: fast gate, plus the **full matrix** (it widens what reaches
   the origins and callee-hold logic) with a new grid row: callee
   {local, field, element, `?*fun` view, `as` binding, generic `T`,
   temporary} × argument {`!holder`, `?holder`, owned, `?String`} ×
   result {plain, owned, `?String` view}. The oracle learns owned-closure
   calls (it already handles function-value origins); classify any
   difference.

**Round 2, `temp-callee` (S: ~60 lines; half a day).** In
`readLeafAs`/`rejectResourceTemporary`, a made callee (or callee base)
that needs cleanup records a temporary drop (`recordTempDrop`) instead
of being rejected; `src/storage.zig` names its hidden storage; emit
drops it at the statement's end on every exit. Touches the
`handsOver`/storage facts, so it waits for Round 1 to merge
("one branch at a time per fact"), then runs the full matrix.

**Not scheduled:** Q3B/Q4B (`^fun`, `!f(x)`, `<f(x)`). Entry criterion:
a Trig file where the `*Cell` or `!`-argument workaround costs more
lines than ts-rust's version.

## 8. Soundness risks and the facts they touch

| Risk | Fact / classifier | Guard |
|---|---|---|
| a `*fun` call on some callee path not taking its type's origins, so a stored view or a result loan is lost | `sema.Origins` (`defaultOrigins`, `storeTargets`), call-of-function-value in `ownership.zig` | `owned_closure_call_stores_arg`, grid rows |
| a callee form not held while a later argument lends its holder to write: the closure frees its own environment mid-call | the callee hold (`holdRead`, "the value a call calls") | `owned_closure_callee_write_self` grid; sanitizer |
| a view of a capture (or of what a captured `*T` holds) stored through a write parameter | parameter flow / local-root rule (`storeThroughCapture`, param live at exit) | `owned_closure_stores_env_view`, plus a `*User`-capture row |
| a write view counted as "held" because it appears in a function type | `holdsWriteView`/`mayHoldView` must not enter function parameters (true for `fun`, s1) | `owned_closure_in_generic` |
| generic instances: a `T` in a signature wrongly required plain, or a `T` in captures no longer required loan-free | `PlainRequirement`, `checkViews`, `checkInstantiations` | generic grid row |
| an owned argument dropped twice (caller and callee) or never, on success, failure, or omission | emit's call lowering for `rig.Closure`; `needsCleanup` unchanged | `owned_closure_failure_drops`, sanitizer |
| re-entry writing the environment | binding access of captures (`decideBindingAccess`: owned-closure captures are read) | `owned_closure_write_param_reentrant` |
| Round 2: a temporary callee not dropped on an early exit | `handsOver` (`made`), `recordTempDrop`, storage facts, the exit primitive | Round 2 tests with `!` and `?` exits |

No new classifier is added. Round 1 changes no expression
classification; it widens which types reach the existing ones.

## 9. Decisions for the owner

1. Owned closures may take and return anything a function signature may
   hold (Q1C), and the SPEC §18 row goes.
2. A write view reaches a stored closure only as an argument; owned
   closures never capture a view (Q2A).
3. An owned closure's result views only what the call lent it, never its
   environment (Q9A).
4. No mutable environment for now: state lives in a captured `*Cell` or
   arrives as a `!` argument (Q3A); `^fun` waits for evidence.
5. No call-once closures for now: call, then `<f` (Q4A).
6. Keep today's spellings: `fun`, `sub`, `*fun`, `*sub`, `~fun`, `?fun` (Q5A).
7. A function name does not become a `*fun`; write `*|a| f(a)` (Q6A).
8. `x.hook(!x)` stays rejected, with a hint to clone the handle (Q7A).
9. A temporary callee is a temporary, dropped at its statement's end,
   reversing `temporary_owned_closure_call.rig` (Q8B), in Round 2.
10. Closures as `Map` values need no work here; they follow NEEDS 2 (Q10).
11. The CORE wording in §5 of this proposal, and the round plan: Round 1
    (M, full matrix), then Round 2 (S), each one branch at a time.
