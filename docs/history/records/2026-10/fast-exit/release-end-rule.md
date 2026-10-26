# A release build's end of `main`: measured, not taken (2026-10-25)

The owner chose "Both, memory-only" for how a program ends without its
teardown: `os.exit(code)`, and a rule that a release build's end of
`main` drops only what runs a `drop` body, then ends the process at once
(`exit_group`, `_exit`), leaving the rest of its memory, heaps, and
scheduler threads to the operating system. Both were built in #680. On
the measurement below the owner kept `os.exit` and dropped the rule.

## What was built

`sema.dropOnlyFrees` (a walk like `dropRunsBody`'s, followed into other
modules; a task, an owned closure, an API object, or an error counted as
running a body) marked each binding of `main`'s body whose drop only
frees memory (`Symbol.flags.freed_by_end`, set by the storage plan), and
emit gated its guard as `defer if (rig.drops_memory_at_end) rig.drop(&x);`,
true in debug builds (and `RIG_MAP_TRACE` ones). `rig.runMain` ended the
process on `main`'s stack once `finish` had flushed. Tests showed every
`drop` body still running in release (in a List, a Map, a box, behind
the last count of a `*T`), Ctrl-C and task waits unchanged, the suite
green, and Trig's light gate green.

## Measured on pup (ts-pattern, release)

Trig drops its program and checker stores inside `perform_compilation`
and `emit_files_and_report_errors` (strace -k: the ~170 munmaps of its
teardown come from those functions' drops), before `main` ends, so the
rule reached almost nothing.

| build | 1 checker, core 6: user instructions; user+kernel cycles | 20 checkers: wall, fastest of 20 |
|---|---|---|
| Rig main | 11.290G; 5.312G | 460 ms |
| the main-end rule alone | 11.286G (0.03% fewer); 5.290G (about 5 ms, noise) | 472 ms (noise) |
| scratch Trig calling `os.exit` after printing, in `perform_compilation` | 11.127G (1.4% fewer); 5.216G, about 22 ms saved | 445 ms (within noise) |

The kernel still frees the pages at `exit_group` (kernel cycles only 2%
lower), so what an early end saves is the user-side freeing. Wall time
on a loaded pup moved within about 4% noise. bench/tasks (rig-fast,
interleaved, Mac and pup) was unchanged within noise.

For a rule at `main`'s end to help Trig, Trig would first return its
stores to `main`; `os.exit` after printing reaches the same saving
without any rule.
