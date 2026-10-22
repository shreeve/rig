# Review: cell-mark (PR #100, head 340406f2), round 2

Verdict: **the fix is sound and class-complete for the question asked.** No re-pointable `!*T` was obtained from a place that may not be written. No Critical, High, or Medium finding.

Method: built 340406f2 in a detached worktree (removed afterwards). Ran all 17 round-1 repoint probes (p44-p56, p69-p71, p76) plus 70 new probes (`review-cell-mark-2-probes/`, q01-q33, r01-r23, s01-s14), each under `RIG_SANITIZE=1` in debug and `--release`. No push.

## Results
- Round-1 C1/H1 probes: all now rejected in sema with a Rig diagnostic. Two messages: "this handle is read-only here; pass `+c` ... or lend the contents" (const, global, non-`!` param, `|+c|` capture, field of `*S`, field of const struct) and "cannot lend to write through a read view" (read `for`, `if as`, `match`, `?*T` param, `?Vec`/`?S` fields, `?self`).
- New unwritable sources, all rejected: element of `?Vec`, `![]` slice element via `?v[0..2]`, `?`-returned `?*Cell` from a function, `fun -> !*Cell` returning `!v[0]` from a `?Vec` param, generic `?T`, generic `T` by value, generic `!T` over `?S` field or `?Vec` element, `?self` holder, `|?c|` capture, `if o as c` / `?` optional param.
- Writable places that do lend the handle (`!c` local, `!*T` param, `!w.h`, `for c in !v`, `!self.h`, `!v[0..1]`, `if !o as c`) run clean in both modes. Where a view of the old box stays live, the loan checker rejects it (q01-q05, q08, q15, q19, q23, q30-q33, r06, r23, s04, s10, s11). Where the other holder is a `+` clone, it keeps the old box and prints correctly (r07, r08, r14, r16, r17, s09, s13).
- Write lend through a read view of a handle: rejected everywhere tried, `swap`/`replace` included.
- const-handle `swap(!a, !b)` (q21) is accepted and swaps the Cell contents, not the handles; clean.
- Failures were only my probe syntax errors, fixed and rerun.

## Code read
`handleWritable` runs `requireAccess` quietly with the exemption off and restores diagnostics and `handle_exempt`; `requireAccess` has no other side effects, so the one fact is not duplicated. `view_blocked` stops `lendsHandle` for a handle held under a read view of a non-handle. Receiver exemption (`receiver_obj`) is safe: a receiver is a Cell value `!self`, never `!*T`.

## Notes (Low)
- Oracle not re-run by me.
- Not tested: module-level `var` handle; weak `~` handles; Map/tuple containers (syntax unavailable or not found).
