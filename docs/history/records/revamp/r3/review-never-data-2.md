# review-never-data-2: F1 / F2 fixes at 3fa689e0

Verdict: both fixes sound and class-complete for every form tried (about 75 probes, probes in review-never-data-2-probes/).
Debug and --release under RIG_SANITIZE=1; no finding.

## F1 (cellMadeAway positive list)
Rejected with the "lend each branch" diagnostic: nested branches, a branch inside a path used by value
(`(a.s if k else b.s).c` copy), `match` value, block `if` value, `for ... break ... else` value, `??`, `catch` fallback
over a branch, branch as call argument, generic `pick`/`id` instantiated with S (rejected as a call making S),
branch in array literal, `*O(s: branch)`, branch of `W.o`, via a captured-closure alias, Vec[*O] element leaves.
By-value `S` parameters, `q: S = branch`, and match-subject branches are rejected by other rules.
Accepted and run correct and clean: branch of lends (`?a.s if k else ?b.s`) bound, matched, in loops, used after
`grow(?a2.s)`; in-place receivers `(a.s if k else b.s).c.len`; catch fallbacks yielding Int.

## F2 (sema.calledFn)
Generic closures passing a captured `?T`/`!T` to `sub(?T)`/`sub(!T)`/`fun`: `|?w,?f|`, `|!w,?f|`, two calls,
nested closures, closure in closure over `?self`, method `?self`/`!self`, match binding of generic enum
(`?x`, `!x`), `!v[0]` element, two type parameters, `fun` returning Int, closure called twice.
All run correct. `|+w|`, `|<w|` on views and `|!f|` on a parameter are rejected with diagnostics.

## LOW (conservative, not unsound)
q01: a branch nested as a leaf of a branch used as a receiver
(`(a.s if k else (b.s if k else a.s)).c.len`) is rejected; only the outer node is in_place. Sound; friction only.
