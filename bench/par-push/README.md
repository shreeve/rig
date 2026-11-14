# par.push benchmark

`fill.rig` times `par.push` (SPEC §18, "Each element on several
tasks") against a serial loop of `!t.push(x)`, on a fill shaped like
Trig's `Ids.of`: 3,595,543 records of 32 bytes (115 MB), in 12,500
runs of uneven sizes (most 20 to 400 records, one in forty 1,500 to
5,000), each record a function of its run's source ids, the run's
index and its base.

```sh
tools/heavy bin/rig build --release bench/par-push/fill.rig -o /tmp/fill
tools/mac-claim parpush tools/low /tmp/fill
```

| Form | How the records reach the table |
|---|---|
| `serial` | `!t.push(record(...))` for each record, run by run, in order |
| `push N` | `par.push(!t, ?sizes, limit: N, \|run, k\| ...)`: run `k` written by one of `N` tasks |

Each rep makes a fresh `Table[Sym, 4194304]`, a reserved table whose
pages are first touched by the fill, and times the fill and a sampled
checksum. The forms run interleaved, 15 reps each, and the fastest
counts. Each prints `NAME MS CHECK`; the checks agree.

## Results

| Machine | serial | push 1 | push 2 | push 4 | push 8 |
|---|---|---|---|---|---|
| Mac (arm64, 10 cores), 2026-11-13 | 11.14 ms | 10.26 ms | 8.25 ms | 7.39 ms | 9.37 ms |

The fastest of three runs of the program under `tools/mac-claim`, each
the fastest of its 15 reps; the three runs agree within 3%. At four
tasks the fill is 1.51 times as fast as the serial loop, and at eight
slower than at four: the fill is bound by memory and by page faults,
which scale to the Mac's four performance cores, as a C program of the
same fill found (1.9 times as fast at four threads on fresh pages, and
slower past them). `push 1` beats the serial loop by 8%: it
writes each record in place with no test of the table's room per
record.
