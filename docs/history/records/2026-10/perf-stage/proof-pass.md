# More proven indexes and length adds, measured before building (2026-10-31)

**Question** (the beat-tsrs list, items 2 and 3, bundled): would the proof
pass, taught four more index shapes and the add of one to a length, make
Trig clear its bar (more than 1.5% faster, or at least 1% fewer
instructions, peak RSS no higher)? Measured first, as a hand ceiling on
Trig's emitted Zig; nothing built. Scripts and raw output are in
[proof-pass-data/](proof-pass-data/).

**Answer: no.** Every check the bundle would remove, taken out by hand,
leaves Trig with 0.61-0.64% fewer instructions on ts-pattern and
0.16-0.23% on zod3, and its cycles where they were (within the noise of
either sign). The length adds are 0.08-0.16% and 0.09-0.12% of that.
Adding every `+= 1` counter as well, which is the owner's call and not
part of the bundle, reaches 0.95-1.03% and 0.44-0.48% fewer
instructions, still with no time gained. The work stops here, as the
list's rule says; codegen-gap §5 predicted 0.8% and 0.4%, and
[proofs.md](proofs.md) and [trig-zig-ceiling.md](trig-zig-ceiling.md)
found the same of the false edges and the loop proofs: a bounds test
that never fails is a compare and a branch the core predicts and runs
beside the load it guards.

## What the bundle would prove

What main proves today of each shape ([shapes.rig](proof-pass-data/shapes.rig),
`rig check --facts=proofs`, [shapes-proven.txt](proof-pass-data/shapes-proven.txt)):

| shape | main proves | the new rule |
|---|---|---|
| a countdown, `i = s.len; while i > 0: i -= 1; s[i]` (Trig's `find_active_mapper`) | neither side | a loop that only lowers `i` keeps `below(i, k, b)`; `0 < i` gives `i >= 1`, so `i -= 1` keeps `0 <= i` |
| an index one below a guarded one, `while j > 0 and xs[j] < xs[j - 1]` (std.sort's insertion) | `xs[j]` lower only; `xs[j - 1]` and the swap neither | the same, and `s[i - c]` under `i >= c` and `below(i, k, len(s))` |
| a loop's exit edge, `while s.len <= p: !s.push(...)`, then `s[p]` (Trig's `conditional_flow_step`) | lower only | after a loop with no `break`, its guard is false |
| an index just compared to len, `return 0 if i < 0 or i >= s.len`, then `s[i]` | neither side | the false edge (built in #687, closed: 111 more proofs on Trig, no time) |
| `i + 1` where `i < s.len` | already proven | — |
| an index kept valid by push, `n = s.len; !s.push(v); s[n]` | lower only | `push` only lengthens: `below(i, k, len(s))` survives it, and `n = s.len` before it gives `below(n, 1, len(s))` after |
| a literal plus a length, `1 + s.len` | not proven | `fits(s)` (a length is at most `2^62 - 1`) |
| a Map's or Set's `@len += 1` | not proven (a field, not a binding) | std: `@len` counts its table's entries |

## Method

- **Builds.** Rig main `fe531a8f4`, Trig `aa3994b` (`src/` and
  `tools/trig/main.rig` by `git archive`, the root copied into `src/` as
  `tools/trig/pgo` does). `rig build --release` wrote the package once;
  each arm is that package, edited by [ceil.py](proof-pass-data/ceil.py),
  and built by `zig build-exe -Osafe -fomit-frame-pointer`
  ([arm.sh](proof-pass-data/arm.sh)), as `rig build --release` builds
  it, `base` unedited by the same command. No environment-switched arm.
  - `ceil`, the bundle: `find_active_mapper`'s `active_mappers.at(i)`
    proven both sides; std.sort's `xs[j]`, `xs[j - 1]` and
    `swap(j, j - 1)` proven both sides; `conditional_flow_steps[p]`
    proven both sides (2 sites); every `c + rig.lenOf(...)` and
    `rig.lenOf(...) + c` with a literal `c` an add that does not test
    (18 sites); the prelude's ten `self.len += 1`, untested. These are
    the hot sites codegen-gap §5 sampled (its "proof" class, less the
    `ends` and `bytes` reads of `Interner.text`, which no rule here
    reaches: their bounds are data the program keeps, not facts it
    tested), plus every length add in the program. Cold sites the new
    rules would also reach were not edited; §5's samples put nearly
    nothing there.
  - `len`: only the length adds of `ceil` (item 3 alone).
  - `ceilc`: `ceil` with every `+= 1` untested (1,343 sites), to
    measure what counters add; not part of the bundle.
- **Timing** ([bench.py](proof-pass-data/bench.py)): the Mac (arm64),
  20 rounds, every arm once a round, the first arm rotated each round,
  ts-pattern then zod3, one checker; user and kernel cycles and
  instructions retired from `/usr/bin/time -l`, at `nice 19`, with
  other sessions' builds running (load 4-10). Every run of every arm
  printed `base`'s output and exit status. Two rounds; the second added
  `len`.

## Numbers

Round 2 ([times-2.txt](proof-pass-data/times-2.txt)), against `base`,
fastest and median of 20:

| arm | ts-pattern instructions | ts-pattern cycles | zod3 instructions | zod3 cycles | peak RSS |
|---|---|---|---|---|---|
| `len` | 0.16% / 0.08% fewer | 0.69% more / 0.06% fewer | 0.09% / 0.12% fewer | 0.54% more / 0.49% fewer | the same |
| `ceil` | **0.63% / 0.61% fewer** | 0.03% more / 0.12% fewer | **0.20% / 0.20% fewer** | 0.29% more / 0.36% fewer | the same |
| `ceilc` | 1.01% / 0.95% fewer | 0.12% more / 0.75% fewer | 0.45% / 0.44% fewer | 0.03% / 0.19% fewer | the same |

Round 1 ([times-1.txt](proof-pass-data/times-1.txt), heavier load):
`ceil` 0.64% fewer instructions on ts-pattern and 0.16-0.23% on zod3,
`ceilc` 1.02-1.03% and 0.45-0.48%; cycles from 1.1% more to 0.9% fewer,
noise. Peak RSS 273.2 MB and 84.2 MB in every arm.

- **The bundle is a third of the instruction bar on zod3 and under
  two thirds of it on ts-pattern**, and moves no time.
- **Item 3, how much of `+= 1` is lengths:** codegen-gap measured `+= 1`
  on counters and lengths at 0.64% and 0.46% of instructions (each test
  counted with its add); the lengths are 0.08-0.16% and 0.09-0.12%
  (`len`), about a fifth; the counters 0.34-0.38% and 0.24-0.25%
  (`ceilc` less `ceil`). An overflow test is one instruction, a branch
  on the flags the add already sets, so removing it saves about half of
  what codegen-gap's count charged to it.
- Mac only: pup was not asked for, since the ceiling misses the bar by
  instructions, which do not depend on the machine's load, and cycles
  showed nothing to confirm.

## What is left

- The counter rule (a counter stepped by a constant cannot reach `2^63`
  in a run) is still the owner's, and alone is 0.3-0.4% of
  instructions on Trig: under the bar with the bundle too.
- The proofs worth writing remain the ones a language change makes
  reachable: ids read from memory (item 1, typed table ids), 3.1% and
  4.7% of instructions.
