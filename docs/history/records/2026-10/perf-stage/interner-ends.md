# Row 48: std/text Interner `ends` lookups, share in Trig (2026-11-01)

Source: the prof-item1 profile on pup (core 6, P-core, sibling idle; Trig aa3994b
built --release with Rig 08ddd22bc; cycles/u sampled every 7,000,003; ts-pattern 46
runs, zod3 250). std/text.rig is unchanged from 08ddd22bc to main 6d7728936.
Lines mapped by re-emitting the same pair (scratchpad r48/out/__rig_std_text.zig):

- 695 `end = ends.atProven(i, .lower)`: the first `ends` load in `Interner.text`
- 696 `start = ... ends.at(i - 1)`: the second
- 751 `t = ts[i]` (find's tag probe, not `ends`)

`perf report --sort sym,srcline`, samples on 695/696:

| project | in Interner.find | in checker.Checker.text | total | share of cycles |
|---|---|---|---|---|
| zod3 | 273M (695) | 196M (696) + 14M init | 483M of 153,825M | 0.31% |
| ts-pattern | 56M (695) | 182M (696) | 238M of 144,151M | 0.17% |

Upper bound, adding find's samples with no line (line 0): zod3 0.44%, ts-pattern 0.20%.
Per run: about 2.3M cycles (0.5 ms) on zod3, 6.4M (1.3 ms) on ts-pattern.

The samples are mostly the loads (a dependent miss on `ends` after a tag
match in find; the start load in Checker.text), not the bounds tests: each
test is one compare and a predicted branch. Dropping both tests reaches a
fraction of 0.17-0.31%; even free loads stay under the bar (1.5% time, or
1% instructions).
