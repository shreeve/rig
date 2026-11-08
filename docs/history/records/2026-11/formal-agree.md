# The agreement test: bin/rig's checker beside λRig's

2026-11-07. Steps 1 to 3 of the plan in
[formal-amp2.md](formal-amp2.md), "Research": the largest assumption
left in `formal/` is that `bin/rig`'s checker agrees with λRig's `check`.
This tests it on the corpus.

## What was built

- `test/oracle/lambda.zig`, `rig-oracle --lambda`: for each program,
  the compiler's verdict (`modules.loadRoot`, what `rig check` runs) and
  the program as λRig's forms, or `outside` and why. The scope is one
  `sub main()` whose statements are bindings, assignments, `<x`, and
  `print`, over integers, names, `<x`, `+x`, `^e`, `?x`, `!x`, and `+`.
  Every value's kind follows from the syntax, so the exporter reads no
  types. Forms whose meaning differs between Rig and λRig are left out:
  a bare name of a box, a view assigned to a view (Rig re-points it), a
  write view of a box read bare, and `+` over a box.
- `formal/LRig.lean`, `lrig`: parses each line's S-expression into
  `Expr` and writes back `accepts` and `run`'s outcome. `lake build`
  builds it.
- `test/cli/agree.sh` and `_agree.py`: list the candidates (a cheap
  filter: one `sub main()` and no text, member, index, type, or block),
  export, judge, compare. Kinds: `agree`; `unsound` (the compiler
  accepts, λRig's run faults: always a failure); `rig-stricter`;
  `lambda-stricter`. The last two fail unless `test/oracle/agreement`
  lists the program; a listed program that agrees, or is gone, fails.
  The script takes about 2 s.

## The numbers

Of 112 candidates in test/rig and examples/, 22 are in scope:

| Kind | Programs |
|---|---|
| agree | 20 |
| rig-stricter | 2: an unread local (`reject/probes/sc2-p.rig`), `none` as a name (`reject/types/none_as_name.rig`) |
| lambda-stricter | 0 |
| unsound | 0 |

The other 90 are outside: 30 do not parse (rejection cases), 26 use a
form λRig lacks, 9 re-point a view, 8 name something main does not bind
(`true`, `none`), and the rest are fixed bindings, other compound
assignments, lends of views, and a large integer.

## Next

The corpus is written for Rig's whole language, so few of its programs
fit λRig's slice. Step 4 of the plan, a seeded generator of programs in
the slice, run both ways in the same script, gives the volume. Each slice
λRig gains (formal/README.md, "Next") widens the exporter.
