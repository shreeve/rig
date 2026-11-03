# Trig's load phase at four checkers, by task timestamps (Mac, 2026-11-01)

Trig main 07e4447, built --release by Rig main 43e1f65f4 with `@@` prints (time.since_start, µs) in fileloader.rig, program.rig (bind), checkerpool.rig (checkers). Three runs each of zod3, mitt and ts-pattern at --checkers 4; run 1 of each is cold. Summary: [load-phase-data/summary.txt](load-phase-data/summary.txt), made by `sum.py` there; the raw `*-4-N.txt` runs are on pup in `/zfs/trig-pup/records-data/loader-ts/`.

Warm runs, ms from process start:

| | zod3 | ts-pattern | mitt |
|---|---|---|---|
| spawning 105 lib tasks | 1.1-1.3 to 1.7-2.1 | 1.0 to 1.7 | 0.5 to 1.1-1.7 |
| lib.dom: spawn to start | 0.24-0.32 | 0.32-0.35 | 0.28-0.34 |
| lib.dom parse | 4.3-4.4 | 4.2-4.4 | 4.2-4.4 |
| all other libs parsed by | 2.8 | 2.4 | 1.9-2.0 |
| walk blocked on lib.dom | 4.2 | 3.8-4.0 | 3.7-3.8 |
| walk: project's own files, serial | 5.0-5.5 | 5.0-5.2 | 0.3 |
| bind (tasks) | 3.6-4.0 | 3.5-3.9 | 3.1 |
| checkers made | 1.1 | 0.8-0.9 | 0.8-0.9 |
| end of checker creation | 16.5-17.1 | 15.7-16.6 | 9.8-10.0 |

Findings:
1. The late start is small: a lib task starts 0.24-0.35 ms after its spawn (the spawner is still spawning). Not the problem.
2. The walk takes the libs in order and lib.dom is first, so it blocks 3.7-4.2 ms on lib.dom's parse while the other libs finished ~1 ms after spawning: three cores idle, walk idle.
3. Then the walk parses the project's own files one by one: 5 ms on zod3 and ts-pattern.
4. Bind in tasks still takes 3.1-4.0 ms, even on mitt (few files): likely lib.dom's own bind, one task, serial (not yet timed per file).

Leads (Trig's, by size):
A. Don't block the walk on an unfinished lib: walk the project's files while lib.dom parses, keeping the final file order. Overlaps ~4 ms with the 5 ms own-file parse on zod3/ts-pattern.
B. Parse the project's own files in tasks (Go's work groups do). 5 ms on one core toward ~1.5 on four.
C. Bind lib.dom (and each lib) in its parse-ahead task, as bind_alone does, so its bind overlaps the walk too. The floor before checking would then be about lib.dom's parse plus bind (~7 ms) against today's ~15 ms on zod3.
