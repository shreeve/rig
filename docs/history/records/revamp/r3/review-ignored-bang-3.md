# Review 3: ignored-bang at d4cd3085 (new since a4325ccb)

Scope: c293f2ff (read-view slots, `sema.yieldedLeaves`, path bases),
fad35ac1 (SPEC table), d4cd3085 (CORE sentence 4), and the clean merge
d1635e32 of main (no conflict hunks). Built `bin/rig` and `bin/rig-oracle`
at d4cd3085, and `bin/rig` at a4325ccb, to tell this round's changes from
earlier rounds'. 67 probes are in
`scratchpad/p3/` (session scratchpad).

## Verdict

**Safe to land.** I found no Critical or High issue: no memory-unsafe
acceptance, and no valid form from the brief's list is wrongly rejected.
One Medium finding, `as` headers, contradicts the new CORE sentence and
should be fixed or written down as an exception before the release tag.
The Low findings can follow.

## Gates run

- `./test/run` on the round's tests (ignored_write_lend*, write_lend_kept,
  write_view_lent_as_copied_read, box_lent_as_value, take_through_lend,
  text_hints): 11 passed.
- Over-rejection scan, `rig check` over every .rig in test/ examples/ std/
  (9823 files):
  - **against a4325ccb**, 7 files are newly rejected, all corpus probes:
    fix-s2f, review-revamp-rest-mut-a_34-bad1, a_34-bad2, a_44-bad2,
    review-revamp-rest-p6-z3, p6-z4, and review-sc4-rw. Each one writes
    `!x`/`!w` where a `?T` or `?T?` goes, which is the intended rule.
  - **against main**, those 7, plus the earlier rounds' 6 (generic `T`
    inferred `Int`, `G(w: !n)`, `!x == 6`) and ignored_write_lend.rig.
    Two behavior tests the branch edited flip the other way.
- Every accepted probe ran under `RIG_SANITIZE=1` in debug and
  `--release`. All ran clean with the same output as main, except the
  pre-existing `(!arr)[i]` family (below).
- `bin/rig-oracle` over all 67 probes: 0 differences.
- CORE sentence 4 reads exactly as the brief asks. The old §4 sentences
  are gone, and nothing left in the docs or src mentions `view_loops`,
  `yieldsWriteViewIn`, or "narrowed".
- SPEC table rows each have a test. `bump(!n)` is covered by many tests.
  `!n + 1`, `arr[!i]`, and `print(!n)` are covered by
  ignored_write_lend_read.rig and the SPEC reject block. `Opt.some(v: !n)`
  is covered by ignored_write_lend.rig, ignored_write_lend_once.rig, and
  a SPEC reject block. `rd(!n)` is covered by
  ignored_write_lend_read_view.rig and a SPEC reject block.

## Valid forms still accepted (checked)

These are accepted and run correctly in debug and release:

- `(!p).x += 1` and `(!p).x = 5`
- `!(!p).items.push(4)`, `(!(!p).items).push(5)`, `!(!p).c.bump()`
- `bump(!n)` through a generic `!T`
- `rd(w)` and `rd(?w)` with a held `w`, and inside a `!Int` parameter's body
- `zero(!arr[0..2])` and `zero(!arr)` to `![]Int`
- a held `![]T` passed to `[]T`
- `if !(!p).o as v` and `if !p.o as v` with `v += 1`
- `bump(!(!p).x)`, `match !(!p).e` with `v += 1`
- `[!n, !m]` written through
- a held field `h.w` passed to `?Int`
- `w = pick(!n, false) ?? !m`, then `w += 1`
- a loop whose `else` and inner-loop `else` `break` give `!n`, held and
  written (e03 prints `6 2`)
- a closure inside a value loop

## Findings

### Medium 1: `(!p).o as v` reads the place, and its `!` is silently ignored

`checkOptionalBinding` calls `markWritten(expr)` for every `as` header.
So every path through a write lend bound by `as` is exempt from
`checkReachedLends`, whether or not anything is written. When the
header has no leading `!`, `v` is a copy, or a read view of a payload
that does not copy, and nothing is written:

```rig
struct P
  o: Int?

sub main()
  p = P(o: 3)
  if (!p).o as v
    print(v)
```

This is accepted and prints `3`. Emit gives `if (p.o) |v|`, so the `!`
is simply dropped. Also accepted silently:

- `while (!p).o as v` (c04)
- with a `Vec[Int]?` field, where `v` is `?Vec[Int]` (c01: `!v.push` is
  then "cannot lend to write through a read view")

The checker's own diagnostic says the write form is `!(!p).o as v`.

This contradicts CORE sentence 4 ("`!x` is rejected wherever `x` is only
read") and the SPEC line saying "the base of a field or element
(`(!p).x`) when the place is only read". `(!p).o ?? 0`,
`match (!p).e`, and `for x in (!p).items` are all rejected, so the `as`
form is the odd one out.

It is not memory-unsafe. **Fix:** mark the header written only when it
is `!`-lent or takes (`moveSource == .optional_part`, a temporary), and
add `if (!p).o as v` to ignored_write_lend_leaves.rig. Otherwise, name
the exception in SPEC and CORE.

Closing this would also reject one member of the miscompile family
below (c03).

### Low 2: `sema.breakValues` ignores label shadowing; a valid program is now rejected (regression vs a4325ccb)

SPEC §Labels: "A label may repeat an enclosing one's name; the innermost
is meant." `breakValues` walks a nested `.labeled` loop's body with the
outer label, so `break :a 5` in an inner `:a` loop is counted as a leaf
of the outer `:a` loop.

Probe e07, rejected at d4cd3085 and accepted at a4325ccb:

```rig
sub main()
  n = 1
  m = 2
  c = n > 0
  k = if c
    :a while true
      j = if c
        :a while true
          break :a 5
      else
        6
      print(j)
      break :a !n
  else
    !m
  k += 10
  print(n, m)
```

```text
error: 13:16: `!n` here is read, not held: only its `Int` is read here. Write `n`
error: 15:5: `!m` here is read, not held: only its `Int` is read here. Write `m`
```

The same program with the inner label renamed `:b` (e08) is accepted
and prints `5`, then `11 2`.

The walk only ever adds leaves; it never misses one. So the effect is
over-rejection in both users (`yieldsWriteView` and `writeLendRead`),
never a silent accept, and soundness is not affected.

**Fix:** in `breakValues`, stop at a nested `.labeled` loop whose label
equals `label`, and check whether `hasValueBreaks` and `breaksOut` share
the gap.

### Low 3: a second, misleading diagnostic when an earlier check rejects the write

`checkReachedLends` runs at module end. When another rule rejects a
write before `requireAccess` runs, the path is never marked written, so
a wrong "only reads" error is added:

- `(!p).items.push(3)` reports the receiver error, then "`(!p).items`
  only reads the place it reaches. Write `p.items`".
- `for x in !(!p).items` reports "`xs` must be a binding", then the same
  wrong "only reads".

This only adds noise to programs that are already rejected.

Diagnostics are also printed out of source order: path errors come
after the leaf errors (ignored_write_lend_leaves.rig pins 38:9 before
35:8).

### Low 4: comments and formatting

- sema.zig:6125: the doc line "A loop used as a value: a `while` or
  `for` ... leaves." now sits above `loopValues`, merged into its doc,
  and `hasValueBreaks` lost its doc.
- typecheck.zig:244: "A loop used as a value: its `break` values and
  its `else` value." now documents `ReachedLend`, and `LoopValue` lost
  its doc. `ReachedLend` and `written_paths` have no doc of their own.
- typecheck.zig:9748: two blank lines where `yieldsWriteViewIn` was
  removed, which `zig fmt` would collapse. The other sema.zig
  `zig fmt` diffs are already on main.

### Low 5: SPEC wording

"A written `!x` binds a generic's `T` to the value it reaches where that
copies, so `Opt.some(v: !n)` stores an `Int`" reads as if the program is
accepted. Only the table and the reject block below say it is rejected.

Suggested wording: "...so `Opt.some(v: !n)` would store an `Int`, and is
rejected."

### Not widened: the pre-existing `(!arr)[i]` miscompile family

These are identical on main, a4325ccb, and d4cd3085. Each is accepted,
and then `zig` fails to compile the emitted code:

- `(!arr)[0] = 7` and `(!arr)[i] += 7`: `&arr[..] = ...` is an invalid
  left-hand side.
- `(!v)[0] = 9` on a Vec: `&v.slot(0).* = 9`.
- `if (!arr)[0] as v` and `if !(!arr)[0] as v` on a `[2]Int?`: expected
  an optional type, found `*?i64`.

This round keeps the assigned and `as` forms accepted. It does not add
new members of the family. It is wider than the one known instance,
though: compound assignment, Vec, and both `as` headers. This is worth
a known-bug test for each.

## Brief items covered

- **`yieldedLeaves` coverage:**
  - Labeled breaks from a nested loop are covered (b01).
  - Unlabeled breaks in an inner loop's `else` are covered (e03), and
    those in an inner loop's body are rightly skipped (b02, b01d).
  - `catch` and `??` leaves are covered (b03, b03b, b03c, b04), as are
    `e?` (d12) and a `match` inside a loop body (d11).
  - Closures are skipped (b10).
  - The one gap is label shadowing (Low 2).
- **Rejections now enforced across contexts.** The path rule fires the
  same way in all of these: generic arguments, `defer`, `test` blocks,
  `raw`, `while` conditions, `match` subjects, `+` clones, `?` lends of
  a path, and generic bodies.
- **Held views stay accepted:** `rd(w)`, `rd(h.w)`, and a held `![]T`
  passed to `[]T`.
- **Re-lending a held view is now rejected where it is only read:** a
  `!w` where `w` is held and only read, such as `peek(!w)` or `(!w).x`.
  This is consistent with the rule.
