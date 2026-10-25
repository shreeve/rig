# Returning a lend through a write-view binding: design

Probes: `core-wview/probes/`.

## Root cause

In `lendOn` (src/ownership.zig), write_view arm, `!s.value` with `s: !Slot` carries a loan on `s` plus `s`'s held loans, which are on `@`. The loan on `s` is on a local, so `checkEscape` reports "cannot return a view of `s`, which this function was not lent". At a scope's end, `escapeVarsFrom` reports "does not live long enough".

This is a class, not one form. The same rejection hits `s = !@a`, `for s in !@xs`, `match !e` payloads, and `e = (!@).find(j)` (probes b, i, h4, n). The read form works only because `walkThroughView` carries no loan on `s`.

**Why accepting it is sound.** A write-view binding is a pointer. Its held loans cover what it sees: the lend's loans for `if as` and `=`, the source loan in `bindLoopElems`, and the `alias_of` loan in `bindPayload`. The loan on `s` only keeps `s` unused while the new view lives (sentence 5). Past `s`'s scope, or past the return, `s` can't be used, so that loan guards nothing. This is Rust's reborrow of `*s`.

The oracle already models it: its `deref` loans are skipped by C6. It accepts every probe, and differences lines 34–50 list the class as prod-strict. Polonius #3 (a conditional return, then reuse on the `none` path) already passes (probe j).

## CORE: amend sentence 7

After "…not a loan on the holder." add:

> A view reached through a write view a binding holds (`!s.value`, `s: !Slot`) carries that view's loans and a loan on the binding. That loan guards only the binding and ends with its scope, so the view may outlive the binding: `if !@slots[j] as s` may `return !s.value` `from @`. *(planned)*

`rig pending`: probe m1, which prints ```output `42`.

Must stay rejected (both are today, by the compiler and the oracle):
- Probe r1: `v = !s.value`, `@slots[j] = none`, `return v` gives ```error `cannot assign to `@slots[j]` while `@slots` is lent`.
- Probe m4: `s = !x` of a local `x`, then `!s.value` gives ```error `cannot return a view of `x`, which this function was not lent`.

Also tested: m2, m5 (using `s` while `v` lives) and m6 (the caller using `t` while the result lives).

Also add one sentence to SPEC's `if !m as x` paragraph.

## Compiler change (ownership pass)

1. Add `Loan.deref`, and compare it in `sameAs`.
2. In `lendOn`, set `deref` when the var is a local with `ref == .write`. Exclude params, captures, hidden, `call_held`, `arm_of` and `erased_of` vars, and `frame` loans.
3. `checkEscape` skips `deref` loans, and `escapeVarsFrom` drops them without a report.

Size: about 25 lines, plus unit tests and about 12 test/rig cases (the probes).

**Oracle:** no code change. Remove the differences entries that now agree (f02, f02b and f04 are move questions and may stay). The run must show no prod-accepts.

## Unlocks, and what it leaves alone

- **Unlocks:** Map and Set `find` returning `(!Entry[K, V])? from @`, with `edit`/`ensure` on top (probe n). That removes the index re-tests behind the 1.3–1.9% ceiling.
- **Separate gap:** the generic read form `if ?@slots[k] as s` over `Slot[K, V]?` is still rejected (h5/h6; the oracle accepts it). A 24-byte slot needs that fixed, plus partial moves.
- **Unchanged:** copies of plain data (h), views of locals and temporaries, caller rules, `from`/`keeps`, and codegen.
