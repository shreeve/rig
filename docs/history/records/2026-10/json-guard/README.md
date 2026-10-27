# std.json's instruction guard on main (2026-10-26)

`bench/json/guard.py` failed on main (ad3a8ea52) against its own
compiler: rig-safe ran 2.9% more instructions per byte on twitter and
twitterescaped and 3.1% more on github_events than `guard.txt`, which was
last set at 6c7ea329f (#619). `std/json.rig` has not changed since, so
the rise is the compiler's or the runtime's. Refreshing the baseline
would have hidden a std.json slowdown, so the guard was left as it was,
and the rise was bisected.

## Method

Each probe is a `rig` built at the commit by `tools/baseline SHA`, with
the guard's own measurement against it (`RIG=... bench-json
--build-only --variants rig-safe`, then instructions retired per byte from
`/usr/bin/time -l`, the median of 5, N parses minus 1 over about 60 MB),
on the Mac. The JSON source is the worktree's `std/json.rig`, the same
at every probe. The counts repeat within 0.1% at one commit.

## The bisect

Instructions retired per byte, rig-safe:

| Commit | twitter | twitterescaped | github_events |
|---|---|---|---|
| 22ad2233a (#619, guard set) | 7.9284 | 9.4214 | 7.0537 |
| d377a2bac (#661) | 7.9289 | 9.4215 | 7.0531 |
| a4806b8b7 (#642) | 7.9323 | 9.4235 | 7.0537 |
| bfcef57ee (#681) | 7.9293 | 9.4229 | 7.0540 |
| d6f6cb08c (#677) | 7.9318 | 9.4276 | 7.0538 |
| b77ffb199 (#680) | 7.9322 | 9.4241 | 7.0555 |
| d469abad1 (#682) | 7.8755 | 9.3676 | 7.0089 |
| dcf3c146d (#692) | 7.8777 | 9.3659 | 7.0083 |
| 57b0360fe (#695) | 7.8774 | 9.3681 | 7.0099 |
| **91802aaf5 (#696)** | **8.1657** | **9.6990** | **7.2748** |
| ad3a8ea52 (main) | 8.1654 | 9.6984 | 7.2743 |

#682 (frame pointers off in release) took 0.6-0.7% off. #696 (table
reads) added 3.7% on twitter, 3.5% on twitterescaped and 3.8% on
github_events over its parent on main. Nothing after it moved the counts.

Inside #696's branch (based on a06053e58):

| Commit | twitter | twitterescaped | github_events |
|---|---|---|---|
| a06053e58 (base) | 7.9306 | 9.4219 | 7.0529 |
| 94b018d7c runtime: rt and copiedOut keep an optional in registers | 7.9301 | 9.4219 | 7.0540 |
| **22bf02111 runtime: one unsigned compare tests a signed index against a held length** | **8.2152** | **9.7552** | **7.3212** |
| bdf86715a emit: an inlined call's optional or fallible result stays a run-time value | 8.2136 | 9.7585 | 7.3213 |
| 95bbd637a emit: a rarely function is noinline | 8.2157 | 9.7535 | 7.3204 |

**22bf02111 is responsible:** 3.6% more instructions per byte on
twitter, 3.5% on twitterescaped, 3.8% on github_events. It routes
`rig.at`, `rig.elemPtr` and a List's `indexOf` through `heldIndex` (a
signed index bit-cast to `u64` and compared once against the length) in
place of `index`, and `List.get` likewise. The other three commits of
#696 do not move std.json's counts.

## Time

On the Mac (`.mac-quiet` absent, load 1.7-2.2), twitter, rig-safe,
fastest of 10 interleaved runs each, under `tools/low`, 22bf02111
against its parent 94b018d7c:

| Parses a run | Parent | 22bf02111 | Difference |
|---|---|---|---|
| 1000 | 0.1767 s | 0.1831 s | 3.6% slower |
| 5000 | 0.8726 s | 0.8899 s | 2.0% slower |
| 5000 | 0.8707 s | 0.9072 s | 4.2% slower |

## What it means

#696's record ([perf-stage/table-reads.md](../perf-stage/table-reads.md))
measured the single compare on Trig, where it took instructions off. On
std.json's string and number scans it adds them and costs about 2-4% of
twitter's time. The owner's rule is that std.json only gets faster, so
`guard.txt` stays at 6c7ea329f's values until 22bf02111's cost to
std.json is removed or the owner accepts it.
