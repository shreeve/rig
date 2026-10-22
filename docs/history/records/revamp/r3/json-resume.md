# std.json: resume here ("Rig - json.rig" session, paused 2026-10-13)

**READ FIRST: json-handoff.md (2026-10-16).** The "Rig - json.rig" chat was retired; its in-flight work (strfast PR, colon, the two-copy reader, the wide-masks check) and lessons are there.

Paused by the owner (2026-10-15). No jobs running. #221 (tierarch) merged before the pause; on resume, delete the tierarch branch (local, origin, pup) and ../rig-tier, then wait for #224 (markers) for the two-copy reader.

**PRIMARY FOCUS (owner, 2026-10-14): close std.json's gap to yyjson.**
**2026-10-15 after resume:** #221 (tierarch) merged and is cleaned up
everywhere. The owner split markers (#224) into `called` and `rarely` only;
`inline` is being redesigned on its own branch. The two-copy reader
(json-tools/called.rig) NEEDS `inline fun number`: without it canada has
11.9% more instructions (number goes out of line, two call sites), so it waits
for the inline redesign (2026-10-15: #229 stopped after a second review finding; plan: #230 stack fix, then a frame-owner round, then `inline` as a small change, likely a day or more). When inline lands: rebuild called.rig from main, test
(json, behavior/std, json_space_dense.rig), time on the Mac and burst, PR.
**State (2026-10-15, after the owner's branch freeze):** #221 (tierarch: TIER by
target.arch; x86 up to 9.1% faster, Mac unchanged) has auto-merge on, and also
records the local tape's x86 loss, RIG-NOTES 25's second case, and the 4-digit
variant. localtape and numdigits are deleted (they failed the rule on x86 and
on Mac citm). Next, when markers (with `called`) merges: the two-copy reader,
scratchpad/mk/src/called.rig, rebased onto main (it was built on localtape +
numb4, both gone, so regenerate wsspec from main's json.rig with
json-tools/make_wsspec.py, add `called fun document`, `inline fun number`, and `rarely fun`
on fail/utf8_text/escaped), then retime on the Mac (one window) and burst
(cpuq run --spill-to burst, then ssh burst ... cpuq run --exclusive, taskset -c 2,
remove scratch afterwards) and open the PR. Remove ../rig-called afterwards.
**Two-copy reader (2026-10-14):** .git/revamp/r3/json-tools/called.rig (regenerated 2026-10-15 from main with tierarch; first built on
numdigits = localtape + numb4) is wsspec with `called fun document[dense:
Bool]`, `inline fun number`, and `rarely fun` on fail, utf8_text, escaped.
Hand-patched as noinline it passed the rule on the Mac: citm 8.9%, github
3.8%, canada 3.0% faster, nothing slower. The owner approved `called` (not
cold, Zig noinline); Rig is adding it to the markers PR. When that lands:
compile it, run json, behavior/std, and the dense test
(.git/revamp/r3/json-tools/json_space_dense.rig, expected checksums middle
12533774216418854047 / end 12227242303234227985; add it to the repo), time
both machines, then PR. pup's exclusive slot is still queued for localtape,
numdigits, tierarch (script scratchpad/x86q/pup-time.sh).
Baseline in memory json-competitor-baseline and RESULTS "Against C and C++"
(#207). The gap is instructions per token (~93 vs ~64 on twitter), not
checks (fast build saves ~1%, 7% canada) and not IPC.
- **localtape** (branch localtape, ../rig-localtape): `document` holds the tape
  in a local, put back via back(<t, r) / stop(<t, e, at). Mac: up to 3.5%
  faster, none slower; reviewed (122,159 inputs identical). Waits on pup's
  exclusive slot (build ready in pup rig-wt/lt-bench: rig-safe vs
  rig-safe@src=main; run time.py rig-safe,rig-safe@src=main,sonic-rs 15),
  then PR (add a RESULTS section; guard --update).
- **Tried and failed, by time (fewer instructions, slower):** wsvec (#199);
  ws8, a branch-free U64 space-run count: 13-18% fewer instructions, 13-34%
  slower. A data-computed position on the critical path loses, even in a
  general register. wsb (an extra 4-space branch): +8-10% instructions on
  twitter, not timed. Inlining skip_plain_ascii's first 16 bytes: +6-13%.
- **Micro harness:** scratchpad/micro (objmin, objpretty, arrint, arrstr;
  count.sh). std.json vs yyjson instructions per member: 249/146, 374/163,
  143/79, 118/97.
- **Next:** the `markers` round (`inline fun`, `rarely fun`; owner chose them).
  When it lands: wsspec (two `document` instances, `inline fun number`) and a
  yyjson-style pretty/minify split, timed on both machines. Also the number
  path (arrint 143 vs 79 per member).
- growval will not land (by-value growth bloats `document`); noalias is next in
  Rig. RIG-NOTES 25 should get ws8 as a second example.

**Landed (2026-10-13):** #187 (vector UTF-8 check; Mac fastest of seven
parsers on five files, tied with zimdjson on twitter; x86 1% ahead of
sonic-rs by geomean) and #195 (RIG-NOTES 7 call counts).
**Landing: #199** (auto-merge): the vector whitespace skip, a negative
result. It cut instructions 12-29% but was 32-41% slower on the Mac, and on
x86 IPC fell from 5 to 3.7, from a data dependency on every token's critical
path. Adds RIG-NOTES 25 (guard.py counts instructions only: judge hot loops
by time) and 26 (a guard cannot bind), and the 31,488-case whitespace test.
No branches of mine remain after it merges (delete wsnote and ../rig-wsnote).
**TIER=0 on x86 (2026-10-13, exclusive pup timing):** 6% faster than main by
geomean, no file worse (twitter 10%, twitterescaped 8%, github 10%, citm 4%,
gsoc 3%; canada within noise). Against sonic-rs: 8% ahead by geomean, github
tied, citm 7% behind. The Mac needs TIER=16 (TIER=0 is 5-9% slower on three
files there). Asked Rig for a round adding a compile-time choice by target
(RIG-NOTES 12), e.g. `TIER = 0 if target.arch == .x86_64 else 16`. When it
lands: std.json side, tests, timings on both machines, and close entry 12.
**x86 gap (citm, github 12% behind sonic-rs):** citm is 71% whitespace in long
runs; github is 76% string bytes. The lever is sonic-rs's 64-byte whitespace
bitmap kept in a register (wsspec), which waits on Rig's oncecall round.
For github, look next at the string scan on x86 (skip_plain_ascii is 37-40%
of samples there).

**Where things stand.** Mac, main 598a244e0 + the float change: std.json
is faster than sonic-rs on all six files (twitter 6%, twitterescaped 15%,
canada 5%, citm 9%, gsoc 14%, github 10%). x86 (pup) is still behind
(geomean 7% slower, measured before proofsimd/pushkeep; remeasure).

**Landed:** #167 (float conversion inlined; Float.from_bits): canada 5%
faster than sonic-rs, so all six Mac files lead sonic-rs on main.
**x86 (pup, main + #167):** std.json vs sonic-rs: twitter 5% slower,
twitterescaped 10% faster, canada 4% slower, citm 18% slower, gsoc 11%
faster, github 17% slower; geomean 5% slower. Instructions/byte citm 8.72
vs 6.29, github 8.03 vs 5.39. Raw output in json-x86-20261013.log (columns
rig-safe, sonic-rs, simd-json-tape, serde_json, zig-tape-safe); add it to
docs/json/RESULTS.md with the next std.json PR.

**Waiting on Rig:** inlinect (#154, auto-merging); the cap removal (time
it when asked: wsspec in scratchpad/inl should then keep `number` inline,
citm ~11% faster); SIMD round 2 (#156: vector UTF-8, `\u` decoder, lookup
classify; snippets in scratchpad/simd2).

**When rig#168 lands** (the 64 KB token limit lifted): embed each JSON
file as one literal in test/json/compare.py and bench/json/bench-json
(drop the 60 KB chunks); close docs/json/DESIGN.md's "Large literals and
embedding" item; mark docs/RIG-NOTES.md entry 18 fixed.

**Measured (not a weakness):** `utf8_end`/`utf8_end3` returning `Int?`
instead of -1 cost nothing (within 1% on all six files); rune_size's 3.2%
was its extra checks. Add to docs/json/DESIGN.md's API item ("optionals
in place of -1 cost nothing measured") in the next std.json PR. A
zero-cost std.utf8 helper is utf8_end3's shape with `-> Int?`; time it
with the guard before std.json switches.

**Next levers:** the specialized whitespace bitmap (after the cap goes);
SIMD round 2 adoption; RIG-NOTES entry 8 (List write window, ~3% est.);
the x86 remeasure on pup. The API (Value layer) comes after beating
sonic-rs on both machines (owner's order).

