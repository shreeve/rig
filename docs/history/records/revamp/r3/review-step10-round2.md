# Review round 2: step 10 storage facts (`r3-step10-facts` at `9594b403`)

Reviewer: the round-1 reviewer (`review-step10.md`). `bin/rig` and
`bin/rig-oracle` were current at `9594b403`: `zig build` and
`zig build oracle` were no-ops, and no source is newer than either binary.
I compared each probe with `rig-10f-base` and `rig-v014`, ran single
programs with `RIG_SANITIZE=1`, and changed nothing in the worktree.

Probes: `probes/review-step10/r2/` (45 programs, each with a header
comment). `r2/run.sh probe.rig` runs one on HEAD, the base, v0.1.4 and
the oracle.

## Verdict

Every round-1 finding is fixed at HEAD:

| Round 1 | Probes | HEAD |
|---|---|---|
| C1 | a35, a36 | rejected: "a view of … outlives the call" |
| C2 | a05, a08, a27 | rejected: "this header binds a copy" |
| H1 | a13 | runs |
| H2 | a38, a39 | rejected |
| L1 | a20 | no oracle DIFF |

**B3 (the call-held rule) holds.**

- I tried every tail position: a closure block, `for … else`,
  `while … else`, `raw`, a function's tail `if`/`match` statement, a
  nested `if`, an `if … as` block, a generic body, and a method body.
  All are rejected (b01–b10).
- I tried every value use: the operand of `??`, `catch`, or `!`; an
  argument to a generic and to a plain call; a receiver of a chained
  call. All six are rejected (b11).
- `discardsValue` is set only by `checkExprStmt`. It passes only through
  `!`, `?`, `catch`'s value, and borrow sigils, and every one of those
  hands its value only to the discarded statement. I found no statement
  marked discarded whose value is used.
- **No finding below is in B3's call-held rule, so B3 does not stop.**

The header rule's exceptions do not all hold. The "match on a call's
returned view held as a pointer" exception gives a **use of freed
memory**. It is pre-existing, and also live in v0.1.4. There are two more
pre-existing findings in argument holding.

| # | Sev | New? | Where | Finding |
|---|---|---|---|---|
| R2-C1 | **Critical** | pre-existing (base); **live in v0.1.4** | header rule exception (c), `match` only; not B3 | A `match` on a view a call returns that points into the header's own temporary reads its subject after the header block has dropped it: the tag, plain payload copies, String payload copies |
| R2-H1 | High | pre-existing; live in v0.1.4 | `argument` facts (B1 / H1 fix), `storage.argumentParam` and emit's `callParams`; not B3 | A callable held in a field, `s.cb(...)`, in a hoisted call has its parameters shifted by one, as if `s` were a receiver. An owned argument is planned and held as a pointer, with no drop flag, so an early exit leaks it |
| R2-H2 | High | pre-existing (base and HEAD identical) | emit of implicit lends in generic bodies; not B3, not step 10 | A `T` local implicitly lent to a `?T` parameter in a generic body is emitted `&x`, where `rig.lend(&x)` is needed. For `T = Int` the Zig does not compile, hoisted or not |
| R2-L1 | Low | pre-existing | oracle | The oracle rejects (C5) a correct `if pick(?mkh(7)) as x` that copies plain data inside the header (c10): a false DIFF |

---

## R2-C1 (Critical): a match on a returned view into the header's own temporary

The new header rule (`c827e440`) exempts "a match on a call's returned
view held as a pointer" (`held_view`). That is sound when the view points
at a place. When the view points into a temporary the same header makes,
emit evaluates the view in the header block. That block drops and
poisons the temporary. The `switch` then dereferences the view after the
block.

**`r2/c04_match_view_dispatch_string.rig`:**

```rig
fun mkh(s: String) -> H from s       # H(e: E.a(s: s))
fun pick(h: ?H) -> ?E from h
...
  match pick(?mkh(?Text("a text long enough to live on the heap")))
    .a(s) => print(s)
```

The emitted Zig:

```zig
switch ((__rig_hdr_1: { var __rig_tmp_2: rig.Text …; defer … rig.drop(&__rig_tmp_2);
                        var __rig_tmp_3: H …; defer … rig.drop(&__rig_tmp_3);
                        break :__rig_hdr_1 pick(&rig.keep(&__rig_tmp_3, …, mkh(…bytes())).*); }).*) {
    .a => |__rig_payload_4| { const s = __rig_payload_4.s; rig.print(.{ s }); },
```

| Build | Output |
|---|---|
| HEAD, sanitizer | panic: syscall error INVAL (writing a poisoned slice) |
| HEAD, Debug, no sanitizer | prints 8 NUL bytes, then 0xAA bytes (freed heap) |
| HEAD, `--release=fast` | `\0\0\0\0\0\0\0\0ong enough to live on the heap` |
| base | the same |
| v0.1.4 (`c04b_v014_form.rig`) | prints freed memory too |
| oracle | `DIFF main prod=accept ref=reject C5` |

**Siblings:**

- `c03_match_view_dispatch_dead.rig`: an `.a(n)` plain payload of a
  dropped `H`. The sanitizer prints `a -6148914691236517206`; v0.1.4
  prints `a 7` (latent there). The oracle reports a DIFF.
- `c01` is the guarded form: `__rig_subject_2.*` is read in the arms, and
  the sanitizer gives 0xAA. The oracle reports a DIFF.
- `if … as` and `while … as` copy the value inside the header block, so
  they are correct (c10).
- A view binding is reported, because it carries the loan (c02, c07).
- `for` over a slice into the temporary is rejected (c05).

**Root cause.**

- In `walkMatch`, the header's temporaries are dropped
  (`dropStmtTemps(drops)`) before the arms bind and run.
- Two reads of the subject are not modelled as uses of the subject after
  the header: the dispatch on the tag, and a plain-data payload copy.
  A plain copy "carries no loan once copied out", and by then the
  temporary's own flows, including its loan on the `Text`, have been
  cleared.
- The emitted program reads the subject after the header, so the checker
  does not check what is emitted.

**Fix shape.** Do one of these:

- reject a `held_view` subject whose value has loans on the header's
  temporaries; or
- emit the dereference (`.*`) inside the header block, as `as` does, for
  a read match whose bindings are all plain copies.

This is in the header rule's exceptions. It is not in B3's call-held rule.

## R2-H1 (High): the field callable's parameters are misaligned in a hoisted call

`storage.argumentParam` treats any `member` callee that is not a type
callee as a method, and drops `params[0]`. Emit's `callParams` does the
same. But `s.cb(...)` calls a callable held in field `cb`: it has no
receiver.

- **`h17_field_callable_owned_arg.rig`:** `cb: fun(Text, ?Q, Int) -> Int`.
  The call is hoisted because one argument lends a Cell-holding part of
  a temporary. The fact for the `Text("…")` argument is `pointer` (it was
  planned against `?Q`), and emit holds it as `const __rig_arg_3_0 =
  rig.Text.of(…)`, with no live flag and no drop.
- **`h18_field_callable_leak.rig`:** the same call with a later argument
  `gf(2)!` that fails. The output is `-1`, then `error: rig: memory leak
  detected: 1 allocation (186 bytes)`. HEAD, the base and v0.1.4 all leak.
- **`h19_direct_call_control.rig`:** the same call made directly is clean.
- **h16:** `g(1)` is planned as `pointer` against the shifted `?Q`. It
  happens to compile.

The H1 fix's "`by` decided apart from what emit writes" does not catch
this, because the plan and emit share the misreading.

## R2-H2 (High): an implicit lend of a generic local does not compile

**`h14_lent_generic_local.rig`:** `fun pick[T](q: ?T, n: Int) -> ?T from
q`, called as `pick(x, 1)` and `pick(n: g(1), q: x)` with `x: T`, and
`T = Int`. Emit writes `pick(T, &x, 1)`. Zig reports `expected type
'i64', found pointer` for both forms.

- The explicit `?x` emits `rig.lend` and works (h15).
- HEAD and base emit identical code. The implicit lend did not exist in
  v0.1.4.

This is outside step 10: emit's `emitBorrowValue` path for an implicit
lend skips `genericReadBorrow`.

## R2-L1 (Low): an oracle false positive on an `as` copy

**`c10`:** `if pick(?mkh(7)) as x` / `while … as y`, where `pick` returns
`?Q?` into the header's temporary and `Q` is plain data. Emit
dereferences and copies inside the header block, so the program is
correct and sanitizer-clean (`7 7`, `8 8`). The oracle rejects it with
C5.

---

## Exceptions to the header rule, as attacked

| Exception | Probes | Result |
|---|---|---|
| a take `<p` through a temporary path | c11: `if`/`while <v[idx(?Text(..))] as` over `Text?`, `E?`, `Vec[Int]?` | correct; the place is left `none`; clean |
| a slice | c12 (write and read slices of places and elements, with temporary bounds); c06 (a slice of the temporary itself); c05 (a returned slice into a temporary) | correct; c05 and c06 are rejected |
| a match on a returned view | c01–c04 | **R2-C1** |
| a made value with plain bindings | c09 (String payload of a header Text: rejected); c13 (`for` over a made Vec or array); c14 (Box and handle made values: rejected) | correct |
| `while` re-evaluation | c10, c11 | correct |

H1 (lent hoisted arguments) is correct for these cases:

- `String?`, `[]Int` from a Vec temporary, `![]Int`, a Box and a handle
  temporary as `?Q`, a made struct, a Text place;
- a made `Q?` as `(?Q)?`;
- a generic `?T` at the call site;
- array and field-array slices, a Text field of a temporary, and a Box
  place as `!Q` (h01–h13).

The exceptions are R2-H1 (field callables) and R2-H2 (generic bodies).

## Is the class closed?

**For B3's call-held storage, yes, as far as I could probe.** The rule
now reads a recorded fact. Every value use and every tail I tried is
reported, and no loan is stripped silently except for a discarded
statement.

**For header storage, no.** R2-C1 is the same class in the one place the
new outright rule exempts: the checker ends the header's temporaries
before the match reads its subject, while emit reads the subject after
the header block. The structural fix is still B4: point, not copy, and
read inside the header. Until then, `held_view` should go through the
same rejection whenever the subject's loans reach the header's
temporaries.
