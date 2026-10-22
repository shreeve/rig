# Review round 2: REVAMP-3 steps 4 and 5 fixes (`r3-step45` at `a2e72ce8`)

Reviewer: the round-1 reviewer (`review-step45.md`). I used the
worktree's `bin/rig` and `bin/rig-oracle` (built at `a2e72ce8`) and
compared with `rig-45-base`. Every probe ran with
`RIG_SANITIZE=1 bin/rig run`. I ran no suites and changed nothing in
the worktree.

Probes:

- 63 new probes are in `probes/review-step45/r2/`, each with a header
  comment;
- their verdicts at HEAD are in `r2/HEAD-results.txt`, and `r2/run.sh`
  reruns one on the new binary, the base and the oracle;
- I reran every round-1 probe at HEAD.

## Verdict

Every round-1 instance named in the fix list is fixed:

- C1 and H1: r15, r19, r24, r25, r11 and r12 are now rejected at the
  temporary;
- H2: r02a and r02e print 30;
- H3: c11 is rejected per instance;
- M2: g05, g10 and s04 run;
- L1: the array diagnostic now names `[2]Text`.

M1 (n39, a re-pointed field keeps its old loan) and M3 (4.6 and 5.4)
are unchanged, and the fix list did not claim them.

The fixes for H3 and M2 hold up under adversarial probing. The stop rule
and the H2 fix do not cover their classes:

| # | Sev | New? | Feature, and whether it had a round-1 soundness finding | Finding |
|---|---|---|---|---|
| R2-C1 | **Critical** | memory corruption is new (Vec and arrays of owners); the wrong-result form is in the base | **Header subjects through a temporary**: yes, round-1 C1 and H1. This is a second round. | The stop rule misses **branching** subjects. `if (!v[idx(?Text("a"))] if c else !w) as t` binds a copy, even when the branch taken is the plain `!w`. Growing `t` frees the original's buffer: use of freed memory. |
| R2-H1 | **High** | the class is pre-existing (the base fails for plain data); the Cell reach is new | **Elements reached through a read view in emit**: yes, round-1 H2. This is a second round of the class, not a regression of the fix. | A **guarded `match` on an element of a `?Vec[E]` parameter** emits `&v.*.slot(0).*`, and the Zig does not compile. Plain payloads, Text payloads and Cell holders all fail. |
| R2-L1 | Low | no (base crashes too) | | `rig check` hits an assertion (`sema.recordUse`, `gop.value_ptr.* == use`) on d04, a closure capturing `?w` of a write view passed to a call with two `!b` arguments. A crash, not an acceptance. |
| R2-L2 | Low | | | Oracle gaps: it accepts `r = ?x` of a generic loop copy (e16, `stricter`), and it marks every re-point and held-write-view program `unknown`. So it gives no check on M2's change. |

**What stops under "a second soundness round stops the feature":**

- **Header subjects reached through a header temporary** (round-1 C1
  and H1, now R2-C1) should stop. Do not extend `rejectsTempPath` leaf
  by leaf. The copy comes from one emit path, the `if … as` and
  `while … as` arm in `emit.zig` near line 2468: when
  `borrowsOptionalValue(value) and hasTemps(value)`, it binds
  `var __rig_opt_N_v = __rig_opt_N; const t = &__rig_opt_N_v`. That path
  is sound only for a read binding of a type with no Cell, used within
  the body. Until step 10's lowering, either:
  - reject in sema every `if … as` and `while … as` that takes this
    path with a **write** binding, or with a read binding that is not
    plain data; or
  - make the temp-path rejection cover every subject shape (place,
    branches, lends of either) by walking `hands` leaves.

  Either way, the rule should be stated once, on the emit path that
  copies, not on the subject's syntax.
- **H2's class** (an element reached through a read view emitted with
  `.slot`) had one round-1 instance (Cell `set`). R2-H1 is a sibling the
  round-1 report asked to check. It is a Zig compile failure, not memory
  corruption, and the plain-data form predates step 4. I would fix it
  as a class in `emitIndex` and not count it as a stop. The design owner
  should decide.
- **H3** (the generic Vec loop's `no_cell` requirement) and **M2** (the
  early end of a re-pointed view's old loans): no findings. They stand.

---

## R2-C1 (Critical): a branching header subject with a temporary binds a copy

**Repro** (`r2/c10_branch_rhs_only_temp_write.rig`):

```rig
fun idx(s: String) -> Int
  s.len - 1

sub main
  v: Vec[Text?] = Vec()
  !v.push(Text("q"))
  w: Text? = Text("w")
  c = v.len == 1
  if (!w if c else !v[idx(?Text("a"))]) as t
    for _ in 0..40
      !t.add("xxxxxxxx")
  print(w)
```

Output: `error: rig: use of freed memory`, exit 134. The branch taken is
`!w`, a plain local. The temporary is in the branch not taken, but the
whole subject is evaluated in a header block, and the binding is a copy:

```zig
if ((__rig_hdr_1: { var __rig_tmp_2 …; break :__rig_hdr_1 (if (c) &w else __rig_blk_3: {
        break :__rig_blk_3 &v.slot(idx(rig.keep(&__rig_tmp_2, …).*.bytes())).*; }).*; })) |__rig_opt_4| {
    var __rig_opt_4_v = __rig_opt_4;
    const t = &__rig_opt_4_v;
```

**Siblings, all accepted:**

- `c01_branch_subject_temp_write.rig`: the temporary is in the taken
  leaf. Use of freed memory.
- `c08_branch_while_temp_write.rig`: `while (… if c else …) as t`. Use
  of freed memory.
- `c09_branch_field_temp_write.rig`: a field after the index,
  `!h.f[idx(…)].o`, inside a branch. Use of freed memory.
- `c11_branch_read_escape.rig`: a read binding of `Vec[Int]?`. `r = ?t`
  stores a pointer to the dead `__rig_opt_4_v` past the `if`. The
  checker accepts it, and emit gives `r = t` with `t = &__rig_opt_4_v`.
  It printed correctly in my runs, because the stack slot was not
  reused. It is a latent dangling pointer.

**Correctly handled:**

- `c07`: the Cell-holder read binding is rejected ("would bind a copy of
  the `C` … a change to its Cell would be lost").
- `c13`: with the temporary only in the branch *condition*, the subject
  is not in the header block, and the write lands.
- `c02`: a branching read `match` changes the Cell correctly.
- `c03`: a branching write `match` gives read payloads, so it is
  rejected.
- `c04` and `c05`: branching `for` sources are rejected.

**New or not.** The base rejects Vec and arrays of owners, so the memory
corruption is new reach. The class is in the base:
`c01b_branch_subject_temp_plain.rig` (`[1]Int?`, `n = 50`) prints `[1] 2`
on both binaries, where `[50] 2` is expected.

**Root cause.** `typecheck.rejectsTempPath` returns early when
`self.hands(p).kind != .place`, so it never looks inside branches. The
copy itself is emit's `borrowsOptionalValue(value) and hasTemps(value)`
path for `if … as` and `while … as`. That path copies for any subject
with a header temporary, whatever its shape. The oracle accepts every
one of these programs.

## R2-H1 (High): a guarded match on an element of a `?Vec[E]` parameter does not compile

**Repro** (`r2/f04_guarded_match_readview_elem_plain.rig`):

```rig
enum E
  a(n: Int)
  b(n: Int)

fun f(v: ?Vec[E]) -> Int
  match v[0]
    .a(n) if n > 1 => n
    .a(_) => 1
    .b(n) => n
```

Zig error: `const __rig_subject_2 = &v.*.slot(0).*;`, `expected type
'*T', found '*const T'`. The base fails the same way. `f03` (a Text
payload) and `f02` (a Cell holder, `viaMatch`) fail the same way at HEAD,
and are newly reachable. These sibling forms work:

- a `[]E` or `?[1]E` parameter (f07);
- a local `r = ?e` (f08);
- an element in a shared handle (f09);
- an unguarded match, `if … as`, a loop, a field lend, an implicit
  lend, and a `?self` method on a read-view element (f02b, f06).

**Root cause.** The guarded-match subject (`evalSubject`) takes the
place's address with `as_place` true and `read_place` false. So
`emitIndex` writes `.slot(` under a `*const Vec`. The H2 fix set
`read_place` only in `emitCellAddress`. A class fix: in `emitIndex`, use
`constSlot` whenever the Vec is reached through a read view (the base
type is `?Vec`, or the place is only read), and keep `.slot` for write
places.

## H3: checked, no finding

At `T = Text`, I tried every body form that might copy a `T` out of a
generic loop over `?Vec[T]`. Each is rejected per instance:

- return, storing in a field, a by-value argument, `<x` and `+x`
  captures, `[x, x]`, `Box(x)`, `r = x`, push, `if x as y`, `if <x as y`,
  and `-x` (e01 to e17);
- `T` = a struct of owners, a handle, or a Box.

`!v.swap` in the loop is rejected by the loan. `?x` escaping the
iteration is rejected ("does not live long enough", e16). A generic
write loop assigning `e = <x` drops the old value (e18, clean).

## H2: checked; the round-1 instance is fixed

Cell `set`, `replace` and `?self` methods through these paths, all under
read views, are right (f01, f02b):

- `?Vec[Vec[C]]`, `?[1]Vec[C]`, `?Vec[Box[C]]`, `[]Vec[C]` and
  `?Vec[Vec[Cell[Int]]]`;
- a struct's Vec, array and Box fields;
- `?Vec[*C]`;
- an index with side effects (evaluated once).

The remaining sibling is R2-H1.

## M2: checked, no finding

The early end applies only when the right side does not name the local
and cannot leave early. I tried these ways for the old view to survive
through another route, and each is still rejected where it must be:

- a reborrow `w2 = !w` or `id(!w)`, then `w = <w2` (d01, d02);
- a struct holding `!w` (d03);
- a `<w` capture in a closure (d15);
- `w` moved into a struct (d13);
- a read view `s = ?w` (d14);
- a view pushed through `w` into its target (d12);
- re-pointing in a branch with the old target used after the join (d07);
- loops with `continue` and `break` (d06);
- `defer` (d08).

Sound acceptances that now run:

- reading or replacing the old target on the right side (d09, d10);
- a `![]T` re-pointed in a loop (d11).

## Stop rule: what it covers

- **Rejected at the temporary**, for `match`, `if … as`, `while … as`,
  and `for` read and write:
  - an index temporary (a01, a04, a14);
  - a call-argument temporary on the path (a02);
  - a field after the index (a06);
  - a Box path (a07);
  - a shared-handle path (a08);
  - a temporary nested in the index (a09).
- **Correctly handled:**
  - a call returning a view, with no temporary (a03, matched in place);
  - calls with temporary arguments, rejected by the temporary-loan rule
    (b01 to b07, a05);
  - `<p` takes (r20, round 1);
  - slice sources with temporaries in their bounds or object (a10 to
    a13). The slice points into the original storage, and the writes
    landed.
- **Missed:** branching subjects (R2-C1).
