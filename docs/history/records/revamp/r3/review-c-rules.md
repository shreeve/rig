# Review: the C rules (`c-rules` at `8f4ea627`)

Reviewer: an independent adversarial reviewer. I built with `zig build`
in `/Users/shreeve/Data/Code/rig-c-rules`; `bin/rig` already matched
HEAD (the C3 behavior test runs and the C3 reject test rejects). I ran
single programs with `RIG_SANITIZE=1`, compared each with `rig-v020`,
ran `bin/rig-oracle -v` on each, and changed nothing in the worktree.

Probes: `probes/review-c-rules/` (72 programs and `mod1/`, a two-module
program). Each has a header comment. A few are invalid on both
compilers, and I kept them as a record of shapes the language already
closes: `c2_box_vec_nest` (a Box cannot hold a view),
`c2_weak_direct` (`~` needs a `*T`, not a `?*T`),
`c2_generic_with_body_view_arg` (generic types cannot have `drop`), and
`c1_header_temp*` (a temporary cannot be lent to write).

## Verdict

**No soundness finding in C1, C2, or C3.** No rule needs a second
soundness round, so none stops. I found no accepted program that
corrupts memory, leaks, uses freed memory, gives a wrong result, or
fails in Zig. Every accepted probe ran sanitizer-clean with the right
output. The findings below are about docs, the oracle, and how complete
the rules are.

| # | Rank | Rule | New? | Finding |
|---|---|---|---|---|
| L1 | Low | C2 | new | Two SPEC §10 passages still say a Vec of views is in use until it is dropped |
| L2 | Low | C1 | new (the claim); the mechanism is older | The read downgrade does not reach a `for` source or a `match` subject; the compiler is `stricter` than the oracle |
| L3 | Low | C3 | extends an older oracle gap | The oracle rejects `y = h.w if c else g.w`; the compiler accepts it and is right |
| L4 | Low | none | pre-existing | The note "lent to read here" points at a `!` receiver |

## What I attacked

### C1 (`carryResult`): no hole found

**Write access smuggled through the result.** Each of these keeps the
write loan, or is rejected:

- A generic struct instantiated with a write view, `Pair[!Int]`.
- `(!Int)?` and `[1]!Int` results (`c1_generic_struct_write_arg`,
  `c1_optional_write_result`, `c1_array_write_result`).
- A stack closure cannot return a view of a capture
  (`c1_closure_returns_capture`).
- An owned closure cannot capture views.
- A callable result can only return what the caller lent.
- A `?H` result whose `H` holds `!T` drops `write` from `views`, because
  `reachOf` masks reach through a read view. This is still safe: writing
  through `r.w` needs write access to the struct, and the holder `h` stays
  live and write-lends the target.

**The loan lands on the right root.** `mayOwnView` counts a holder of a
write view as owning (ReachWalk keeps `path.read` false across
`.write_view`). So the read loan lands on the holder, not on the
target, for:

- a write-view binding (`c1_write_view_var_reborrow`);
- a `!Vec` parameter (`c1_write_view_param_reborrow`);
- a struct field (`c1_through_held_write_view*`);
- a `Vec[!Vec[Int]]` element (`c1_vec_of_write_vec_views`).

A push or re-point through the holder is rejected in every case.

**Stores.** A write view stored by a field assign or by
`!dst.push(!v[0])` keeps `v` write-lent, so `v` cannot be read or pushed
(`c1_store_via_push*`).

**Same statement and self-reference.** All of these are rejected:

- `both(first(!v), !v)`
- `!b.consume(!b.first())`
- `h.r = first(!h.w)`
- `!h.rs.push(first(!h.w))`

**Headers.** A push while the payload lives is rejected in each form:

- `if … as` (`c1_optional_result_header`);
- `while … as` (`c1_while_header`);
- a fallible `r = find(!v)!` (`c1_fallible_result`);
- `match` (`c1_match_payload`);
- `for` (`c1_for_source`).

The accepted forms run right: `c1_while_header_ok`, `c1_fallible_ok`,
and `c1_text_string_result_ok`, which takes the String path through
`holdsViewOnly` and `keepViewTemps`.

**`c1_vec_of_write_views`** (`?Int` from `!Vec[!Int]`, then `ws[0] = 5`)
is accepted on both compilers and prints the old value. That matches
Core §4: a call's `?Int` result is a copy and carries no loan. It is not
a finding.

### C2 (`sema.dropRunsBody`): no hole found

**`dropRunsBody` matches what the emitted drop runs.**

- A `*T` holder follows its target's `drop`.
- `~T` correctly does not.
- A drop body that reads a view through `~T` is safe, because the weak
  carries the loans of the strong handle it came from. Both `g = G(w: ~p)`
  and `w = ~p` are rejected (`c2_weak_upgrade_in_drop`, `c2_weak_direct2`).
- A route that hides the weak in a Cell is rejected: "cannot store a view
  of `a` in a `Cell`" (`c2_weak_in_cell`).
- Owned closures and Signals cannot hold views, so type erasure hides no
  drop body that could read one.
- An enum payload, an array of `(*Guard)?`, and a `Vec[Guard]` under a
  generic container all keep their loans to scope end
  (`c2_enum_payload_body`, `c2_array_of_opt_shared`,
  `c2_generic_body_inner_block`).
- Across modules, both forms keep their loans to scope end (`mod1/`): an
  imported generic holding a local `Guard`, and an imported struct with a
  drop body.

**Deferred use through an alias keeps the container live.** Both of these
are rejected (`c2_defer_closure`, `c2_defer_holder_struct`):

- `defer f()` of a closure that views the container;
- `defer print(r.v…)` through `r = ?s`.

**A view of an inner-block value may stay in an outer container.**
Structs with `Text` and `Box` fields, enums with owned and viewed
payloads, and `T?` all drop sanitizer-clean after the viewed value is
gone (`c2_inner_block_mixed`).

**The drop-order check is unchanged.** `!= .yes` matches the old
`runsDropBody`, which returned false for a type variable.

### C3 (`readsThroughWriteView`): no hole found

**Non-plain targets are rejected:** a plain struct, an enum with a Text
payload, and `!(Int?)` (`c3_struct_field_copy`,
`c3_payload_enum_field`, `c3_optional_int_field`).

**Where a `!T` goes, `h.w` is rejected or treated as a lend.** These
contexts are covered:

- a struct literal field;
- a push;
- `(!Int)?`;
- `[2]!Int`;
- `return` as `!Int`;
- a typed `!Int` binding.

**String copies keep the Text's loan.** This holds for fields, elements,
and a re-pointed holder (`c3_string_*`).

**Values come out right in every form tested:**

- assignments between views (`ws[0] = ws[1]`, `ws[0] += ws[1]`,
  `h.w = h.w + ws[0]`);
- evaluation order (`ws[0] + bump(!ws)` reads 1 before the bump);
- Float and U8 elements;
- conditional, `match`, and block values;
- through a `?H` parameter.

See `c3_assign_between_views`, `c3_eval_order`, `c3_float_u8_elem`,
`c3_contexts_run`, `c3_cond_expr`, `c3_match_arm`, and `c3_block_value`.

## Findings

### L1 (Low, C2, new): SPEC still says a Vec of views is in use until it is dropped

Probe: `c2_vec_string_doc.rig`

```
t = Text("hello"); v: Vec[String] = Vec(); !v.push(?t[..2]); print(v)
!t.clear(); !t.add("…longer…"); print(t)
```

HEAD accepts it and runs sanitizer-clean, printing `["he"]` and then
the new text. `rig-v020` rejects it: "cannot lend `t` to write while a
read loan is live".

Two SPEC §10 passages now state what C2 removed:

- **SPEC.md:4207–4208.** "Once the last use … is past, the Text is free
  again; a Vec holding one is in use until it is dropped."
- **SPEC.md:4277–4279.** "A Vec that holds views keeps their Texts lent
  until it is dropped, since it is in use until then; drop it early with
  `-v` to change them sooner." The example after it, which uses `-views`,
  still runs, but `-views` is no longer needed.

This is a Rule 1 docs issue. The commit updated SPEC §7 (line ~3103) but
not §10.

### L2 (Low, C1): the read downgrade does not reach a `for` source or a `match` subject

Probes: `c1_for_source_read.rig`, `c1_match_subject_read.rig`

```
for x in all(!v)          # all(v: !Vec[Int]) -> []Int
  print(x, v.len)         # error: use of `v` while a write loan is live
match find(!v)            # find -> Res, payload ?Item
  .found(it) => print(it.n, v.len)   # same error
```

The oracle accepts both, so the compiler is `stricter`. The same
`match` with the result bound first (`r = find(!v); match r`) is
accepted. `if … as` and `while … as` subjects are downgraded too.

**Root cause.** It is not `carryResult`. The `!v` argument's own write
lend lasts until its statement ends, and a `for` source or a `match`
subject is one statement with its body. An `if`/`while` condition, by
contrast, is its own statement. That mechanism predates C1; the gap is
between it and C1's text.

Core sentence 7 and SPEC §7 state the rule without this exception, and
`test/oracle/differences` does not list it. This is sound: it only
over-rejects. Either a sentence in the docs or a classified `differences`
entry would close it.

### L3 (Low, C3, extends an older oracle gap): the oracle rejects a conditional expression of write-view fields

Probes: `c3_cond_expr.rig`, plus the control `c3_cond_expr_names.rig`

```
y = h.w if pick() else g.w    # w: !Int
y += 10
print(y); print(n, m)         # 11, then 1 2: correct
```

The compiler accepts and runs it correctly. The oracle reports `DIFF …
prod=accept ref=reject C2 a bare write view would be copied`.

The same DIFF already exists at `rig-v020` with bare names
(`y = w if pick() else v`, the control probe), so the oracle's
copy-on-read lowering (`want`) does not pass through `if` expressions.
`match` arms and block values are fine (`c3_match_arm`, `c3_block_value`
agree). C3 widens the gap to fields and elements.

No current test set has this shape, but one that adds it would fail the
oracle set. The fix belongs in `test/oracle/lower.zig`.

### L4 (Low, pre-existing, not a C rule): a misleading diagnostic note

Probes: `c1_receiver_and_arg.rig`, `c1_self_store_vec.rig`

```
!b.consume(!b.first())  ->  note: lent to read here   (points at the `!b` receiver)
```

`rig-v020` prints the same note. The rejection is right; only the note's
wording is misleading.

## Oracle

I ran `bin/rig-oracle -v` on every probe.

- **Accepted-by-compiler, rejected-by-oracle (DIFF):** only `c3_cond_expr`
  and its pre-existing control (L3).
- **`stricter`:**
  - `c1_for_source_read` and `c1_match_subject_read` (L2);
  - `c3_into_optional`, where the oracle accepts `o: (!Int)? = h.w`. The
    compiler rejects it, which is right: the oracle's
    `wants_view = want == .write_view` misses an optional of a write view.
    That is an oracle gap and does not affect soundness.
- **Everything else:** both checkers give the same verdict.
