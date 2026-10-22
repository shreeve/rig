# Review: fix-view-payload-match (f5b0d00d), fast gate

Reviewer: independent, one round. Base c3558b2e (= main bfae9569 content).
Worktree built at f5b0d00d (`zig build`, `zig build oracle`); main's
`bin/rig` built at bfae9569. Probes: `.git/revamp/r3/probes/review-view-payload/`,
run with `run.sh <probe>` (set `B` in it to a built branch `bin/`; the review worktree is removed) (main check, branch check, branch debug under
`RIG_SANITIZE=1`, branch `--release`, oracle), every step under `timeout`.

## Verdict

No soundness hole found. No Critical, High or Medium findings. The fix is
the right shape: one fact (`payload_fields`, recorded in
`checkVariantPattern` from the instantiated field type) read by the one
classifier (`storage.payloadByAddress`), which emit (`guardBindings`,
`payloadAliases`) and the storage Planner now call identically with the
binding node. Recommend merge.

## What was checked

Probes (all branch results sanitizer-clean, identical in debug and
`--release`, oracle 0 differences unless stated):

| Probe | Covers | Branch | Main |
|---|---|---|---|
| p01_escape_generic_local | Opt[?Text] local, in place, plain + guarded arm, view escapes and is read after stack churn | runs, `hello` x2 | Zig compile error |
| p02 / p03 write_match_view_field(_concrete) | `match !o` assigning a view-typed binding, generic vs concrete | rejected alike ("pattern bindings are immutable") | same |
| p04_write_view_field_generic | Opt[!Int]: `match !o` on param and local, `match <o`, call temp, generic wrapper; writes through | `111111` | Zig compile error |
| p05_optional_view_field | Opt[?Text?] (view of optional) generic and concrete, read/write match, guard, escape | correct | Zig compile error |
| p06_pair_mixed | Pair[?Text, Text]: view field beside an owned field bound by address; guard, escape, write, consume | correct | Zig compile error |
| p07_generic_body_instances | generic body over Opt[T] in place at T=Text, escapes, catch-all, guard | correct | ok |
| p08_imported/ | imported generic and concrete enums with view fields; guard, multi-field, write, consume, catch-all | correct | Zig compile error |
| p09_param_subjects | `!Opt[?Text]`, `?Opt[?Text]`, `?*Opt[?Text]` params, `match ?o`, `match !o`, escapes | correct | Zig compile error |
| p11_slices | Opt[[]Int], Opt[![]Int]: guard, escape, write, consume | correct | ok |
| p14_guarded_write_matches | guarded write matches over Opt[!Int], Pair[?Text, Text], Pair[?Text, !Int]; call temp; consume | `1111 / tt guarded / 111111` | ok |
| p17_escape_then_reassign_subject | escaped view outlives a reassignment of the subject (still views t) | accepted, prints `tt` (correct) | Zig compile error |
| p20_other_instances | Opt[H] (struct holding a view), Opt[*Text], Opt[?*Text] | correct | ok |
| p15, p16, p18, p19 | escaped payload view, then its referent dropped / moved / grown / reassigned (local, call temp, slice, `!` param) | all rejected (loan live) | same |

- `test/matrix.py -k viewpay.`: branch 99 ran clean, 43 rejected, 0 failed;
  main 43 ok, 43 rejected, 56 failed. The 43 rejections are the same cells
  on both. Oracle over the grid: 13 differences, all `stricter`
  (prod rejects, oracle accepts, the `*.whole` cells); none looser.
- `rig check` over all 9809 `.rig` files in test/, examples/, std/ with
  main's and the branch's compiler: identical exit status for every file
  (no over-rejection, no new acceptance).
- `./test/run -j 2 payload match enum facts_sema view_payload unit`:
  511 passed, 0 failed.
- Generic bodies: a generic is never instantiated at a view (`T = ?Text`
  is rejected at the call: "a generic function is checked for a `T` that
  holds no `?T`, `!T`, or slice"), so the fact, keyed per node and
  recorded once per body, cannot be overwritten by instances. In a body,
  `G[?T]`'s field is `?T` and is bound as is.
- Sibling sites grepped (emit, storage, ownership, typecheck, oracle):
  `storage.variantPayload` / emit `variantPayload` / `consumedPayload`
  read declared fields only for names and counts; ownership's
  `bindPayload` uses the binding's symbol type (instantiated);
  `typecheck.readBinding` and the `arm_view` flag use the instantiated
  `f.ty`. No production site still classifies by the declared field type.

## Findings

### Low 1: the oracle's `payloadOf` still reads the declared field type

`test/oracle/lower.zig:1135` (`payloadOf`) returns `sema.dataFields(f)[i].ty`
from the declaration, so for `G[?T]` in a generic body it hands
`bindHeld` the declared `T` as `stored`, while the binding is `?T`.
`bindHeld` then models the binding as a fresh loan of the subject
instead of a copy of the view the field holds. This errs strict, never
loose, and generic instances at a view outside a generic body make the
oracle abstain ("a generic instance at an owner or a view"), so it hides
no hole; it is the same declared-vs-instance confusion the branch fixes
in production. Fix: read `ctx.payloadFieldOf(b)` there (or substitute).
Not a merge blocker.

### Low 2 (pre-existing, not this branch): a payload that is itself a view is tied to the subject

p12_local_subject_return (generic) and p13_local_subject_return_concrete
(concrete): `o = Opt.some(v: x); match o .some(r) => r` in a function
`from x` is rejected "cannot return a view of `o`"; p10_catchall_mixed_pair
and the grid's `*.whole` / `*.local.ret|guard` cells are rejected
"`w` does not live long enough". `r` is the view `x` the field held, not a
view of `o` or `w`, so these are over-rejections. Main rejects the same
programs identically and the concrete enum is treated the same as the
generic one, so the branch neither causes nor widens it. The oracle
accepts several (`stricter` in p10, p13 and the grid). Candidate for a
later precision change in ownership (carry the field's loans, as Core s7
does for a String payload), not for this fix.

### Notes (no action)

- `payloadByAddress` now returns `writes` when no fact exists (poisoned
  field type) without the `fieldIsPointee` check the old code applied.
  Only reachable on a program with an error, so emit never sees it.
- Commit is test-first in spirit: the new behavior test and the `viewpay.`
  grid fail on main (Zig compile errors) and pass on the branch.

## Soundness statement

No soundness hole remains that I could find: every accepted probe binds
view fields as the view they hold (no pointer-to-pointer, no copy where a
view is expected), escaped payload views point at the real referent after
stack churn, every probe that invalidates that referent is rejected, and
all runs are sanitizer-clean in debug and `--release`.
