# Release builds without stack canaries (queue row 51)

Decision note for the owner, Rig - Rust, 2026-11-01. Found by the parse
pass 2 agent (trig#236's report, Trig NEEDS 69).

## What happens now

`rig build --release` passes Zig `-Osafe -fomit-frame-pointer` and nothing
about the stack protector, so Zig's default applies: canaries on, whenever
libc is linked. Every macOS program links libc, so every Mac release build
has them; on Linux only programs that link libc do (loco does, Trig does
not). Trig on the Mac: 3,253 functions check a canary, 52 of the 54 hottest
parse functions among them; pup's Trig has none.

A canary catches a write past a stack buffer. Safe Rig cannot make one:
every index and slice is checked, or proven by `src/proofs.zig`. So a canary
guards only `raw` code and the Zig of the runtime and std shims. It is
hardening, not part of Rig's safety guarantee (North Star 2). Rust does not
use canaries by default either; tsrs has none.

## Numbers (the Mac, 2026-11-01 10:29-10:5x)

Trig `dd43341` emitted once by Rig `ad5d9b043`, then compiled three ways
with the same flags `rig build --release` uses (its `.text` identical to the
`rig build` binary's): canaries on (`on`), a second build of the same (`on2`,
the A/A, `.text` identical), and `-fno-stack-protector` (`off`). 11 rounds
interleaved, twice in the two orders, fewest of each; load about 2.

| project | instructions, off vs on | cycles, off vs on (two runs) | A/A cycles |
|---|---|---|---|
| empty | 6.4% fewer | 2.6% / 2.6% fewer | 0.6% / 1.2% |
| mitt | 6.2% fewer | 4.5% / 4.1% fewer | 1.0% / 0.7% |
| neverthrow | 6.3% fewer | 3.6% / 2.5% fewer | 0.5% / 0.9% |
| zod3 | 6.7% fewer | 2.7% / 2.7% fewer | 1.1% / 0.5% |
| ts-pattern | 7.0% fewer | 2.9% / 3.5% fewer | 0.3% / 0.4% |

Peak RSS 0.1 MB lower; footprint level; output identical. Raw:
scratchpad `ssp/mac-ab.txt`.

## Decisions (defaults)

1. Release builds (`--release`, safe and fast) pass `-fno-stack-protector`.
   Debug builds keep canaries. Default: yes.
2. `RIG_STACK_PROTECTOR=1` keeps them in a release build, as
   `RIG_FRAME_POINTERS=1` keeps frame pointers. Default: yes.
3. The change goes through the full gates (both light gates, json and hash
   guards, which should move only on the Mac). Default: yes.
