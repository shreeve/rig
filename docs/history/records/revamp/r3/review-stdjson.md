# Review: std.json round (`stdjson`, worktree /Users/shreeve/Data/Code/rig-stdjson)

Reviewed HEAD f6804d936, plus the uncommitted edits that were in the
worktree during the review (DESIGN.md, RESULTS.md, STD/README/HANDOFF
text, the json.rig header). Line numbers are from the working tree as it
was then.

Probes: /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/1c58de3a-5ee5-45ab-8975-d40e96d31938/scratchpad/jsonreview/probes/
- Worth keeping in test/corpus/: `scan_exhaustive.rig` (runs clean, about
  7 s in debug under the sanitizer, prints `checked 358940 mismatches 0`),
  `dangle_drop.rig`, `dangle_mutate.rig`, `dangle_loop.rig`,
  `dangle_reparse.rig`, `dangle_return.rig`, `stale_view.rig` (all
  rejected), and `partial_tape.rig` (runs clean; it shows finding M1, so
  its expected output changes with the fix).
- `evidence/`: not corpus material, since they panic on purpose
  (`wrong_getter*.rig`), plus the STD.md example extracted and run.

## Summary

| # | Sev | Where | Finding |
|---|---|---|---|
| M1 | medium | std/json.rig:194-203, docs/STD.md:558 | A failed parse leaves a partial tape, though STD.md says "there is no partial result" |
| M2 | medium | test/json/compare.py:489-508, 222-242 | The data check fails open: with an empty manifest, checker and corpus pass with 0 cases, even under JSON_REQUIRE_DATA=1 |
| M3 | low-med | test/run:487-491 (check_json), test/json/README.md:36 | A skipped group is recorded as a plain `pass` with no reason. `-v` shows no note, which contradicts the README |
| L4 | low | std/json.rig:154-190, docs/STD.md:543-546 | Getters called on the wrong kind or out of range return silent garbage or panic, and the docs don't say so |
| L5 | low | test/json/compare.py:448-450, test/run check_json | The `JSON` env var swaps the parser under test/run, but the pass is recorded under std.json's results key |
| L6 | low | .github/workflows/shards.yml (cache step) | The cached `path` includes the tracked test/json/data/README.md, and a restore overwrites the checked-out copy |
| L7 | low | docs | Stale or inconsistent counts and speeds, NEEDS items missing from Open items, an unchecked "allocates nothing" claim, and size limits not documented |
| L8 | low | test/run json | The JSON groups only ever run in debug, so the SIMD and SWAR kernels are never checked in `--release` by the suite |

No `raw` in std/json.rig. `skip_plain_ascii` is correct (proof below, plus
358,940 exhaustive inputs in debug+sanitizer and in `--release`). The API
cannot dangle: all six misuse probes are rejected. The STD.md example runs
and matches its output block.

## M1. A failed parse leaves a partial tape

`parse` clears the lists and then `document` pushes entries until the
first error. On failure the tape keeps what was pushed, and the array and
object entries that never closed still have payload 0.

Probe `partial_tape.rig`:
```
src = "[[1"   →  parse false, error eof 3, size() == 3
kind(0) == .array, kind(1) == .array, next(0) == 1, next(1) == 1
```
`next(1) == 1`, so the usual skip loop `i = doc.next(i)` starting at 1
never advances (a hang). STD.md:558 states "`parse` reads the whole
document or fails; there is no partial result." That is a docs claim the
code contradicts (AGENTS rule 1).

Fix: in `parse`, when `document(src) < 0`, clear `tape`, `text`, `floats`
and `ints` (a few instructions, error path only), then keep the sentence
and turn `partial_tape.rig` into a test that expects `size() == 0`.
Alternatively, document that the tape is unspecified after `false`.

## M2. The data check fails open when the manifest parses to nothing

`manifest()` (compare.py:489-496) takes only lines that split into exactly
two fields, a 64-hex sha and a path. If none match, `data_problem()`
returns None and the data counts as valid. `checker_group` and
`corpus_group` then glob whatever is in `data/`, and a group with 0 cases
exits 0.

Shown in a scratch copy of the tree, with a third column (`-`) added to
each manifest line. `fetch_one "$0" "$1"` under `xargs -L 1` still
accepts such lines, so the fetch script keeps working:
```
$ compare.py --check-data            → rc=0   (data dir empty)
$ JSON_REQUIRE_DATA=1 compare.py checker corpus
0 passed, 0 failed, 0 total          → rc=0
```
Related problem: the globs also pick up unpinned files left over from an
older pin, and the results key does not cover them.

Fix:
- (a) `data_problem()` returns "the manifest lists no files" when
  `manifest()` is empty, or better, checks the count against the
  expected 153.
- (b) Build the checker and corpus groups from the manifest paths, not
  from globs.
- (c) In `main()`, fail when a selected group yields 0 cases and `--only`
  is empty.

The other paths are loud, as the round claims. In a scratch copy:
- No data: `SKIP checker: … is missing` and rc 3. With
  JSON_REQUIRE_DATA=1, `FAIL …` and rc 1.
- One file missing (`simdjson/recipe_book.json`): skipped, rc 3.
- One byte changed in `pass01.json`: `differs from its pinned sha256`,
  and rc 1 under REQUIRE.

## M3. A skipped group shows as a plain pass

On rc 3, `check_json` prints `note: json/<g> skipped (…)` to stderr and
returns 0. `worker` then writes `pass\tjson/checker\t` with an empty
reason. Results:
- `-v` lists `pass json/checker` with no note, but
  test/json/README.md:36 says the note appears "on the run's output and
  in `-v`".
- The final tally counts the group as passed.
- The only trace is one stderr line in the middle of a parallel run.

CI sets JSON_REQUIRE_DATA=1, so CI is safe. A local run without the data
is quiet unless you watch the scroll.

Fix: have `check_json` set a reason (for example `SKIPPED="skipped: …"`),
have `worker` write `pass\t$id\tskipped: …`, and print a count of skipped
groups in the summary line.

## L4. Getters on the wrong kind or index

Nothing in STD.md or the header says what happens. Results from runs
under the sanitizer:
- `[2.5, 0, "abc"]`: `get_float(2)` on the int `0` returns **2.5**
  (`floats[0]`), `get_int(3)` on the string returns **1342177283**, and
  `get_bool(1)` returns false. No error is raised.
- `[1000, …]`: `get_float(1)` panics `index out of bounds`.
- `[-5, "x"]`: `get_str(1)` panics `slice bounds out of range`, because
  a negative `e >> 31` gives a negative offset.
- `kind(i)` or any getter with `i >= size()` panics.

All of these are memory-safe. Fix: document the precondition (`0 <= i <
size()` and a matching `kind(i)`, otherwise an unspecified value or a
panic), or have each getter check its tag and panic with a clear message.

## L5. The `JSON` env var is not isolated from test/run's cache

compare.py swaps in `$JSON` as the parser (compare.py:448-450). The key
`check_json` records is computed from the `--stub` driver, which always
uses std.json. So `JSON=exp.rig ./test/run --delta json` records passes
under std.json's key, and a later `./test/run --delta` carries them over.
`JSON` is also a generic name that may already be set in someone's shell.

Fix: `check_json` runs compare.py with `env -u JSON`, or sets
`NO_CACHE=1` when `JSON` is set. Renaming the variable (for example
`RIG_JSON_EXPERIMENT`) would also help.

## L6. The CI cache includes a tracked file

The cache step uses `path: rig/test/json/data`, which includes the tracked
`README.md`, and the cache is keyed only by the fetch script's hash. When
README.md changes without a fetch-script change, the restore overwrites
the checked-out README with the old copy. No test reads it today, but
vocab and doc scans over Markdown could.

Fix: cache `rig/test/json/data/simd-json` and `rig/test/json/data/simdjson`
only.

Otherwise the key is right: `hashFiles` and the `path` are relative to
the workspace, and `defaults.run.working-directory` does not apply to
`uses` steps. Each run also re-verifies a restored cache, because the
fetch step re-hashes every file.

## L7. Docs

- std/json.rig:38-39 says DESIGN.md "Open items" lists every NEEDS, but
  "multiple results" (json.rig:590) and "an enum variant's name as text"
  (json.rig:119) are not listed there.
- Speed claims disagree:
  - DESIGN.md:59: "0.9-3.7 GB/s, 1.5-7x".
  - STD.md:532: "about 1 to 6 GB/s".
  - RESULTS.md's latest tables (632-, 662-): 2.0-7.2 GB/s.

  Pick one source and cite it.
- RESULTS.md:19-20 "Correctness" is stale. It says "10495 of 10495" and
  "110 with an exact error kind". The real counts are 10,511 inputs, and
  119 cases.txt lines with an exact error. My counts by group:
  - cases 181
  - scan 1298
  - edges 4192
  - blocks 3543
  - spaces 1053
  - floats 84
  - checker 132
  - deep 7
  - corpus 21

  The `--subset` part is 1,168 of them.
- STD.md:540 "a warm parse allocates nothing": no test checks it (rule 1).
  Either reword it ("each parse reuses the Doc's lists") or add a check.
- Limits are not documented. A string longer than 2^27-1 bytes, or an
  input over 4 GiB, is a `too_large` error (MAX_STRING, MAX_INPUT), so
  valid JSON is rejected. STD.md only names `too_large`. Document the
  limits. No test exercises `too_large`, which is acceptable given its
  cost, but say so.
- compare.py:429-430 is a slightly historical comment ("a constant and a
  call per case made the program … grow"). Rephrase it as the reason for
  the design.

## L8. Release mode is never exercised

The json groups run only under `rig run` in debug. The SIMD lowering
(`Simd[U8,16]` compares, `bits()`, `first()`) and the SWAR kernels differ
by optimize mode. `scan_exhaustive.rig` passes under `--release` too
(9.5 s). Suggestion: the deep gate runs `scan` and `blocks` once with
`--release`, or the probe becomes a behavior test with a `# release`
line.

## 4. The tiered scan, `skip_plain_ascii` (std/json.rig:649-674): correct

Argument. The invariant is `at <= i`, and no byte in `[at, i)` is special.
- **U64 phase.** In `special64` a borrow comes only from a true zero byte
  of `w^0x22` or `w^0x5C`, or from a byte below 0x20. A byte b ≥ 0x20 can
  only set a top bit when b ≥ 0xA0, and then `~w` masks it while `w`'s
  own top bit marks it anyway. So no false mark comes before the first
  true one, and `trailing_zeros >> 3` is exact. The loop guard
  `i + 8 <= len` keeps reads in bounds.
- **SIMD phase.** The guard `i + 16 <= len` keeps reads in bounds, and
  the U8 lane compares are unsigned.
- **Tail.** It runs only when `len-16 < i < len` (the SIMD loop exited
  and `i < len`). So the shift `i + 16 - len` is in 1..15. Shifted bit j
  is the byte at `len-16 + j + shift = i + j`. Every lane before `i` is
  dropped, which includes all lanes before `at`.
- **len < 16.** At most one U64 step, then the byte loop. `at == len`
  skips every loop and returns `len`. `at > len` returns `at`, but callers
  never pass it.

Exhaustive probe (`scan_exhaustive.rig`):
- **Starts:** `at` = 1..18, after 0 or 1 spaces and 0..8 `\"` escapes,
  so `\` and `"` sit before `at` inside the overlapping tail read. Also a
  start after `é`, and one after raw `\n\t\r` whitespace inside an array.
- **Body:** 0..130 plain bytes, drawn from the neighbours of the special
  bytes.
- **Stops:** a control byte, 0xFF, `\`, `"`, or none, with 0..33 bytes
  after the stop.
- **Checks:** the exact error kind and offset, or the decoded length.
- **Result:** 358,940 inputs and 0 mismatches, in debug with the
  sanitizer and in `--release`.

Coverage in compare.py:
- `blocks` tests the tail only with the stop on the input's last byte, or
  no stop at all. Its "mid-input" stops have 70 more bytes after them, so
  they are found in the SIMD loop.
- `scan` covers stops in middle lanes of the tail, but only the opening
  quote lies before `at`.
- Middle-lane tail stops with escapes or UTF-8 before `at` appear only
  incidentally, as the last element of the `edges` arrays.

The probe fills that gap. Its 7 s fits test/corpus.

## Other checks

- **Fetch script.**
  - Every file is pinned by a commit in its URL and by its sha256.
  - A download is written to `file.part`, which is removed on a hash
    mismatch.
  - `xargs` exits 123 on any failure, and `set -e` with `pipefail` turns
    that into a failing script.
  - Paths are constants, so there is no path traversal, and nothing
    downloaded is executed.
  - Pinned URLs and both repos' LICENSE-MIT and LICENSE-APACHE files
    answer HTTP 200 at the pinned commits.
  - The file counts in data/README.md (16, 78, 38, 17 and 4) match the
    manifest.
- **Default suite cost.** There are 9 `json/*` tests. Recorded durations
  are 0-6 s, and the subset is 1,168 inputs, about 5.4 MB. Nothing is
  slow or flaky.
- **Hand-tuned paths.** These are `unicode` with two 3-byte escapes and
  `push_utf8_two3`, `utf8_end3`, and `hex_value` with one U32 read. Each
  is explained in its comment and exercised: by twitterescaped (in the
  subset corpus), by `edges`, and by `cases`.
