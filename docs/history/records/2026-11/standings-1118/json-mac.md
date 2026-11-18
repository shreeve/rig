# std.json against the fastest JSON parsers, the Mac (2026-11-18)

- **Rig:** origin/main **a303f69fd** (fetched 15:09; "Merge pull request #1077 from shreeve/string-of-text"), in a detached worktree. std.json is `rig-safe` (`rig build --release`, Zig's safe mode, every check kept), built by `bench/json/bench-json --build-only`.
- **Machine:** Apple M5, macOS (Darwin 27.2.0), Zig 0.17.0, Apple clang 21.0.0, rustc 1.99.1, Go 1.27.3.
- **Competitors:** yyjson 0.10.0 and simdjson 3.10.1 DOM (`bench/json/cbench`, `-O3 -mcpu=native`); sonic-rs 0.5.10 (`Value`), simd-json 0.18.1 (tape) and serde_json 1.0.151 (`Value`), `-C target-cpu=native` (`bench/json/rust-bench/build.sh native`); Go's `encoding/json/v2` into an `any` (`bench/json/gobench`).
- **Harness:** `bench/json/timers/time.py`'s method (calibrated to about 400 ms a run, the same interleaved order), with every sample kept so the median can be given too. Two claims under `tools/mac-claim`, 25 rounds each, 50 rounds in all. MB = 10^6 bytes.
- **Data:** `tools/fetch-json-data.sh` (153 files verified by sha256).


### MB/s, fastest of 50 interleaved rounds

| file | bytes | std.json | yyjson | simdjson DOM | sonic-rs | simd-json (tape) | serde_json | Go json/v2 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 631,514 | 4632 | 5204 | 4495 | 3281 | 3613 | 657 | 433 |
| twitterescaped | 562,408 | 3795 | 4067 | 1759 | 2812 | 1618 | 549 | 317 |
| canada | 2,251,051 | 2248 | 2141 | 1742 | 1957 | 1601 | 674 | 265 |
| citm_catalog | 1,727,204 | 5865 | 5549 | 5208 | 4141 | 3922 | 1020 | 608 |
| gsoc-2018 | 3,327,831 | 8210 | 4794 | 5434 | 7506 | 4200 | 1866 | 898 |
| github_events | 65,132 | 5258 | 5338 | 4818 | 4028 | 3832 | 847 | 587 |
| geomean | | 4642 | 4313 | 3512 | 3623 | 2897 | 856 | 476 |

| file | std.json vs yyjson | best competitor | std.json vs best |
|---|---|---|---|
| twitter | 11.0% slower | yyjson (5204) | 11.0% slower |
| twitterescaped | 6.7% slower | yyjson (4067) | 6.7% slower |
| canada | 5.0% faster | yyjson (2141) | 5.0% faster |
| citm_catalog | 5.7% faster | yyjson (5549) | 5.7% faster |
| gsoc-2018 | 71.3% faster | sonic-rs (7506) | 9.4% faster |
| github_events | 1.5% slower | yyjson (5338) | 1.5% slower |
| geomean | 7.6% faster | per-file best (4647) | 0.1% slower |

### MB/s, median of 50 interleaved rounds

| file | bytes | std.json | yyjson | simdjson DOM | sonic-rs | simd-json (tape) | serde_json | Go json/v2 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 631,514 | 4532 | 5110 | 4440 | 3235 | 3563 | 647 | 421 |
| twitterescaped | 562,408 | 3756 | 4000 | 1726 | 2758 | 1584 | 541 | 308 |
| canada | 2,251,051 | 2211 | 2105 | 1719 | 1925 | 1557 | 665 | 254 |
| citm_catalog | 1,727,204 | 5788 | 5465 | 5137 | 4053 | 3818 | 992 | 586 |
| gsoc-2018 | 3,327,831 | 8130 | 4682 | 5401 | 7385 | 4116 | 1840 | 868 |
| github_events | 65,132 | 5196 | 5251 | 4762 | 3953 | 3775 | 832 | 574 |
| geomean | | 4578 | 4236 | 3468 | 3559 | 2837 | 841 | 461 |

| file | std.json vs yyjson | best competitor | std.json vs best |
|---|---|---|---|
| twitter | 11.3% slower | yyjson (5110) | 11.3% slower |
| twitterescaped | 6.1% slower | yyjson (4000) | 6.1% slower |
| canada | 5.1% faster | yyjson (2105) | 5.1% faster |
| citm_catalog | 5.9% faster | yyjson (5465) | 5.9% faster |
| gsoc-2018 | 73.6% faster | sonic-rs (7385) | 10.1% faster |
| github_events | 1.0% slower | yyjson (5251) | 1.0% slower |
| geomean | 8.1% faster | per-file best (4571) | 0.2% faster |

### Per-claim fastest (MB/s), std.json / yyjson

| file | claim 1 | claim 2 |
|---|---|---|
| twitter | 4632 / 5204 | 4605 / 5170 |
| twitterescaped | 3795 / 4067 | 3780 / 4042 |
| canada | 2248 / 2141 | 2238 / 2126 |
| citm_catalog | 5852 / 5549 | 5865 / 5522 |
| gsoc-2018 | 8210 / 4794 | 8168 / 4777 |
| github_events | 5253 / 5338 | 5258 / 5316 |

Median below fastest, worst row: 4.0%

The two claims agree within 1% on every std.json and yyjson cell, fastest and median alike.

## Against earlier standings (std.json, fastest, MB/s)

| file | 2026-11-05 (cf6a362a6, 15 rounds) | 2026-11-07 (#1003's branch, 30 rounds) | today (a303f69fd, 50 rounds) | today vs 11-07 | yyjson 11-07 / today |
|---|---:|---:|---:|---|---:|
| twitter | 3683 | 4540 | 4632 | 2.0% faster | 5213 / 5204 |
| twitterescaped | 3222 | 3782 | 3795 | level (0.3%) | 4083 / 4067 |
| canada | 2079 | 2168 | 2248 | 3.7% faster | 2149 / 2141 |
| citm_catalog | 4238 | 5804 | 5865 | 1.1% faster | 5544 / 5549 |
| gsoc-2018 | 7254 | 8086 | 8210 | 1.5% faster | 4785 / 4794 |
| github_events | 4243 | 5257 | 5258 | level | 5347 / 5338 |
| geomean | 3842 | 4576 | 4642 | 1.4% faster | |

- yyjson reads within 0.4% of its 2026-11-07 numbers on every file, so the Mac measures as it did then.
- Against yyjson by geomean: 11% slower on 2026-11-05, 7.6% faster today. Per file, the gaps that remain have narrowed since 11-07: twitter 13% to 11% slower, twitterescaped 7% to 6.7%, github_events 2% to 1.5%.
- Against the best competitor per file (yyjson on five files, sonic-rs on gsoc-2018), std.json is level by geomean (0.1% slower fastest-of-50, 0.2% faster by median).

## Load notes

- **Claim 1** (json-board-b1), 15:21:40-15:27:24. It queued behind the Rayon board's claim (rayon-board-3, started 15:19), then mac-claim's quiet check passed. Load average at start 4.32 / 3.38 / 3.10, at end 3.24. Busy at start: WindowServer 48%, Claude renderer 12%, Chrome 8-9%; a moment later `duetexpertd` (a macOS daemon) at 98% of a core, gone by the 15:22 sample. A clang build outside the claim showed at 15:27:01 (57% and 52%), one 20-second sample, the claim's last seconds.
- **Claim 2** (json-board-b2), 15:29:41-15:36:05. Load average at start 2.42 / 2.87 / 2.98; total CPU of every process 108% of a core; WindowServer 46%, Claude renderer 38%, claude CLI 18%. Quiet until 15:34, then other work started outside the claim: `swift-test`, `duetexpertd` (94%), XprotectService, BackgroundShortcutRunner and siriactionsd, then `layout_test` (100%) and `rt_test` (94%); load average peaked at 11.9 (15:34:42) and was 6.8 at the end. That covers about the last 6 of its 25 rounds. Its fastest cells match claim 1 within 0.6%, and the median tables come out within 1% of claim 1's alone, so the noise moved no conclusion.
- `~/Data/Code/mumps-compare/.mac-quiet` was absent throughout. Every build (bin/rig, the six rig-safe programs, cbench, rust-bench, gobench) went through `tools/heavy`.

## Raw data

Samples (ns a parse, every round) in raw/json-mac/ (scripts in scripts/mac/) beside this file: b1.json, b2.json; load samples every 20 s in busy.txt, claim-start snapshots in load.txt; samples.py and report.py made these tables.
