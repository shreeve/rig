# Round B brief: `keeps s` (NEEDS 11)

Owner-approved design: brief items 2a-2f (option (b), the `keeps s`
clause, by-value parameters by type, function values by type, a written
`?` for kept arguments, the CORE sentence 7 text). Launch needs the
owner's go to run beside round A. Draft prepared 2026-10-14; reviewed by Trig, corrections applied.

## Sources (read all)

- `.git/revamp/r3/proposal-call-stores.md`: the design (option (b)), §4
  the rules, §6 the one "lent parameter" classifier, §9 spelling.
- `.git/revamp/r3/owner-brief-ownership-regex.md` §2: decisions 2a-2f
  and the approved CORE sentence 7 text.
- Trig (read only): `docs/ownership/EVIDENCE.md` §3.4, §4, §7.3;
  `docs/ownership/proposal-notes.md` "B" and "Diagnostics";
  `docs/ownership/acceptance/` (`accept/keeps_*` 9, `reject/keeps_*` 10)
  with `verdicts`.

## The rule (approved; CORE wording exactly as approved)

A view lent to a call (`?T`, `!T`, `[]T`, `![]T`, `?String`, an
optional of one, or a `?self`/`!self` receiver) is kept only when the
signature names that parameter in `keeps`. A value passed by value keeps
today's type rule. A function called as a value keeps what its type
could hold. Each body is checked against its `keeps`.

- Written on every `fun`, `sub`, method that stores a lent parameter on
  any path (into `self`, a write argument, or through a call that keeps
  it); never inferred into a signature.
- The compiler's note suggests the clause ("say so: `keeps s`").
- Trusted on `extern zig` declarations, as `from` is.
- Not on function types this round.
- Generic parameters follow the same rule.
- Spelling: `sub watch(!self, s: ?String) keeps s`, after `-> T` and
  beside `from`; `keeps self` names the receiver.
- Built-in generics' methods keep every argument (unchanged until traits).
- A kept argument needs a written `?` at the call (2e).

Desugaring (state in docs/INTERNALS.md):
`f(e1..en) == t1 = e1; ...; tn = en; f(t1..tn)`; the write arguments'
owners hold the loans of the `ti` that `f` keeps; every other `ti`'s
loans end with the statement.

## Required

1. **Tests first.** Import Trig's 9 `accept/keeps_*` (run
   sanitizer-clean, `# expect:`) and 10 `reject/keeps_*` (post-change
   diagnostics). 8 of the 9 accepts fail on main;
   `keeps_union_copies_in` is accepted today and must stay accepted.
2. **One classifier:** "lent parameter kept" decided once, by the
   signature, recorded as a fact; the ownership checker and the oracle
   read it.
3. **Migration of Rig's own code:** every std function, example, test,
   and corpus program that stores a lent parameter gets `keeps`; the
   compiler's note makes this mechanical. List them in the PR.
4. **Diagnostics** per Trig's proposal-notes "Diagnostics" (body check
   at the store with the suggested clause; a kept lend at the caller;
   the two declaration errors).
5. **A B grid in test/matrix.py:** parameter kinds (`?T`, `!T`, `[]T`,
   `?String`, optional, receiver, a by-value parameter of a view-holding
   type, a generic `T`, a call through a function value) x stores (into self, into a write arg,
   through a keeping call, on some paths) x with/without `keeps`.
6. **Docs:** CORE sentence 7 exactly as approved; SPEC; INTERNALS.
7. **Gates:** Mac fast gate; full gates on pup; one independent
   adversarial review; Trig's gate (below); `rig check --time` on Trig's
   src/parser before/after (ownership phase within 10%).
8. **A second soundness round stops the feature.** If B needs to change
   A's path classifier, stop and report.

## Coordination with round A

B branches from main after #206 merges. Whichever of A and B lands
second merges main and reruns the full gates (`GATES_DELTA=1`) on the
combined tree.

## Trig's gate

Trig's `keepsviews` (github.com/shreeve/trig, head 6f07271, on main
3b5c032):

```
RIG=<PR bin/rig> tools/parser/test --sets tokens,ast,parser,parse-only,clean,all-ts,all-js,fixtures   # 18,568/18,568
RIG=<PR bin/rig> tools/lexer/test                                                                     # passes
for m in src/*/; do rig check --tests "$m"; done                                                    # clean, every module
```

- Removing `keeps text` from `Scanner.set_text` must be rejected by the
  body check.
- `docs/ownership/acceptance/verdicts` gives the 19 keeps programs their
  post-B verdicts.
- Today's rig rejects `keepsviews` with exactly 25 errors, all "cannot
  let this call store a view of X in X: X outlives it".
- If B rejects a site Trig expected to pass, report the line to Trig
  before changing the rule or the port.

## Out of scope

`scan_js_doc_comment_for_tags` taking the text (needs A's read-view
path rule; after both land); the regexp parser beside the scanner;
`keeps` on function types; Map/Set's `get(?k)` keeping (with traits).
