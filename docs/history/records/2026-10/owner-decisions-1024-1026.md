# The owner's decisions and scoreboards, 2026-10-24 to 26

**What this is:** the running summary kept for the owner over three days
and nights: what landed, the decisions put to him with their defaults, his
answers in his words, and the scoreboards against tsrs as they stood. It is
history; HANDOFF.md and the ledger say where things stand now. The closing
"fresh session" note names a handoff that is not kept; HANDOFF.md's "Start
here" replaced it.

## The big lift is done
- **APIs Stage 5 phase 2, #622, is merged** (634f9c764): `*{A}`, `~{A}`, and `*{A + Syncs}`. All of Stages 3–5 are on main.
- **Every phase was adversarially reviewed and gated,** and Trig's emitted Zig was byte-identical throughout.
- **Trig's full suites on 634f9c764 are GREEN:** 1,381 jobs, 0 died, matching tsc on 12,892 of 12,892.

## Also landed overnight
- **#624, the blocking pool:** about 3 threads instead of one per call. It's 15–16% faster on Trig's acceptance run; pup's tasks, actors, net and http benches are within 2%; the runtime tests pass in all three modes.
- **#625, std file reads:** `read` stops at the file's size, `read_dir` copies once, small reads go through the stack.
- **#623, the consolidation round 2 plan:** records/2026-10/consolidation-2/PLAN.md.

## Consolidation round 2 (Rig, overseen by me)
- **Track 3, the oracle:** Trig's 7 disagreements were triaged and **none is a compiler hole.** All were oracle imprecisions in four classes, fixed in **#626**:
  - Trig's disagreements went from 7 to 0;
  - the oracle now checks Map and Set by their signatures;
  - its rejections only gained (17 new);
  - its floors only rose (tests to 22,767, docs to 1,077, matrix to 71,930).

- **#627, plain `fun` values are plain data:** the oracle now decides 9,618 of Trig's 9,861 functions, up from 5,174 at the start of the night, and **0 disagreements remain**, with no compiler hole and no CORE question. Its rejections only gained.
- **Track 1, one place per fact** (#629, #631, #632, #633):
  - the crossing check and API object erasure are each decided in one place;
  - a real accept-then-fail is fixed (`rig.IterItem` with an object-shaped optional item);
  - results like `(^{Shape})!` now convert to the object instead of giving "type mismatch".
- **Track 4, docs** (#635, #637):
  - README, WELCOME and QUICK teach APIs, API objects, `Sends`/`Syncs` and `from @field`, and WELCOME maps Rust's traits, `dyn` and Send/Sync onto them;
  - INTERNALS has an "APIs and API objects" section;
  - Learn Rig journeys 03, 04 and 07 are trimmed under 3,000 words;
  - a **new journey 08, "Many types, one contract"**, covers Stages 3–5; the old 08–11 are now 09–12 (the renumbering was accepted under the delegation; easy to revisit).
- **Track 2, parked defects:** 7 fixes, landing together as one gated merge:
  - API objects print hidden text unquoted;
  - an error set with fields lent by address failed in Zig, and now one function decides what's lent by address;
  - `[T: Clone]` clones;
  - `if ?o as v` in generics reads in place;
  - slice and array loops in generics;
  - inference through boxes and handles;
  - `^{Job + Owned}` results need no `from @`.
- **Track 2b** (#643–#651, nine PRs merged in order):
  - nested-by-value builds take 4.9 s instead of 211 s;
  - methods make their instances only when called;
  - better messages;
  - a `fun` field views nothing;
  - ROADMAP rows 18–28.
  Two forms are newly rejected, both listed in the release notes, with Trig told and its light gate green: `lib.List`/`lib.print` through a module name, and a self-nesting public generic. Row 13 (an empty `api`) was your call, given in Rig's session: no.
- **Lean proofs for Stages 4 and 5** (#652), with no `sorry` and only the standard axioms:
  - `erased_runs`: a program with API objects that the checker accepts runs without fault;
  - `crosses_erase`: erasure never lets a value cross that couldn't before;
  - `erase_confined`: the task machine stays confined.
  The gaps (boxes of Int only, counted handles not modeled) are recorded in formal/README.md.
- **The census** (#653): main against f55fe3d9a and ace79d579 on both machines.
  - **pup:** nothing past 2%; Trig runs within 0.9%.
  - **Mac:** spawn was 35–70% slower, bisected to #621 (`os.memory`). That's layout: its new atomic totals shared a cache line with hot runtime globals. **Fixed in #654:** each total is on its own line, and Mac spawn is back within noise (90–136 ns, against 237–258 before). It will be followed by a measured class fix giving the scheduler's hot globals their own lines.

- **The defer hotfix (#663, regated as #660 + main):**
  - a scope's defers now run with its returned value's loans in force;
  - a returned write view moves;
  - closes two memory-safety holes on main, found by the write-view panel;
  - 17 rejections across 3 cases, where the old compiler caught 1;
  - an independent review found it sound.
- **Print forwarding (#664):**
  - a wrong-output bug is fixed: a generic printed `[]U8` bytes as text;
  - public generics whose callee prints their `T` must state `Print`, through the same walk as `Sends`/`Syncs`.
- **std.json restored by construction (#665, merging after its Mac suite):**
  - a program that doesn't use `time.since_start`/`os.memory` compiles exactly as before them;
  - all 12 json builds are byte-identical to before #617;
  - Mac spawn re-timing waits for a quiet Mac.
- **Your three decisions are landed:**
  - row 11 as a ROADMAP line (#655);
  - Map/Set printing in Rust's form, `{"a": 1, "b": 2}`, `{1, 2}` and `{}` (#657);
  - **row 29 per instance (#662):** `iter.count` and the safe shapes are accepted, the unsafe ones still rejected, and the oracle agrees (19,129 Trig functions, 0 disagreements). Two small follow-ups, settled with Rig's defaults under the delegation: `iter.sum` over `?Int` stays rejected (now for the true reason), and one oracle abstention is recorded.
- **Release prep (#656):**
  - `tools/rename-task-bounds.py` (`Moves`/`Shares` → `Sends`/`Syncs`);
  - docs/MIGRATING-0.3.md;
  - CHANGELOG's "Upgrading from v0.2.9" lists **42 forms v0.2.9 accepted that main rejects**, found by running main over v0.2.9's 4,836 accepted programs, each confirmed on both compilers;
  - **migrate-0.3.py's passes are restored (#658):** of v0.2.9's 4,836 programs, main accepts 1,094 as written and **3,495 after the guide's scripts**, and nothing accepted before is rejected after; the rest need a human, named by form;
  - **two leftover v0.2.9 programs, settled by evidence (#659):**
    - one is form 43, a deliberate stricter rule, with its rewrite;
    - the other **changes meaning** between v0.2.9 and main (`l = while … break slot(!n)` now holds a view where v0.2.9 copied). The release notes have a "changes meaning" paragraph, and migrate-0.3.py is being taught to flag the shape;
  - nothing is tagged.

## std.hash (your decision, being built)
- `hash.Map[K, V]` / `hash.Set[K]`: unordered, SwissTable-style like hashbrown. Control bytes probed 16 at a time with SIMD, K and V in the slot, 7/8 load, doubling.
- Same API as `Map`; plain `Map` stays ordered and unchanged, even after `use std.hash`.
- It's being benchmarked against Map, Zig's HashMap and (if cheap) hashbrown, plus a Trig A/B on its hot caches.

## The two Core rules you approved
- **The write-view return: landed (#670).**
- **Partial moves: landed** (#668 the oracle, #673 the compiler). Both checkers agree on every function, and the review's two use-after-free holes in the drops were fixed before landing.
- **The allocator fast path (#676, landed):**
  - small blocks are allocated and freed with no call, from the thread's own free list: 23 and 26 instructions on x86, from about 50;
  - Trig: 1.8% fewer instructions on ts-pattern and 2.0% on zod3, clearing your ≥1% instruction bar; time within noise, faults and RSS identical;
  - two checks dropped, each argued from invariants (the runtime's own tests keep them);
  - the remap skip measured under the bar and dropped.
- **Map quick wins (#675, landed):** `Table.reset` as one fill (bench/hash inserts 11–15% faster, zod3 1.6% faster, ts-pattern even). The two-multiply hash and growing 2× were measured and dropped: no time gain on Trig, and 3.8% more cycles.
- **The map tracer (#671) landed;** Trig's traces come next.
- **The prefault fix (#674), landed, accepted under your speed bar:** Trig at one checker is 2–7% faster with page faults halved (81.0K → 37.8K on ts-pattern), at a cost of 4–6% more RSS (328 → 342 MB). Say if you'd rather not take that trade.

## The beat-tsrs committees: what was measured so far (Trig, pup, ts-pattern)
- **Landed in Trig:** member listing with a keyed sort (#200), −396M instructions and 1.3% faster (zod3 4.2% faster). Mapper caches kept in place, 1.6% faster, is being measured on top.
- **Dropped after measuring:**
  - a name filter, 1.4% slower;
  - recursion identity per stack entry, about 0 (−6M);
  - no copy in the inference mapper, about 0 (−10M);
  - 8-byte relation slots, time even;
  - a key-in-slot table for relations and instantiations, 4.6% slower.
- **The lesson:** the instruction estimates from profiles ran 1.2–25× high, and several cuts saved instructions but no time (Trig's IPC is already above tsrs's). Everything is now judged by measured time on real Trig, which bears directly on the Map/Set packed-slots design.

- **Trig's line-level profile on current main (11.89G instructions, down from 13.22G):**
  - yield checks 3.25% (being fixed);
  - re-hashing already-hashed keys 2.4% (decision 7b);
  - List index tests 3.33% (the proofs track);
  - List.push down to 3.9% from 6.5%, after Trig's #201; what remains is mostly Map growth's rebuild, for the Map design.

## Decisions for you (each with a default)
1. **#617, `time.since_start`,** a new std name: approve as named.
2. **Plan row 29:** when a generic body holds a value of an associated type (`S.Item`, e.g. from `iter.next()`), is it judged per instance (it views its base only if that instance's `Item` can hold a view) or by the body (it may view the base, so the base stays lent while it lives)? **Default: per instance.** That matches how Stage 3 checks calls through bounds (#609, #616), it accepts `iter.count` and the safe shapes, and it still rejects an `Item` view kept past a write to its base.
3. **Plan row 11:** should `p.name()`, where an `add` block gives `p`'s type that method, keep and view what that method itself says (`from @a`), rather than its API's `from @`? The compiler side works (branch add-from), but the oracle deliberately reads the API's declaration. **Default: no change, and a ROADMAP line.**
5. **std.json safe builds on the Mac were 4–7% slower since #617.** You said "we cannot have slowdowns like this", so it is being fixed: a program that doesn't use `time.since_start` or `os.memory` will compile to the same machine code as before those PRs (pay for what you use). Status is below.
11. **Loco's light gate: APPROVED by you ("Perfect! Proceed."), being set up.** Loco just caught a real regression from #624 (the blocking pool spun on a lock with no backoff: 62% of a worker's time on a large walk), which Trig's gate couldn't see. Default: yes, run Loco's 51 checks and byte comparison beside Trig's light gate on every compiler, runtime and std change.
10. **Frame pointers (from committee B1):** dropping them (`-fomit-frame-pointer`) cuts 2.9% of ts-pattern's instructions, but panic traces and `perf -g` would then rely on DWARF unwinding. Default: omit them in release builds only, and keep them in debug.
6. **A release-mode exit that skips drops: DECIDED by you ("Both, memory-only"), being built.** (Trig's ask.) measured, the drops start about 22 ms before exit (167 munmaps), about 2% of the run, of which 7–10 ms (0.5%) comes after the last output. (Earlier estimate: 20–25 ms per run, drops plus 175 munmaps.) After flushing output, a release build would exit without running drops (`os.exit`, or `main` skipping drops in release); debug's leak check stays. It's a new API and semantics, so it's yours. Default: yes, as `os.exit(code)` that flushes and skips drops, documented as not running them; `main` unchanged.
7. **The Map/Set stage's design (#667, records/2026-10/map-stage/):** the top candidate is packed slots. Plain-data keys and values of 32 bytes or less sit in their slot, with 16 slots probed at once (`Simd[U8, 16]`), filled to 7/8, doubling on growth, and order kept as a List of 4-byte slot numbers; the other maps keep dense entries behind the same SIMD index. It also explains why the earlier slots experiment lost: 40-byte slots, and a table growing 4× and so 20–80% empty. Estimated 4–7% of ts-pattern; Trig's traces still have to confirm it. Its five questions, each with a default:
   - (a) adopt it as the target: yes;
   - (b) `!h.set(word)` on `Hasher`, so a key that is already a hash isn't hashed again: yes. **Now measured as urgent:** Trig's 128-bit CacheKey is already a hash, yet Map hashes it again with two 128-bit multiplies (hashMix is 1.14% of all instructions), 3–5 times per relation check;
   - (c) a `$plain(T)` compile-time question beside `$size(T)`: yes;
   - (d) iterating a huge packed map may be slower than today while Trig is faster: accept it for packed maps only, recorded;
   - (e) candidate 3: no.
8. **Scaling (committee B3, [perf-stage/beat-tsrs-committees/B3.md](perf-stage/beat-tsrs-committees/B3.md)):** in the same mode, tsrs scales 3.15× and Trig 2.44×. The causes are checker imbalance from tsc's fixed file assignment (about 95 ms) and a serial parse and bind (about 34 ms); Rig's scheduler is not a cause. Three decisions, each with a default:
   - (a) **Work-stealing checkers (−18%):** Trig's output then equals `tsc --checkers C` only where tsc's own output doesn't depend on the checker count, which held on all six projects tested. Default: approve as an opt-in mode first.
   - (b) **Parallel parse and bind (−7% at 4 checkers):** you said no earlier, when it measured about 1.5% of one-checker time. Default: revisit, yes.
   - (c) **A Rig `par` form where each worker keeps its own state and pulls items** (what makes (a) expressible): a new std API, so the name is yours. Default: yes, with a name to choose from candidates.
9. **Proving away checks (#672, records/perf-stage/checks.md):** remeasured, every check removed is now worth 5.6–7.4% on ts-pattern, not 11.2% (#538, Table/Slot and Trig's records took a share). About 80% of what remains is lookups by stored ids, which a type can prove (as `Slot` does) and a flow proof can't. Decisions, each with a default:
   - (a) **a `Span[n]` std type:** a run of slots a table makes, viewed as a slice with no test. A stand-in is 1.3% faster on ts-pattern and 3.8% on zod3 on pup (1.9% and 3.7% on the Mac). Default: yes;
   - (b) proven conversions written `@bitCast`/`@truncate`, so no `llvm.assume` remains: yes, kept only if not slower;
   - (c) guards make facts on their false edge too: yes;
   - (d) Map `find` handing back the entry: **your approval of the write-view rule settles this one**, and it's the next PR after #670 lands;
   - (e) check summaries across calls: not before measuring.
4. **Map/Set print:** `print(m)` shows internal fields (`Map(len: 1, es: [...])`). Choose the form. **Default: `{"a": 1, "b": 2}` and `{1, 2}`, in insertion order.**

## APPROVED by you (2026-10-25)
"I approve Parallel parse and bind. I also approve everything you have suggested that you think will help."
That covers:
- 8a: work-stealing checkers (opt-in);
- 8b: parallel parse and bind;
- 8c: the `par` form with per-worker state (the name is still to pick from candidates);
- 7b: `Hasher.set`;
- 9a–9c: `Span[n]`, proven conversions as bit casts, guard facts on both edges;
- 10: no frame pointers in release builds;
- the Map design's (a)–(d).
- 8c's name: `par.workers`. You said "Pick whatever name you think I'd like"; I picked it as a plain word for exactly what it is, and it's being built.

## New since (2026-10-25, afternoon)
- **Work-stealing checkers landed in Trig (#207), opt-in** (`TRIG_CHECKERS=dynamic`). Built with today's tasks and Chan; output byte-identical on six projects. ts-pattern at 4 checkers: 0.46 → 0.42 s (8.7% faster). Trig was 2.3× slower than tsrs at all cores and is now 2.1× slower.
- **Parallel parse and bind, first try: slower** (39 ms vs 30). Two causes, both Rig-side: trees on worker heaps miss the prefault, and file calls make 641 futex calls where tsrs makes 5. Rig gets inline-when-idle file calls after the pool lock, and then Trig retries.
- **The pool lock:** -c is never slower than main on Loco's runs, and -d is 7% better on a loaded run. A pinned stress test on pup decides between them.
- **par.workers:** the shape is now `par.workers(!states, ?items, |s, x| body)`, keeping Trig's checkers where they live. It's the std form of Trig's hand-built loop.
- **Loco's expert panels** (six experts) found loco near minimal under Rig's rules. Their asks of Rig, held for after v0.3.0 (one language feature at a time):
  - **Language:** a list literal of fresh owned values (5 of 6 experts); escapes in byte literals and indexing by a byte literal (5 of 6); compile-time functions taking a Static; constant array literals; `for x in chan`; block strings.
  - **Std:** `Map.get` returning a copy for copyable values; `os.isatty`; `print` without the newline; `String.repeat`; `take(!x)`; file reads that fail on not-found.
  - **Runtime:** the yield check in leaf loops (6–7% on loco's scanner; forwarded to #677); cheaper task start.

Decisions:
12. **Make dynamic checkers Trig's default?** Default: yes, after the six-project check passes at 1, 2, 4 and 8 checkers.
13. **Loco's std asks** (`os.isatty`, `print` without the newline, `Map.get` as a copy, `take(!x)`, `String.repeat`): names are yours. Default: a naming round after v0.3.0.
14. **A parameter's optional field: move it like any other field?** Loco hit this: `<p.tags`, where `p` is a parameter and `tags: List[String]?`, is rejected. Non-optional fields move fine. The approved desugaring keeps today's take for optional fields, and a take writes `none` back, which a parameter can't do. The change: an optional field of a name that can't be assigned moves like a name. It accepts only programs rejected today, and nothing changes meaning. Default: yes, as a one-line desugaring note plus the checker fix, with the Core panel's check.
- **APPROVED (2026-10-25), your words "Both":** inline-when-idle file calls (Rig, after the pool lock), and decision 14: a parameter's optional field moves like any other field. Decision 14 starts when one of my running agents finishes, to stay within three agents.
- **#678, prefault at 8 MB per heap:** zod3 at four checkers 4–6% faster, ts-pattern unchanged, peak memory 5% more. Waiting on Trig's light gate (after "pup free").
- **Huge pages: measured and not taken.** At most 2.4% faster on one project, and nothing at all cores. A records-only PR keeps the numbers.

## Scoreboard (pup, 2026-10-25): Trig main 676760a on Rig c2639a40f vs tsrs 0.18.0 (PGO+LTO+BOLT)
Output is byte-identical to tsc's throughout. Figures are fastest of 10, interleaved; "now" is how many times slower Trig is than tsrs, and "start" is where it was at the start of the perf stage.

| | Trig | tsrs | now | start |
|---|---|---|---|---|
| ts-pattern, one thread | 1.022 s | 0.643 s | **1.59×** | 1.76× |
| ts-pattern, all cores (dynamic) | 0.410 s | 0.217 s | **1.89×** | 2.22× |
| zod3, one thread | 0.2025 s | 0.127 s | **1.59×** | 1.71× |
| zod3, all cores (dynamic) | 0.134 s | 0.0677 s | **1.98×** | 2.2× |

Since the start, Trig is 12% faster at one thread and 17% faster at all cores.

What's left: instructions 1.53× (11.06G vs 7.24G); page faults 2.5× at one thread and 4.7× at all cores; RSS 1.65× at one thread and 2× at all cores.
- **Merged #678** (prefault at 8 MB per heap): ts-pattern at four checkers takes 44% fewer page faults with wall time unchanged; zod3 is 4–6% faster. It costs 5% more peak memory. **Merged #679** (huge-pages records: faults fell, time didn't). Main is at 7494bd21c.
- **Fast exit, #680 (draft, gates green), measured on pup:** the release rule at main's end saves nothing on Trig (0–5 ms, noise), because Trig frees its big stores before main ends. `os.exit` after printing saves 22 ms at one checker (1.4% fewer instructions).
15. **Fast exit: land `os.exit` only, and drop main's release rule?** Under your speed bar, `os.exit` passes (≥1% fewer instructions) and the rule doesn't. The rule would also make debug and release drop differently, for no measured gain. Default: land `os.exit` (flushes stdout and stderr, runs no drops) and record the rule as measured and not taken.
- **#682 (draft): Hasher.set and frame pointers, measured.**
  - **`set`:** on bench/hash, prehashed keys insert 10–14% faster and miss 25–29% faster. On Trig it's within noise (0.1%), because Trig's hot keys are packed type ids, not hashes. Setting those raw made ts-pattern 30 times slower: an unmixed value clusters the table.
  - **No frame pointers in release:** Trig runs 2.5–2.9% fewer instructions and is 1–2% faster; bench/tasks is within noise. On std.json, five files are within noise or faster, but gsoc-2018 is 1–2% slower on both machines.
16. **Drop `Hasher.set`?** It doesn't help Trig, and one wrong use is catastrophic (30 times slower). Default: drop it and record why.
17. **Frame pointers off in release, with gsoc-2018 1–2% slower?** That's under the 2% noise line, but "never slower" makes it yours. Default: take it for Trig's 1–2%, and look at gsoc's code layout in the std.json work.
- **`par.workers`, #684 (gates pending):** `par.workers(!states, ?items, |s, x| body) -> List[R]`, with results in item order. On uneven items it's 40% faster than a fixed split, and within 1% of Trig's hand-built Chan loop on both machines. It also fixes a bug: `par.map` and `par.each` took a named function of the wrong type without a Rig error. It merges after both light gates and a code review.
- **std.hash, #685 (held): `hash.Map` and `hash.Set` as a SwissTable in safe Rig.** Compared with the ordered Map, misses are 1.6–3.9× as fast and scattered hits 2.4× as fast. Inserts are 1.15–3.4× slower, and hits in insertion order are 22–56% slower. It's still 1.5–2.2× slower than hashbrown on hits. Trig A/B: ts-pattern within noise; zod3 1–2.5% slower. The causes are Rig limits, not the design:
  - growth writes free slots one at a time (`List.filled(n, none)` can't take an owning optional);
  - String keys are hashed again on growth;
  - each slot is 24 bytes, not hashbrown's 16, because the optional's flag repeats what the control byte already says.
18. **Hold std.hash until those three are fixed?** Default: yes. Hold #685, do the three fixes as one round, and land it only if it clears Trig's bar.
- **Merged #677 (fewer yield checks, same bound):** at one checker, ts-pattern is 2.0% faster with 5.1% fewer instructions and zod3 2.9% faster with 5.0% fewer; at all cores, ts-pattern is 1.7% faster. Loco has 2.4% less user time. Both light gates were green, and the emitted std.json is identical. The Mac bench rows wait for a quiet Mac. Main is at d6f6cb08c.
19. **Drop the yield check from loops that make no calls?** It's worth about 4.4% more on Trig and 6–7% on Loco's scanner. But a task looping over a huge collection without calls would then never yield, and the other tasks on its core would wait until it finishes. Default: no; keep the 1,024-turn bound. The way to get this speed safely is preemption by the operating system's timer, as Go does since 1.14, which is a design round of its own.
- **Merged #683 (pool lock -c: waits by reading, never yields):** on two oversubscribed cores it had the best median and p90 of the three builds, with system time equal to main's. Both light gates were green. Main is at bf459593b.
- **`Span[n]`, #686 (draft): measured, no gain.** With Trig's store lists moved onto spans, ts-pattern is 0.7% slower and zod3 0.6% faster, which is noise, because each read still tests its index. **Guard facts, #687 (draft):** proves 111 more of Trig's checks, from 0.6% slower to 0.2% faster, which is noise; instruction counts are coming.
20. **Drop `Span[n]` (#686)?** It adds a std type and a wasm32/Windows panic rule for no measured gain. Default: close it and record the result. #687 lands if it saves ≥1% of instructions, under your bar; otherwise it's recorded and closed.
- **#687's instruction counts:** 0.013% more on ts-pattern and 0.021% more on zod3, so it doesn't clear the bar. Decision 20 now covers both: **close #686 and #687, and record why.** The checks they remove are cheap, because the processor predicts them, so proving them away doesn't save time.
- **#684 review: fix first.** (1) A state's write view could escape into the results, so two places could write one state. (2) A named function with a scalar `!` parameter fails only in Zig. (3) One valid program is rejected. Everything else is sound: items are taken once each, failure and cancel are clean, and seeds replay exactly. The builder is fixing all three.
- **Merged #684, `par.workers`,** after the review fixes and a clean re-probe; both light gates were green. Main is at f2435554c. Trig has been told it can use it in place of its Chan loop.
21. **Approve the CORE §5 sentence for #688?** "An optional field is taken, leaving `none`, where `p.f = x` could assign it; of a parameter, a capture, or a `=!` local, where it could not, it moves like any other field." The panel found it sound ([param-opt/final.md](param-opt/final.md)). Default: approve.

## DECIDED (2026-10-25): you said "Answer all those decisions as you think I would"; each took my default
- **15:** `os.exit` only. The main-end rule is recorded as measured and not taken. #680 is being updated.
- **16:** `Hasher.set` dropped, with the reason recorded.
- **17:** frame pointers off in release; gsoc-2018's 1–2% gets a look during the std.json work. #682 is being updated.
- **18:** std.hash #685 held, as a draft, until its three Rig fixes.
- **19:** the yield check stays in loops that make no calls; timer preemption, as Go does, is a later design round.
- **20:** `Span[n]` #686 and guard facts #687 are closed, with a records PR.
- **21:** the CORE §5 sentence is approved, and **#688 is merged** (main 6c3f35b78). Loc has been told.
- **Speed:** Trig was asked for a memory-layout push. PGO for Trig gets measured when an agent slot frees.
- **Inline-when-idle (#689): not landed (your decision, in Rig).** It cut futex calls from 702 to 32 and made the front end 5% faster (2 ms), but Trig's whole run didn't move. Records are in #691 (merged); the code is on branch inline-idle.
- **#680 is `os.exit` only, ready.** Its CORE sentence 3, written under your delegation: "`os.exit(code)` ([std.os](STD.md#stdos)) ends the process at once: no later drop point or `defer` is reached, and what is still owned goes back to the operating system with the process." The release rule is recorded as measured and not taken. Waiting on Trig's light gate.

## The measured gap (Trig (fork), 2026-10-25; ts-pattern, one thread)
Trig takes 4.88G cycles to shipped tsrs's 2.96G, a gap of 1,917M cycles (1.65×). Ranked, with who is on each:
1. **tsrs's PGO+LTO+BOLT build: 809M (42% of the gap).** Rig-side; the PGO agent is on it.
2. **Map/Set: +478M** (975M vs 497M). Rig std; the Map stage's trace replay comes first (Rig).
3. **Rig helpers inside Trig's checker:**
   - Table store reads, 405M;
   - List.at, about 130M;
   - bounds tests, 109M;
   - rehashing, 92M;
   - yield checks, 70M;
   - other runtime, about 150M.

   Trig's own logic without them is at or below tsrs's. A new agent is on Table and List reads.
4. **List push/grow/copy: +271M (6.6×).** A new agent is on Rig's growth, and Trig is reusing scratch lists.
5. **Memory:**
   - inference records kept forever, 32 MiB (Trig-side);
   - Map entries' optional flag, about 7.7 MiB, and small-map headers, 14.9 MiB (both in the Map stage).
- **Merged #680, `os.exit`.** Main is at b77ffb199.
- **Merged #682** (frame pointers off in release, so Trig is 1–2% faster; Hasher.set dropped).
- **The Map replay** (Trig's real traces, 18.66M ops, 0 mismatches) puts the packed Map at **3.1–3.7% of ts-pattern**, not design.md's 4–7%. The form as designed was only 1.0%, so it's tuned: rebuild in memory order, a 32-slot first table, and no optional flag. Memory for the replayed maps falls from 103 to 69 MB. Small symbol tables stay on today's path, and there's no stored hash. I approved building it under your approved design. Real Trig decides, and it's killed under 2%.
- **The Map build is blocked on one language question.** A packed slot that's free still has to hold some key, and generic std code can't make a key of type K. The fix is one rule: inside `if $plain(T)`, T is checked as plain data, the way `if x as y` narrows a value, and as Zig does with compile-time branches. It's a CORE §10 change, so it goes through a Core panel and then to you. It's next, since no other language feature is in flight. Meanwhile Rig checks whether the parts that don't need it pay on today's Map.
- **PGO works: Trig is about 10% faster, with about 14% fewer instructions.** The profile was trained on the other project, and output is byte-identical on all six projects. Against shipped BOLT, PGO+BOLT is 8.6–8.8% faster on ts-pattern and 4.8–5.6% on zod3, so BOLT on top of PGO adds about nothing. The path: Zig emits bitcode, clang 22 instruments and optimizes it, and Zig links. A release build takes about 17 CPU-minutes instead of 7. `rig build --pgo` is being built (record: [perf-stage/beat-tsrs-committees/committee-pgo.md](perf-stage/beat-tsrs-committees/committee-pgo.md)).
22. **Approve the `$plain(T)` SPEC paragraph** ([core-plain/5-final.md](core-plain/5-final.md)), the one language change the packed Map needs (4.4% of ts-pattern)? The panel accepted it, with fixes folded in. Default: approve. Rig then builds it, and the Map after it.
- **Merged #696 (Table/List reads):** on ts-pattern, 1.54% fewer instructions and 1.2–2.2% fewer cycles. Trig's light gate was green, and the task benches are equal or faster on a rerun. Main is at 91802aaf5.
- **Merged #698, `rig build --pgo`:** Trig 10.1% faster on ts-pattern and 11% on tiny-invariant, with output byte-identical; builds without `--pgo` are unchanged. Main is at 9822afed9. Trig has been told, and a fresh scoreboard follows its switch.
- **Table prefault: measured and not taken.** Huge pages and populate cut faults (Trig now 19.0K vs tsrs 17.8K at one checker), but kernel cycles stay at 372–411M against tsrs's 172M, and wall is even. The lesson: kernel cost tracks memory touched (about 1.6× tsrs's), not fault count. So the memory levers are smaller objects, freeing inference records (32 MiB), and the packed Map (103 → 69 MB), not page tricks. Records-only PR to follow.
- **#697 (List growth): closed under the bar.** On top of #696 it saves 0.94% of instructions, with no time change, and two std.json programs got really slower (gsoc fast 1.0–1.6%, canada safe 2.0–2.3%). Rig's List already grows the way Rust's Vec does. The real cost is Trig's 3.22M short-lived Lists, and Trig has the list of sites. A records PR follows.
- **APPROVED (2026-10-26): the `$plain(T)` paragraph.** #701 is merged (main 5a79e02f2), and the packed Map build has resumed.

## Scoreboard (2026-10-26): Trig PGO (#217) vs shipped tsrs, on pup
- **ts-pattern, one checker: 893 ms vs 665 ms = 1.34×** (it was 1.59× yesterday and 1.76× at the start). Instructions 1.20×, RSS 1.48×.
- **All cores, dynamic:** 350 ms vs 250 in Go mode (1.40×), and vs 225 in tsrs's default (1.56×). zod3: 1.39× at one checker.
- **Disassembly diff:** Trig's program logic is at parity with tsrs's (1,466M vs 1,396M cycles). About 870M of the 940M-cycle gap is in Rig patterns:
  1. Map, 495M vs 230M (the Map stage);
  2. Table base reloads, 186M, caused by the yield call blocking hoisting (row 5, yield, is 122M vs 0);
  3. List operations, 330M;
  4. bounds tests, 217M vs 39M;
  5. enum conversion, 37M vs 0.

  Agents are on 2 and 5 together, and on 4 and the enum conversion; Rig is on the Map.
- **The packed Map (#702) misses the bar; not landed.** With PGO, ts-pattern is 1.6–2.5% faster at one checker but 1.5–3.8% slower at four. Large general maps regress: a million-key insert is 70% slower, and its walk 10.7× as slow. What did work is the inlining: Map spills fell from 426M to 82M instructions. Next: that hot-path inlining alone, on today's dense layout. `$plain` stays in the language as a general tool.
- **Names confirmed (2026-10-26), your words:** "Keep hash.Map and hash.Set in std.hash, as I chose on 10-25." #685 is being revived with `$plain`.
- **#706 (a yield check that keeps registers): held, under the bar on PGO** (0.8–0.9% fewer instructions; 1.9% on a plain release build). Finding: the Table base is reloaded mainly because of the index test, not the yield call. The bounds agent now targets that site, and #706 gets re-measured stacked on it.
- **A std.json slowdown from my #696, caught by Rig:** commit 22bf02111 (one compare for a signed index) made std.json 3.5–3.8% more instructions per byte, and rig-safe twitter 2–4% slower. My merge skipped a std.json check. The revert is #708 (being gated), and the record is #707. From now on, every runtime or codegen PR shows std.json numbers before it merges.
- **Map inlining (map-inline), cross-checked by Trig (fork):** 1.6% fewer instructions, Map spills down 90%, wall 0.4–1% faster at one checker and even at four, RSS 0.1–0.3% higher (code size). It merges after std.json, bench/hash and both light gates. Trig (fork) has been deleted.
- **APPROVED and merged (2026-10-26, late), your words: "Approve the defaults: land #705+#706, land the Map inlining, accept std.hash with zod3's 3% memory."** #705 (one compare for an index against a fixed bound) and #706 (a yield check keeps registers) landed together: ts-pattern and zod3 1.6% fewer instructions, ts-pattern 1.0–2.5% faster. #710 (Map inlining) landed on top. Trig's light gate is GREEN on both, and std.json's guard is 0.1–0.7% under baseline on main 87d472e17.
- **std.hash (#685): approved, held for one fix.** Trig 1.0–4.1% faster, and ts-pattern's RSS 3.8% lower. zod3's 3% extra RSS isn't the swiss table: peak live bytes are equal (52.9 vs 52.5 MiB). Old tables freed by copying growth stay in the heap's 16 MiB large-block cache. The agent is trying in-place growth from smaller sizes and returning freed blocks to the OS. If zod3 comes out even, the fix goes into #685; either way #685 merges after Trig's light gate.
- **Next leads (Rig's §9, shares to be measured first):** List checks 10%, Map/Set 9%, checker spills 4%, yield checks 3%, hashMix 2%, String hash/compare as calls; Trig NEEDS 62 (blocking calls on the caller's stack when one task can run).
- **Merged (2026-10-26, late), your words "Merge #711 once Trig's light gate is green" and "Merge #712":** #711 (pair hashing, 1.0–1.2% fewer Trig instructions, std.json identical), #712 (HANDOFF, AGENTS, README), and #713 (the ledger's resume entry). main d6c26af22.
- **Fresh session:** start from og-handoff.md here, then the repo's HANDOFF.md and AGENTS.md. A new session doesn't need Rig (OG); questions go to you.
