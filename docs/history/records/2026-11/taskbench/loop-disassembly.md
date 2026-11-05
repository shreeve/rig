# Why Rig's CPU loop is 25-32% slower: the two extra adds (2026-11-05)

`even`, `skew` and `tree` spend their time in `spin`, the same loop in all four programs:

```rig
fun spin(n: Int) -> Int
  total = 0
  for i in 0..n
    total = (total + i * 7) % 1000003
  total
```

On the Mac at one worker, Rig takes 898M cycles for `even` against Go's 707M, about 27% more, while running fewer instructions (975M against 1.10G). The cost is latency, not work. This is the arm64 code of both loops (Apple M5, `otool -tV`). Rig's comes from main 39e1ed89f, `--release=fast`; Rust's from bench/tasks/rayon, `cargo build --release`.

## What Rig emits

```zig
var __rig_turns_4: u32 = rig.tick_turns;          // 1024
var __rig_i_5: i64 = 0;
const __rig_end_5: i64 = n;
while (__rig_i_5 < __rig_end_5) : ({ rig.turn(&__rig_turns_4); __rig_i_5 += 1; }) {
    const i = __rig_i_5;
    total = rig.rem(total + (i * 7), 1000003);
}
```

`rig.turn` (src/runtime.zig) counts down. At zero it resets the count and calls the scheduler's tick through `callKeeping`.

## Rig's loop (arm64)

```
eb50  mov   x13, x14              ; total
eb54  subs  w11, w11, #0x1        ; the yield countdown
eb58  b.eq  eb90                  ;   every 1,024 turns: call tickC, then back to eb5c
eb5c  add   x14, x13, x9          ; total + 7i            <- the chain starts
eb60  umulh x15, x14, x12         ; divide by 1000003, by multiplying
eb64  sub   x14, x14, x15
eb68  add   x14, x15, x14, lsr #1
eb6c  lsr   x14, x14, #19         ; the quotient q
eb70  msub  x14, x14, x10, x13    ; total - q * 1000003    (from total, not total + 7i)
eb74  add   x14, x8, x14          ; + (7i - 7)             <- extra
eb78  add   x14, x14, #0x7        ; + 7                    <- extra
eb7c  add   x8, x8, #0x7
eb80  add   x9, x9, #0x7
eb84  subs  x20, x20, #0x1
eb88  b.ne  eb50
```

## Rust's loop (arm64), the same source

```
33c0  add   x12, x0, x9           ; total + 7i            <- the chain starts
33c4  smulh x13, x12, x10         ; divide by 1000003, by multiplying
33c8  add   x13, x13, x12
33cc  asr   x14, x13, #19
33d0  add   x13, x14, x13, lsr #63  ; the quotient q
33d4  msub  x0, x13, x11, x12     ; (total + 7i) - q * 1000003
33d8  add   x9, x9, #0x7
33dc  subs  x8, x8, #0x1
33e0  b.ne  33c0
```

## The difference

Each turn waits on the one before it through `total`.
- Rust's chain is six steps: add, multiply-high, add, shift, add, multiply-subtract.
- Rig's is eight. LLVM takes the remainder from `total`, not from `total + 7i`, and adds `7i` back afterwards in two steps (`eb74`, `eb78`), with a second copy of the induction value (`x8`, offset by 7 from `x9`).

That is about 13 cycles a turn against Rust's 10, close to the 27% measured. Go's loop is the same length as Rust's (707M cycles).

The countdown itself (`eb54`) is a chain of its own and costs almost nothing. The cost is the loop's shape. The check's branch splits the loop in the middle, so LLVM rotates it with two induction values and reassociates the remainder.

## The fix in the plan

Strip-mine counted loops (concurrency plan, step 3, after #952): an inner loop of up to 1,024 turns with no check in it, then one check, as HotSpot does. The inner loop is then the plain loop Rust and Go compile, and a task still yields every 1,024 turns.

With `RIG_PREEMPT=signal` (#952) the checks are gone entirely, so strip-mining matters for default builds, and on the Mac until preemption is ported there. Measure both when it is built.
