# Integer-model scratch Rig: what the core suite shows (2026-11-24)

Rig - Final, for Rig and Trig. A measurement build only; nothing here lands.

Build: Rig main 394b422bf (the same `src` as Trig's pin b4d9e7247) with `patches/intmodel.patch`, built on
burst for Trig's PGO build and on the Mac for the suite; neither build is kept. The 104 changed bombs are
`data/changed-bombs.tsv`.

## The patch

**Emit:** emitted code takes Rust's release integer model. The runtime and the Zig shims keep `-Osafe`, so their
overflow traps stay.
- `+ - *` and negation wrap (`+%`, `-%`, `*%`), and so do `+= -= *=`.
- `<<` drops the bits it shifts out, as `<<%` does; the shift amount is still checked.
- An integer conversion `T(x)` truncates or sign-extends, as Rust's `as` does (`rig.asInt`).
- These stay as they are: bounds, slice and length checks, division by zero and `MIN / -1`, shift amounts, and
  `@Vector` lanes.

**Proofs:** three inferences in `src/proofs.zig` relied on an overflow trap to omit a bounds test, and are off in this
build:
1. `i += c` (and `i = i + c`) kept `0 <= i` (`isAdditive`). A wrapped add can make `i` negative, though only after
   about 2^63 steps.
2. `i = Int(u)` for an unsigned `u` gave `0 <= i` (`fromUnsigned`). A U64 above 2^63 truncates to a negative Int, and
   this is reachable. It now holds only for unsigned types narrower than 64 bits.
3. A guard `i + k < b` gave `below(i, k, b)` (`genGuard`). The guard's add may have wrapped. It now gives a bound only
   when `k = 0`.

With all three off, memory safety rests on bounds checks, as in Rust, and the build may make a few more bounds checks
than main.

**std:** std has no `raw` code, so wrapping in std can only give wrong values. It cannot reach memory unchecked.

## Core suite (Mac, `swarm test/rig.rip -w 4`): 82 died; then the bomb areas rerun alone

- **104 `bomb` cases** (debug and release variants) expect an overflow or conversion panic and now run on; listed in
  `data/changed-bombs.tsv`. By area: emit-inline-grid 26, emit-misc-1 22, emit-misc-2 15, proofs-misc 14,
  types-misc-1 4, runtime-panic-status 4, types-misc-2 3, probes-05 3, and 1–2 each in runtime-misc, probes-37,
  modules-misc, modules-imported, word-objects, probes-39, probes-11, probes-04 and concurrency-task.
- **Scripts that test traps:** `cli.build` (the debug overflow check), `cli.panic_status` (overflow exits 134),
  `cli.release_checks` (the release conversion check), `cli.actor_inline_room` ("no overflow found").
- **Emitted text:**
  - `code` cases: `types-slice` "slice prefetch emits" (now `i +% 4`), `ownership-write` "write view local writes
    through", and three `emit-inline-budget` cases that count `rig.addProven(` (fewer proofs).
  - `cli.emit_shapes`, `cli.inline` (`simdReadProven`) and `cli.facts_proofs` (the swar.rig proofs) differ.
- **Unit tests:** four of proofs.zig's own tests (G1, kills, joins, E1) fail, because they test the inferences above.
- **Behavior changes that are not traps:**
  - `cli.fault_signal` times out. Its infinite recursion `a[0] + dive(depth + 1, ?a)` no longer overflows the
    stack: with a wrapping `+`, LLVM keeps the sum as an accumulator and turns the recursion into a loop. That loop
    never ends: the script's timeout killed the script but left its `./dives-release` running, and two of them spun
    at 100% CPU for over an hour until I killed them by PID. Any future run of this build needs its own timeout on
    each process of that test, or should leave the test out.
  - `cli.preempt_cover` fails. An actor's computation, smaller without its overflow checks, is inlined into
    `rig.tasks.actorCall`, whose code declines preemption signals; a 20 ms sleeper woke after 52–63 ms. This could
    happen on main too to any small enough actor method. It is worth a look apart from this build.
  - `cli.markers` fails: a function main keeps is inlined in release. Code shape only.

## For the owner's Lean question

formal/ models unbounded `Int`s; its only "overflow" is the scheduler ring's spill (Models/Ring.lean says its counters
do not wrap). No proof there rests on an arithmetic trap. The trap reliance is in src/proofs.zig (the three
inferences above), which formal/ does not model.
