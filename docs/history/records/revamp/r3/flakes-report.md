# Test flakes (PR #300)
Data: cpuq's 54 FAILs (36 h to 10-17 01:31).
- ln: suite.json now `ln -sfn` (3 jobs "Already exists"). Also cause of the curl x69 job (e75c1f5b): dangling link made every `mkdir -p` fail ("Already exists"), so curl could not write. fetch-json-data.sh now replaces a dangling link with a directory.
- JSON_REQUIRE_DATA (14 FAILs, 7 jobs, all 37 h ago): predate the json-data cache (643d3624e); no repeat since. No download needed.
- Timeouts: all 120 s results_cache/no_crash_report failures predate their `# timeout:` lines (10-16 03:45, 08:56). Harness honors it for behavior|examples|known|cli (test/run worker). results_cache raised 300 -> 600.
- Runner died (6 jobs): `test/run: line 157: listing: unbound variable` (set -u, emit rejects the program); fixed in 927e9ac22 before this work. Workers now trap EXIT and record "exited with status N before recording a result (last log line ...)"; the driver's fallback message names SIGKILL/OOM.
- test_prune "kept the oldest builds over the cap" (2 jobs, 10-16 ~20:00): predates d2ba2ffd8 (wait for du to see the store). No repeat since; not changed further.
- Not setup/load (real code or in-flight branches): oracle UNLISTED, reject/*, style, classify, cli/markers, name_grid, lsp, strict_optionals, unit, stack_overflow_recursion --release (139 vs 134 on Linux, 2 jobs, 3 h ago: possibly real, report to owner), no_crash_report Linux core-limit (de04847a, a1c98229, pre-fix).
Verification: burst submit of cli/test_prune, results_cache, no_crash_report, markers, enum_order_shorthand, doc/CORE: PASS. Injected unbound variable shows the new message. tools/gate (needed --allow-gate-changes since cpuq/suite.json changed): suite, corpus, matrix PASS.
