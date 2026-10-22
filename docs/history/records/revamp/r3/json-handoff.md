# std.json handoff from the "Rig - json.rig" session (2026-10-16)

The owner is retiring this chat. This file is everything that lived only
in it. Owner decisions in force:
- std.json may never get slower; judge a change by exclusive time on both
  machines, honest harness (memory: json-only-faster).
- The freeze is lifted for std.json experiments; each change still lands
  only if it passes the speed rule on both machines.
- The x86 two-stage (simdjson-style) redesign is "not now", per Rig's two
  clmul studies (study-prefix-xor.md).

## In flight: finish these first

1. **strfast: PR not yet opened.** Branch `strfast`, pushed to origin,
   head 0f146e228, worktree ../rig-strfast. `Doc.string` decides the
   common case (an ASCII string ending at a quote) with one guarded read.
   The rest moves into a new inline `string_rest`; `plain` is unchanged.
   - **Passes the rule on both machines (honest harness, against main):**
     - Mac, cpuq exclusive window, 20:03-20:07 on 2026-10-15: twitter
       3393 -> 3512 (3.5% faster), twitterescaped 3051 -> 3166 (3.8%),
       canada 2063 -> 2082, citm 4178 -> 4150 (0.7% slower), gsoc
       8233 -> 8310, github 4069 -> 4124.
     - x86, pup, `cpuq lease pup-bench --exclusive`, outside work 2.6
       CPUs: twitter 2756 -> 2875 (4.3%), twitterescaped 2209 -> 2380
       (7.7%), canada 1287 -> 1310, citm 2900 -> 2988 (3.0%), gsoc
       5775 -> 5734 (0.7% slower), github 3220 -> 3361 (4.4%).
     - Instructions: twitter and twitterescaped 7.6-7.7% fewer, github
       3.9%, citm 2.1%, gsoc 1.7%, canada level.
   - **Review:** a Sonnet review found no bug. It compared 65,285
     generated inputs (truncations, substitutions, padded strings across
     the 8/16-byte boundaries, 60,000 mutants) between main and the
     branch under RIG_SANITIZE=1: byte-identical. Its one comment nit is
     fixed in 0f146e228.
   - **Gate so far:** json (all 9 groups, third-party data) passes. The
     `--delta` suite and `guard.py --update` were running when the chat
     ended. Rerun them on 0f146e228, commit the new guard.txt, and add a
     RESULTS section, "One read for a plain string", with the tables
     above. Then open the PR and auto-merge.
2. **colon: lands after strfast, once inline2 is in.** See
   json-tools/colon.patch.md. It passes on both machines on its own, but
   with strfast `key` goes out of line. Retry it combined, with
   `inline fun key`, once inline2 (#246) lands.
3. **The two-copy reader: waits on inline2 (#246).**
   - **Source:** json-tools/called.rig, regenerated from main with
     json-tools/make_wsspec.py: `called fun document[dense: Bool]`,
     `inline fun number`, and `rarely fun` on fail, utf8_text and
     escaped. Rebuild it from the then-current main, and with strfast
     on top if strfast has landed.
   - **Results so far:**
     - Passed the rule on the Mac (hand-patched to noinline, then in
       plain Rig): citm 8.3% faster, canada 4.0%, github 3.7%, nothing
       slower.
     - On #246's head 2a750cb85: tests pass (84), and the dense-path
       checksums match main's.
     - Instructions: citm 23.7% fewer, the rest 2.4-5% fewer, canada
       level.
   - **Without `inline fun number`:** canada has 11.9% more
     instructions, so it needs inline.
   - **Tests:** json, behavior/std, and json-tools/json_space_dense.rig.
     The dense test expects "middle 12533774216418854047" and "end
     12227242303234227985", the values main gives. Add the dense test to
     test/behavior/std/ in the PR.
   - **Still to do:** time it on the Mac (a cpuq exclusive window) and
     pup (`lease pup-bench --exclusive`), then open the PR.
4. **Wide masks (Rig's branch `widemasks`): you confirm it.** It is built
   from json-tools/ws_stage.rig (`ws_stage FILE N` prints ps/64B and a
   checksum). Citm's checksum is 499,613 non-whitespace bytes per pass.
   Before the round, on the Mac: citm 2611 ps/64B, twitter 2419 (not a
   quiet window). Rig asked json.rig to confirm the numbers on the Mac
   and pup before merging.

## Where std.json's instructions go (pup perf, main 11f1e3bf6)

- **twitter:**
  - ~11%: tape `push` (len/cap/store);
  - 8.1%: `plain`'s re-read of the stop byte (strfast removes it);
  - 7.4%: `skip_space`'s 8-space test;
  - 6.1%: `special()` vector compare;
  - ~4%: ctz and maskOr.
- **citm:** `skip_space` is 18%. The two-copy reader targets it.
- **Against yyjson on twitter:** ~29 more instructions per token (~93
  vs ~64). Checks are only ~1% (the fast build saves 0.4-2.7%, 7% on
  canada).

## Tried and dropped (all recorded in RESULTS or RIG-NOTES except where marked)

| Change | Result |
|---|---|
| Vector whitespace skip (wsvec) | Fewer instructions, 32-41% slower |
| Branch-free space-run count (ws8) | 13-34% slower |
| 4-space branch (wsb) | +8-10% instructions; not recorded |
| Inline first 16 bytes of the string scan (inl16) | +6-13% instructions; not recorded |
| Tape in a local in `document` (localtape) | Up to 3.5% faster on the Mac, 3-6.5% slower on x86 (burst run, indicative) |
| First 4 integer digits a byte at a time (numdigits) | Mac citm 2.6% slower |
| Inline key loop under `inline fun key` (V3) | +9-25% instructions; not recorded |
| `rarely` on cold paths alone (V1) | Fewer instructions, slower in time; not recorded |
| Tape write window via List.filled/resize | Not built: resize zero-fills megabytes per parse unless the tape length moves to its own field |

## How to time (learned the hard way)

- **Mac:** `cpuq run --exclusive --label json:bench -- ...` in a window
  that Rig or cpuq opens. Tell cpuq "ready" when the owner has granted
  one.
- **x86:** pup, `cpuq lease pup-bench --exclusive -- taskset -c 2 ...`.
  A plain lease ran at load 16 and shifted ratios ~5%. About 4 CPUs of
  background can't be drained: rerun if cpuq reports outside work well
  over 4.
- **Never time on burst.** It is a shared Spot VM, for builds and tests
  only (`--spill-to burst`; ship test data, and keep outputs in an
  ignored directory such as .zig-cache, or the next sync deletes them).
- **Judge by time, never by instruction counts** (RIG-NOTES 25).
- **Watch Rig's inliner.** It caps a function's size after inlining
  callees: growing `string` pushed `key` out of line. Check `bin/rig emit`
  for `pub inline fn` versus `pub fn` before timing.

## Housekeeping

- **Persistent files:** json-tools/ holds make_wsspec.py, called.rig,
  called-noinl.rig, json_space_dense.rig, ws_stage.rig and
  colon.patch.md. The resume notes are json-resume.md.
- **Branches:** json.rig's only branch is `strfast` (origin and
  ../rig-strfast).
- **iMessage:** texts to the owner from this role were signed
  "json.rig:" (memory: notify-imessage).
