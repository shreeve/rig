# Review: REVAMP-3 step 10 storage facts (`r3-step10-facts` at `144dd575`)

Reviewer: independent adversarial review of B1 (`86ce083f`) and B3
(`144dd575`) on top of B2. I used the worktree's `bin/rig` and
`bin/rig-oracle` (built after the last source change; no rebuild was
needed), and compared each probe with `rig-10f-base` (after B2, before
B1/B3) and `rig-v014` (the release). Every probe ran single, with
`RIG_SANITIZE=1 bin/rig run`; some also without the sanitizer and with
`--release=fast`. I changed nothing in the worktree and ran no suites.

Probes: `probes/review-step10/` (45 programs, each with a header
comment). `probes/review-step10/run.sh probe.rig` reruns one on HEAD, the
base, v0.1.4 and the oracle.

## Verdict

B1's facts and chokepoint work as built, and B1 changed no emitted
program (the emitted Zig of all 63 probes here and in `step10f/`,
`step10/` matches the base, except where B3 changes whether a program is
accepted). B3's hidden var for call-held storage is sound for every
holder shape I tried: loop-carried holders, holders reached through a
write view, and stores through `!h`.

The bug class is **not closed**. There are four real findings:

- **C1 is new in B3.** B3's "the statement discards the result" test
  is made on syntax. It also strips the result's loans. Together these
  let a function, or a value block, return a view of storage the call
  has already ended.
- **C2 is an accepted copy that the B3 argument says needs no var.** A
  plain-data catch-all binding views a header copy. It gives wrong
  results without the sanitizer, and it reads a dead frame.
- **H1 and H2 are accepted programs whose Zig does not compile.** In
  both, the storage that emit makes does not have the type or meaning
  that its fact records.

| # | Sev | New? | Kind / stage | Finding |
|---|---|---|---|---|
| C1 | **Critical** | **new in B3** (the base rejects it); the function-tail form is live in v0.1.4 | `receiver` (`life` call), B3 | A call that ends a function body or a value block is taken to "discard" its result. Its loans on the call-held var are dropped unchecked, so the view leaves the call. |
| C2 | **Critical** | pre-existing in revamp since step 3 (`rig-3s-base`); v0.1.4 rejects it | `subject` copy, `header_value`/`header_copy`; B1 gap (`emitCapture`); contradicts B2 | The catch-all `x` of a read `match ?place` whose header makes a temporary is typed `?E`, a view, for plain data. So it is neither a copy nor arm-local. Emit matches a copy (`__rig_subject_N`, or the header block's rvalue). |
| H1 | High | pre-existing in revamp (an implicit lend is new in revamp) | `argument` (fact `owned`), B1 | A Text temporary implicitly lent as a `String` argument of a hoisted call is declared `var __rig_arg: rig.Text = keep(...).bytes()`, with a drop and a take. The Zig does not compile. |
| H2 | High | pre-existing in revamp (arrays and Vec indexes of owners are new) | `subject` copy, B1 | In a guarded `match ?bs[idx(?Text(..))]` over `Box[E]` or `*E` elements, `__rig_subject_N` has the Box or handle type but is assigned the `E` it reaches. The Zig does not compile. |
| M1 | Medium (latent) | pre-existing; implementer's q05 | not a fact; B2's claim | Emit still takes the address of Zig rvalues. A view of one is read after the block that made it (a32), and a `?self` receiver is copied via `@as(Q, if …)` (a28). With today's Zig nothing is observable, because Zig emits no lifetime markers. |
| L1 | Low | pre-existing (the oracle is unchanged) | oracle | The oracle rejects (C5) a correct program the compiler accepts: a temporary inside a branch of a value `if` in `print(...)`. An oracle set with that program would fail with a false DIFF. |

---

## C1 (Critical, new in B3): a tail call's view of call-held storage escapes

`endCallHeld` (`src/ownership.zig`, B3) checks whether the call is its
own statement:

```zig
var stmt = storage.unborrowed(self.cur_stmt);
while (stmt.isKind(.propagate)) stmt = storage.unborrowed(ir.Propagate.value(stmt));
const discarded = stmt == .list and node == .list and stmt.list.id == node.list.id;
if (!discarded) for (out.loans) |l| if (l.root == id) { reportCallHeld(...) };
...
for (out.loans) |l| if (l.root != id) try kept.append(...);   // strips the loans on id
```

A statement that is the call is not always discarded. The last
statement of a function body, or of a value `if`/`match` block, yields
its value. In that case:

- the report is skipped;
- the result's loans on the hidden var are stripped;
- the hidden var already took over the receiver's own loans, including
  its loan on the statement temporary `mk(42)`.

So the result carries no loan at all. Even the base's rejection ("does
not originate from a borrowed parameter", "a borrow of the temporary …
outlives its statement") is lost.

**`a36_callheld_fn_tail.rig`**:

```rig
fun view(d: !Int) -> !Int from d
  !mk(42).at()          # S.at(!self) -> !Int; mk() a plain S
```

Emit:

```zig
pub fn view(d: *i64) *i64 {
    return __rig_call_1: { var __rig_recv_1: S = mk(42); break :__rig_call_1 (__rig_recv_1).at(); };
}
```

| Build | Output |
|---|---|
| HEAD, sanitizer | `-6148914691236517206` |
| HEAD, `--release=fast` | `0` (expected 42 if it were valid) |
| base | rejected, 16:4 "returned borrow of `mk(42)` does not originate from a borrowed parameter" |
| v0.1.4 (`a36b_v014_form.rig`, no `from`) | accepted; `--release=fast` prints `0` |
| oracle | `unknown` (a write lend of a made value) |

**`a35_callheld_tail_value.rig`** shows the same thing through a value
`match` arm block and a value `if` block, with a Cell-holding part of a
temporary held as a copy (`__rig_recv_4`):

```rig
  s = if k == 0
    print("block")
    mkh(43).q.me(k: g(1), j: g(2))
  else
    ?d
```

| Build | Output |
|---|---|
| HEAD, sanitizer | prints `-6148914691236517206 -6148914691236517206` (both `r.n` and `s.n`) |
| base | rejected (temporary outlives its statement) |
| v0.1.4 | accepted, prints 42 43 (latent there) |
| oracle | `DIFF … prod=accept ref=reject C5` |

The oracle catches this one, but not a36.

**Root cause.** Whether a call's value is used is decided again from
syntax (`cur_stmt` identity). That breaks "one classifier per fact".
Whether the value is taken, read, or dropped is already a recorded fact:
`useOf` / `handsOver` / the tail facts emit's `takesTail` reads.

There is a second part. On the discarded path the loans are removed,
instead of being handed back to what the hidden var was holding.

**Fix shape:**

- Decide "discarded" from the value-use fact, not from `cur_stmt`.
- Never strip loans without reporting them.
- In a discarded statement there is no result to hold them anyway, so
  stripping is only needed where nothing reads the value.

**Siblings checked:**

- A single-expression `=>` arm is not a statement: rejected (a35's first
  form).
- A closure body tail (a41) is rejected for another reason.
- The holder paths (a25 loop-carried, a42 through `!w`, q11) are all
  rejected correctly.

---

## C2 (Critical): a plain-data catch-all binding views the header copy

INTERNALS ("Header subjects") makes three statements:

- "A payload or element is bound by one rule, from its type: a copy of
  plain data …, including the binding of a catch-all arm."
- For a header whose subject makes a temporary, "a copy of plain data
  that is only read is the subject's value."
- B3's argument: "a read match's payload view, which may view a
  `subject` copy, lives for its arm (`arm_view`)".

The implementation does something else:

- `checkPattern` binds a catch-all to the **scrutinee type**. For an
  explicit lend `match ?v[...]` that is `?E`, a pointer when `E` is
  read by address.
- `arm_view` is set only when `copyable != .yes`, so a plain `E`
  catch-all is a view that is not arm-local.
- The checker roots the view at `v`, because the Core says it is a view
  of the place.
- `rejectHeaderCopy` exempts the header because `unwrapBorrows(?E)` is
  plain data.

Emit matches a copy:

- guarded: `var __rig_subject_2: E = (__rig_hdr_3: {...; break :__rig_hdr_3 v[...]; })`, then `const x = &__rig_subject_2;`;
- unguarded: `switch ((__rig_hdr_1: {...})) { else => |*x| ... }`, which captures the address of a Zig rvalue.

**`a05_match_place_hdrtemp_plain_view.rig`** (guarded):

```rig
  match ?v[idx(?Text("a"))]
    x if k > 2 => r = x
    _ => print(0)
  print(clobber(1))
  match r ...   # prints r's payload
```

- HEAD and base: `-6148914691236517206 -6148914691236517206` (expected 7 7).
- v0.1.4: rejected, "a view of `x` does not outlive the `match`".
- Oracle: accept, as the Core says.

**`a08_guarded_match_loop_wrong.rig`** is the same pattern in a loop,
and needs no sanitizer. `__rig_subject_N` is refilled each iteration, so
the view taken in iteration 0 reads iteration 1's copy.

- HEAD prints `8 8` in Debug and `--release=fast` (expected `7 7`); the
  sanitizer gives 0xAA.
- `rig-3s-base` through HEAD all print `8 8`.
- Earlier builds (a0, rig-base, s1-13, 3607) fail in Zig.
- v0.1.4 rejects it.

**`a27_match_hdrtemp_return_view.rig`** (unguarded, `x => x` as the
match's value in `at2(v: ?Vec[E], i) -> ?E from v`): the function
returns the address of the switch operand's rvalue in its own frame. In
Debug without the sanitizer, HEAD prints `-69242844270821376 9`
(expected `8 8`). v0.1.4 rejects the same program (`a27b_v014_form.rig`).

a06 and a07 (unguarded, within one function) are latent: they print the
right values.

**Not affected:**

- an `as` or `for` binding of plain data, which is a real copy (a03,
  a09, a22);
- temporary subjects (a04, a10, a21: rejected as temporaries);
- non-plain payloads (`arm_view`, a34).

**Root cause and class.** This is the step-10 class exactly: emit copies
a place and the checker walks the place.

- The `subject`/`header_value` copy is assumed safe because "plain data
  is copied out". The catch-all on an explicit lend is not copied out.
- It is also a hole in B1's chokepoint. The pointer capture `|*x|` is
  made by `emitCapture`, which names it after the Rig binding. So no
  fact covers it, and the `classify` lint (name-based) cannot see it.
- It contradicts B2's "emit takes no address of a Zig temporary"
  (a06/a27).

---

## H1 (High): an implicit lend of a Text argument in a hoisted call does not compile

**`a13_hoisted_arg_text_view.rig`**: `print(pick(n: g(1), s: Text("…")))`
with `pick(s: String, n: Int) -> String`. The keyword arguments are out
of order, so the call is hoisted. The emitted Zig:

```zig
var __rig_arg_2_0: rig.Text = rig.keep(&__rig_tmp_1, &__rig_tmp_1_live, rig.Text.of(.{ "…" })).*.bytes();
var __rig_live_2_0 = true;
defer if (__rig_live_2_0) rig.drop(&__rig_arg_2_0);
... pick(__rig_arg_2_1, rig.take(&__rig_live_2_0, __rig_arg_2_0))
```

Zig reports: `expected type 'rig.runtime.Text', found '[]const u8'`.

- HEAD and base fail the same way.
- v0.1.4 rejects the program in sema; it had no implicit lend.
- The explicit `?Text(...)` (a15) works, and so does a `?Text` parameter
  (a14).

Root cause: `storage.argumentHold` returns `.value`, and so `owned`,
for any argument that is not a callable or a `?part` of a Cell temp. The
plan records `argument … owned call`. `hoist` then takes `typeOf(node)`
(Text) and `kindOf` (a resource), and arms a drop and a take. But the
argument is lent (`lendOf` is implicit): its value is a view of the
statement slot.

The fact is wrong, and the B1 check cannot see it. Emit asks the same
`argumentHold(...).by()` that the plan used, so the "held the same way"
check is tautological here. Had the view and owner Zig types matched,
this would have been a double drop. I found no type pair that matches.
Text → String, `Vec` / arrays → `[]T`, and `T?` → `View?` all differ.

---

## H2 (High): a guarded match on a Box or handle element through a header temporary does not compile

**`a38_match_box_hdrtemp_noescape.rig`** (no escape at all):

```rig
  bs = [Box(E.a(xs: [7, 7, 7, 7])), Box(E.b)]
  match ?bs[idx(?Text("a"))]
    .a(xs) if k > 2 => print(xs[0])
    _ => print(0)
```

Emit: `var __rig_subject_2: rig.Box(E) = (__rig_hdr_3: {...; break :__rig_hdr_3 bs[...].value.*; });`.
Zig reports: `expected type 'rig.runtime.Box(__rig_main.E)', found '__rig_main.E'`.

- **a39** is the same with `*E` handles: `cannot dereference
  non-pointer type '__rig_main.E'`.
- a37 is a38 with the catch-all escape added. The oracle reports a DIFF
  there.
- Unguarded forms compile and run (a40).
- HEAD and base fail the same way. v0.1.4 could not write the program.

Root cause: `subjectHold` returns `.copy`, but `evalSubject` types the
storage as the subject (the Box) and fills it with the value the lend
reaches. The `subject` fact does not record which of the two it holds.

---

## M1 (Medium, latent): addresses of Zig rvalues remain

B2 claims "emit takes no address of a Zig temporary". That is not yet
true. Besides C2's `|*x|` over a header block:

- **a32** (`print(pick(n: g(1), q: mkq(5).me()).xs[3])`):
  `const __rig_arg_1_1 = (mkq(5)).me();` is inside `__rig_call_1`, and
  `.xs[3]` reads the view after the block ends.
- **a28**: `(@as(Q, (if (c) mkq(5) else b)).me()).xs[3]`. A branching
  receiver with a made leaf is not `reachesLeaf`, so it is copied, and
  `?self` takes the address of the copy.
- **q05**: `((mkq()).me()).n`.

The checker confines each such view to its statement, and Zig keeps the
rvalue's stack slot today. a33 tried to force slot reuse with two call
blocks in one statement; it prints the right values in Debug,
`--release=safe` and `--release=fast`. So these are latent by Zig's rules,
not observed failures.

A lent plain made value is kept in a slot (a16, a18), so this is limited
to `?self` receivers and branch copies.

---

## L1 (Low): an oracle false positive

**`a20_branch_temp_view.rig`**:
`print(pick(?Text("…")) if c else "d")`. The compiler accepts it, keeps
the Text in the statement's slot, and the run is sanitizer-clean. The
oracle reports `DIFF … main prod=accept ref=reject C5 10:9 a loan of a
temporary outlives its statement`. It treats the branch as a statement,
but CORE §3 says only headers are their own statements. An oracle set
that contained this program would fail.

---

## Kinds and the "needs no var" argument, as tested

| Kind | By / life | Argument | Result |
|---|---|---|---|
| `receiver` copy / owned | call | walked by B3 | sound for holders (a25, a42, q02, q11); **C1** in tails |
| `argument` copy | call | walked by B3 | sound |
| `argument` owned | call | "the callee's own value" | false for an implicit lend (**H1**). Temporary arrays are safe: `callRetains` rejects retention, and a generic `T` holding a view is rejected (a19) |
| `subject` copy | construct | arm_view | **C2**, **H2** |
| `header_value` / `header_copy` | header | `rejectHeaderCopy` | **C2** (plain catch-all exemption) |
| `as_value` / `as_copy` | body | `rejectHeaderCopy`, the Cell `as` rejection | sound (a02, a03, a22) |
| `payload` copy | arm | copies fields out | sound |
| `held`, `taken` | construct | the construct's own hidden var | sound (a12, a21, a26) |
| `leaf`, `lent` | expression | pointers | sound for places and slots (a01, a18); rvalue leaves are M1 |
| `temp` | statement | `dropsTemp` | sound (a20, a24, a29) |
| `slot`, `index`, `new_value` | assignment | order | sound (a17: `v[0] %= grow(!v)`) |
| `error_value` | handler | plain data | sound |
| `environment`, `invoked` | call | the closure-literal rule | sound (q06–q08) |

Also confirmed fixed in revamp, and live in v0.1.4:

- **a43**: a value-block tail call on a Text-owning part of a temporary
  is a **use of freed memory** in v0.1.4. The base and HEAD reject it.
- **a30**: a Cell change through `(h1 if c else h2).q.bump()` is
  **lost** in v0.1.4 (prints `2 2 / 1 10`). HEAD prints `2 3 / 3 10`.
- **a01**: v0.1.4 accepted a view of `(mko(5) ?? b).me()` escaping its
  statement. HEAD rejects it.

## B1 chokepoint

- Every `__rig_` storage name in `src/emit.zig` goes through
  `hiddenStorage`, apart from the documented bookkeeping: flags, labels,
  `__rig_i_` index counters, `__rig_arg_{d}` renamed parameters, `__rig_arm`
  and `__rig_select`.
- The chokepoint checks that a fact exists and that its `by` agrees.
  For receivers and arguments, emit computes `by` with the same
  `storage.zig` function the plan uses, so the agreement check cannot
  fail (H1).
- `life` is never compared with the scope emit gives the storage.
- **Storage outside the chokepoint that a view can point into:**
  - Rig-named switch captures `|*x|` (`emitCapture`) over a non-lvalue
    operand: C2.
  - Address-of rvalues: `@as(T, if …)` copies of branching values that
    are not `reachesLeaf` (a28), `?self` on a made value (q05, a32), and
    `emitLeafPtr`'s "any other value made here is a Zig temporary".
  - Labelled value blocks `__rig_blk_N` / `__rig_if_N`. Their yields
    are rvalues, so the same applies.
- The `classify` lint is name-based, so it cannot see any of these.

## Oracle independence

- `test/oracle/` and `src/lib.zig` are unchanged since `b3615559`.
- The oracle reads no storage fact, no `storage.zig` predicate, and
  neither `lendsTempArray` nor `heldBaseOf`. It uses only symbols, types,
  call slots and the other fact accessors the lint allows.
- `test/run`'s lint now forbids `storage.zig`, `storageOf`,
  `recordStorage`, and `Storage*`.
- As the design predicted, the oracle cannot see C2, H1, H2 or M1: it
  accepts them as the Core says. It does see C1's a35 (DIFF) but
  abstains on a36.

## Is the class closed?

No. C1 is a new instance created by B3's own rule. C2 is an accepted
copy that the B3 argument ("needs no var") was supposed to cover. The
next structural steps:

1. **B3:**
   - decide "the result is used" from the recorded use of the call's
     value (the same fact emit's tail moves read), not from `cur_stmt`;
   - never drop a loan without reporting it (AGENTS: "Leaving a scope
     never silently forgets a borrow").
2. **B4 (point, not copy), now required, not optional:**
   - a header block over a place or lend subject should yield the
     place's address (`break :hdr &v[i]`), so `subject` and
     `header_value` hold a pointer;
   - catch-alls should bind by the one stated rule (a copy of plain
     data);
   - with that, `rejectHeaderCopy`'s plain-data exemption and C2 both
     go away, and H2's typing goes with them.
3. **Make the chokepoint structural, not name-based.** Every Zig
   location a view may point into should come from `hiddenStorage` with
   its fact, including captures and rvalue materialisations. Emit should
   fail on `&`/`|*x|` of any operand that is not a place, a slot, or a
   fact-named var. Facts should record lends (`argument` held as a view
   of a slot) rather than deriving `by` from the same predicate emit
   uses.
