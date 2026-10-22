# Review round 2: the C rules (`c-rules` at `1c06aac9`)

Reviewer: the round-1 reviewer (`review-c-rules.md`). I rebuilt in
`/Users/shreeve/Data/Code/rig-c-rules`: `zig build` and
`zig build oracle` were no-ops at `1c06aac9`. I ran single programs with
`RIG_SANITIZE=1`, compared each with `rig-v020`, ran
`bin/rig-oracle -v` on each, and changed nothing in the worktree.

Probes: `probes/review-c-rules/r2/` (40 programs, each with a header
comment).

## Verdict

**No soundness finding in cf4e2c4b (the early end of an argument's write
lend), in the bare-read rule (94f5883b, 2c7ab72d), or in e8dc7278.** I
found no accepted program that corrupts memory, leaks, uses freed
memory, gives a wrong result, or fails in Zig. Every accepted probe ran
sanitizer-clean with the right output.

**No rule needs a second soundness round, so none stops.**

The round-1 findings are fixed:

- **L1:** SPEC §10 now says the Texts stay lent only until the Vec's last
  use.
- **L3:** `c3_cond_expr` now agrees with the oracle.
- **L4:** the receiver note now reads "lent to write here, as the
  receiver, which is read until the call starts".
- **L2 (round 1):** `for x in all(!v)` and `match find(!v)` reading `v`
  are accepted. The read loan lasting through `match` arms is now listed
  in `test/oracle/differences`.

| # | Rank | Area | New? | Finding |
|---|---|---|---|---|
| L1 | Low | cf4e2c4b | new (the claim) | A generic call keeps its argument's write lend for the whole statement, so `print(gfirst(!v).n, v.len)` is rejected; the compiler is `stricter` than the oracle |

## What I attacked

### cf4e2c4b: no hole found

`endWriteLends` removes the write temporaries made since the call
started. It keeps any whose root the call may store, then re-adds the
result's own loans as read temporaries for the rest of the statement.
For a callee to keep write access after it returns, it would have to
hold a write path outside both its result and its stores. I found no way
to do that.

**A closure that stores the view through its capture.** This is rejected
on both compilers: "cannot store a view of `w` through captured `h`"
(`cf_closure_stores_param`).

**A `?Hold` result whose `Hold` holds `!Vec`.** `viewsOnlyRead` is true
for it, because a read view masks what is behind it. Two things make it
still safe:

- writing through it needs write access to the struct;
- `h` stays live through the read temporary, and `h` holds the write
  loan.

So a later `!v`, `!h.w`, or `!h` in the same statement is rejected
(`cf_read_view_of_write_holder*`, `cf_slice_of_write_holder`).

**Iterators.** A struct over a read slice can come from `iter(!v)`, be
bound, or be called in an `if` header. Either way, the body's `!v.push`
is rejected (`cf_iterator_struct`, `cf_iterator_inline`).

**Generics.** In both `main` and a generic body,
`bothg(gfirst(!v), !v)` is rejected (`cf_generic`).

**Headers.** Each of these is rejected:

- a `for` body that lends `v` through a fresh alias `w = !v`
  (`cf_header_alias`);
- a `match` arm that calls `grow(!v)` while the payload lives
  (`cf_match_arm_write_via_call`).

**Nesting.** In `two(passw(?x, !v), first(!v))`, the outer write-view
result keeps its lend, so the later `first(!v)` is rejected
(`cf_nested_reread`).

### The bare-read rule: no hole found

**Non-copy write views are rejected** in all of these forms:

- an untyped binding of a bare `w: !Vec`;
- a branch mixing it with a lend;
- a typed `y: !Int = w`.

See `br_noncopy_name`, `br_mix_noncopy`, and `br_typed_binding_name`.

**A branch mixing a bare write-view name with a lend reads both as
values.** Examples are `w if c else !m`, `w if c else get(!m)`, and a
`match` of `h.w` and `!m`. `y` is an `Int`, and writing `y` changes
neither `n` nor `m`, so no view is aliased (`br_mix_*`).

**Branches of `!String` names and fields keep the Text's loan.** A
later `!t.clear()` is rejected (`br_string_branch`,
`br_string_match_name`). Plain enum and Bool branches are emitted
correctly (`br_enum_branch_emit`).

### e8dc7278's siblings: no hole found

Each of these reaches a second lend of the same root while a write loan
is carried, and each is rejected:

- a write-view result used as the receiver of a call whose argument reads
  or writes the same root (`e8_receiver_sibling`,
  `e8_result_as_receiver`, `e8_result_as_receiver_vec`);
- a consuming `<self` receiver that holds `!xs`, with a `?xs[..]`
  argument (`e8_consumed_receiver*`);
- a moved holder as an argument (`e8_write_view_receiver_value`);
- a closure callee that captured `!xs` (`e8_closure_callee`);
- a struct literal of a moved holder, a moved view, or a write-view result
  next to a read slice of the same Vec (`e8_struct_holds_both*`);
- array literals (`e8_array_literal_*`, `e8_array_both`);
- `print`, `Text(...)`, and a binary operator (`e8_print_sibling`,
  `e8_text_sibling`, `e8_binop_sibling`).

Assignment through a write-view result with a right-hand side that grows
the Vec is accepted. It is also correct: emit evaluates the right side
first (`const __rig_new = growv(&v); (firstv(&v)).n = __rig_new;`). It
runs clean on both compilers (`e8_assign_sibling`,
`e8_compound_assign_sibling`).

`both(!b.firstw(), ?b)` is accepted by `rig-v020`, so e8dc7278 fixes a
pre-existing hole rather than one round C introduced.

## Findings

### L1 (Low, cf4e2c4b): a generic call keeps its write lend for the whole statement

Probe: `cf_generic_ok.rig` (a minimal copy is below)

```
fun gfirst[T](v: !Vec[T]) -> ?T
  ?v[0]
...
print(first(!v).n, v.len)    # accepted
print(gfirst(!v).n, v.len)   # error: use of `v` while a write loan is live
```

The oracle accepts it: `stricter … main prod=reject ref=accept`.
Binding the result first (`r = gfirst(!v); print(v.len)`) is accepted.

**Root cause.** `defaultOrigins` gives a generic function the origins of
its own signature, "where a type parameter could hold anything". So
`v: !Vec[T]` is in `stores`, and `endWriteLends` keeps the write lend as
a possible store.

**This is sound but contradicts the docs.** Core sentence 7 says that
after `head(!v)`, "in its own statement or through `r = head(!v)`", `v`
may be read, and it makes no exception for generic calls.
`test/oracle/differences` does not list the case. Two fixes would work:

- **Instance-level origins.** In an instance, `T` cannot hold a view, so
  `T` adds nothing to `stores`.
- **Document the gap.** Add a `differences` entry and a line in the docs.

## Oracle

I ran `bin/rig-oracle -v` on every probe.

- **DIFF (the compiler accepts, the oracle rejects):** none.
- **`stricter`:**
  - `cf_generic_ok` (L1).
  - `e8_print_sibling`, `e8_text_sibling`, and `e8_binop_sibling`. Each
    calls `firstv(!v)`, which returns a write view, then `growv(!v)` in
    the same statement. That is the listed `write_result_whole` class:
    a write-view result keeps its lend for the statement.
- **`unknown`:** a few, on write receivers without `!` and on write views
  seen through a read view.
- **Everything else:** both checkers give the same verdict.
