# Inline small, only-called functions

The compiler decides, with no syntax. A `fun`/`sub`/method is emitted `pub inline fn` when its body has <= 60 IR nodes, it is on no call cycle, every mention is a call's callee, it is not root `main`, has no compile-time params, is not in a generic type, holds no closure, and the inlined frames/expansion it joins stay bounded (64 KiB added frame; <= 320 expanded nodes). Decided once program-wide (`src/inlining.zig`, read as `Facts.isInlined`). A size rule measures each body as written, so a small entry calling a large function inlines and the large one stays out of line.

## The hazard, with evidence
Zig's `inline fn` and `@call(.always_inline, ...)` both inline semantically (probed: both give "called inline here"). A literal argument becomes comptime inside, so `a + 1` called with 255 as U8 / maxInt Int is a compile error instead of a run-time panic (reproduced on the emitted package), also for out-of-bounds and divide-by-zero, even at unexecuted calls. No Zig attribute keeps run-time semantics. Fix: every parameter of an inlined fn is bound through the existing `rig.rt` (`const n = rig.rt(__rig_in_n)`), which the optimizer folds away. Probed in debug and ReleaseSafe: panics stay run-time. Tests with literal args, in debug and --release, and unreached literal calls.

Found by the suite: inlining sums frames (value_size_limit segfaulted). Fixed as a class: frame budget above, tied to `typecheck.checkFrames`.

## Gates
Suite, corpus (10032), matrix (7140 programs, 0 failed), unit, equiv: green. Emit diff over 4803 emitting programs (3111 differ): exactly three categories, 0 other: `pub fn` -> `pub inline fn` with params renamed `__rig_in_x`; added `const|var x = rig.rt(__rig_in_x)`; owned param copy `var t = rt(__rig_arg_N)`.

## Measure (Trig JSON, scratch clone, loaded machine, fastest of 30 interleaved, spreads up to 4x)
MB/s, before -> after (max=0 vs default):
- rig-safe: github 2350 -> 2658 (+13%), citm 2202 -> 2301 (+4.5%), gsoc 3709 -> 4122 (+11%), twitter 1916 -> 2084 (+8.8%)
- rig-fast: github +13.8%, citm +13.4%, gsoc +1.8%, twitter +29.7%
Threshold: 35 gains little (misses string/key); 100 no better than 60. Compile time (citm, release/debug) within noise; binary +0.7% / +0.35%.
Caveat: noise is large; the sign is consistent across all 8 cells, the magnitudes are not.
