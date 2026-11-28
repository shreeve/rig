# Duration layout benchmark

Times what a `Duration`'s layout costs at each call that gives or takes
one (the datetime design, §5.1): layout A, whole seconds (an `Int`) and
nanoseconds (an `I32`) of one sign, 16 bytes; layout B, one `Int` of
nanoseconds. It is not part of the test suite or CI.

Both are stand-ins written in Rig over `std.time`, whose readings they
take as an `Int` of nanoseconds (`t.elapsed().ns()`, `t.since(u).ns()`)
and whose waits they give one (`ns:` of `time.sleep`, `time.within`,
`time.after`), so each call converts there, as the scheduler is an `Int`
of nanoseconds underneath. A monotonic reading is one `Int` in both.

| Case | Each call |
|---|---|
| `elapsed()` | a clock read, made a duration: A divides by 10^9 for the seconds and keeps the rest |
| `since` | the difference of two readings, made a duration |
| `deadline add, compare` | a reading plus a duration (A: `s * 10^9 + ns`, which panics past an `Int`), compared with another reading |
| `sleep(0)` | `time.sleep` of a zero duration (A: its nanoseconds, as long as an `Int` holds and the largest past that) |
| `within, empty fun` | `time.within` of 5 s around a function that gives 0 |
| `select, after loses` | a send to a channel of one slot, then a `select` of its receive and `time.after` of 5 s, which loses |
| `select, after(0) wins` | a `select` whose one arm is `time.after` of zero, which wins at once |

Each loop runs in a `called` function. A duration passes through
`hint.opaque` at every call, so no conversion is moved out of the loop,
and what a call gives is kept with `hint.keep`, so it is computed.

```sh
D=$(mktemp -d)
bin/rig build --release bench/duration/duration.rig -o $D/duration
cpuq drain -c 2 -t 20m --label rig:duration -- $D/duration       # the Mac
taskset -c 6 $D/duration                   # pup, on a P-core, in a slot
$D/duration check                          # each loop at N and 2N: the ratio of their times
```

It prints, for each case, the nanoseconds a call for A and for B and
their difference, the fastest of 20 rounds, A and B in turns (B first in
odd rounds). `check` runs each loop at N calls and at 2N, the fastest of
5, and prints the ratio of their times, which is near 2 when every call
does its work.

## Results

The numbers, and how they were taken, are in
[docs/history/records/2026-11/datetime-phase0/bench.md](../../docs/history/records/2026-11/datetime-phase0/bench.md).
