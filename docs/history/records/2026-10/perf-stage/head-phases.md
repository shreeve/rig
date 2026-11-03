# Trig's serial head against tsrs, by phase (2026-11-01)

pup, 07:16-07:17 in Swiss's slot: one checker on P-core 6 (sibling idle,
`--singleThreaded`), four on 0,6,8,10 (siblings idle); 20 rounds, arms
rotated; medians in ms. Trig main `dd43341` with measurement-only phase
timers on stderr (scratch worktree `trig/head-phases`, never pushed), a plain
`--release` build by Rig `ad5d9b043`, cross-built on the Mac. tsrs 0.18.0 as
shipped, Go mode (`--checkerAssignment go --noLazyMembers`), its own
`--extendedDiagnostics` phases. Exit statuses are the same on both sides.
Raw: pup `/zfs/trig-pup/trial/head/runs.txt`, `an.py`, `time.sh`; summary
`scratchpad/head/an.txt`.

"Outside the clock" is wall less each tool's Total time: process start
before `main` and exit after the statistics.

## Four checkers

| phase | zod3 Trig | zod3 tsrs | gap | ts-pattern Trig | ts-pattern tsrs | gap |
|---|---:|---:|---:|---:|---:|---:|
| wall | 102.2 | 66.7 | 35.4 | 343.2 | 239.8 | 103.4 |
| check | 59.0 | 44.0 | 15.0 | 290.9 | 208.5 | 82.4 |
| **head** (wall less check) | 43.2 | 22.7 | **20.5** | 52.3 | 31.3 | **21.0** |
| start-up and config | 1.8 | 1.0 | 0.8 | 1.9 | 1.0 | 0.9 |
| load: parse + resolve | 21.4 | 10.0 | **11.4** | 20.8 | 11.0 | **9.8** |
| bind | 7.3 | 0 | **7.3** | 7.4 | 0 | **7.4** |
| checker creation | 1.7 | 1.0 | 0.7 | 2.0 | 1.0 | 1.0 |
| tsrs: lazy lists, global diagnostics | (in check) | 4.0 | -4.0 | (in check) | 5.0 | -5.0 |
| report | 0.05 | 0 | 0 | 0.9 | 3.0 | -2.1 |
| outside the clock | 10.3 | 9.2 | 1.0 | 18.7 | 12.3 | **6.5** |

## One checker

| phase | empty Trig / tsrs | zod3 Trig / tsrs | ts-pattern Trig / tsrs |
|---|---|---|---|
| wall | 20.6 / 15.9 | 160.6 / 114.8 | 815.1 / 644.6 |
| load | 10.2 / 7.3 | 17.9 / 11.0 | 18.4 / 11.1 |
| bind | 4.7 / 2.0 | 7.3 / 3.0 | 7.3 / 3.0 |
| checker creation | 0.6 / 1.0 | 0.6 / 1.0 | 0.6 / 1.0 |
| check | 0 / 0 | 126.9 / 93.0 | 774.8 / 617.5 |
| outside the clock | 4.1 / 4.9 | 6.0 / 5.8 | 10.9 / 9.6 |

## Readings

- **Load is the largest piece of the head**: 7 ms behind tsrs at one
  checker on zod3 and ts-pattern, 10-11 ms at four. Trig's load gets 2-3 ms
  slower at four than at one (17.9 to 21.4 on zod3); tsrs's barely moves
  (11.0 to 10.0), so its parallel parse buys it little either.
- In user cycles the load is parsing: a profile of zod3 at one checker (E-core,
  self cycles grouped by module) has lexer 3.1%, ast 2.9%, parser 1.9%,
  module resolution and paths 0.6%.
- System calls are similar in kind and count (strace -c, zod3, one checker),
  except that Trig makes 777 futex and 384 epoll_pwait calls against tsrs's
  317 and 0: every file call from a task goes through Rig's blocking pool
  (`sched.blocking`), a thread hop each way, pinned to one core.
- **Bind** is 7.3 ms serial at both counts; tsrs binds in 3 ms at one
  checker and in its checkers at four (Merges' parallel bind is the path at
  four; tsrs also binds declaration files' member lists lazily, which Trig
  does not).
- **Outside the clock** at four checkers on ts-pattern: 6.5 ms more than
  tsrs, likely the exit's unmapping of four checkers' memory.
- The check phase here is a plain build, not PGO, so its gap (82 ms on
  ts-pattern at four) is larger than the audit's PGO figure (45 ms).

## Ownership

- Parse speed (lexer, parser): mine. The blocking pool's hops: Rig runtime,
  mine. Loader order, parse-ahead and parallel bind: Merges'.
- Exit memory work: Merges' queue row 44, fix 1 (os.exit in Trig's finish),
  waiting on the owner's name for a std.target flag.

## The load split (zod3, one checker, pup E-core 13)

- **Parsing.** Self cycles over 30 runs each (perf's sampling is capped near
  1 kHz, so one run gives about 270 samples): Trig's lexer and parser 5.45%
  of 8K samples (436), tsrs's scanner and parser (tsrs/bin/tsrs, with
  symbols, `TSRS_LAZY_DTS=0`) 4.07% of 7K (285). Trig parses in about 1.5x
  tsrs's cycles, about 3-4 ms on a P-core. ast is not compared: tsrs_ast
  holds the checker's accessors too.
- **The blocking pool's hops.** The same Trig built with a Rig whose
  `sched.blocking` and `blockingStop` run the call inline (a ceiling, not a
  fix: worktree rig/pool-inline-ceil): load 26.9 to 24.5 ms at one checker and
  26.9 to 23.6 at four (medians of 8, E-cores 12-15). About 2.5-3.3 ms of
  the E-core load, perhaps 1.5-2.5 ms on a P-core.
- Module resolution is 0.1-0.3% of user cycles; its system calls are no
  more than tsrs's.

## Re-measured after trig#234, #236 and rig#855, #856 (2026-11-01 13:14)

Trig main `fb60a18` with the same timers (`head-phases-timers.diff`), Rig
main `5fd1ff38f` (pool-inline in, no canaries); arms shuffled each round
with a warm-up; 20 rounds; medians in ms.

| | zod3 Trig / tsrs, 1 | zod3, 4 | ts-pattern, 1 | ts-pattern, 4 |
|---|---|---|---|---|
| wall | 159.4 / 114.8 | 95.5 / 65.1 | 847.6 / 646.4 | 342.7 / 238.4 |
| head (wall less check) | 30.6 / 21.8 | 36.0 / 22.1 | 38.7 / 25.9 | 45.7 / 30.4 |
| load | 16.0 / 11.0 | 15.9 / 10.0 | 16.7 / 11.0 | 16.7 / 11.0 |
| bind | 7.0 / 3.0 | 7.1 / 0 | 7.1 / 3.0 | 7.2 / 0 |
| outside the clock | 5.8 / 5.8 | 9.1 / 8.1 | 12.4 / 7.9 | 16.5 / 11.9 |

- The load no longer slows at four checkers (zod3 21.4 to 15.9, ts-pattern
  20.8 to 16.7): the blocking pool's hops were it. Its gap to tsrs is 5-6
  ms at both counts.
- The head's gap at four: zod3 20.5 to 13.9 ms, ts-pattern 21.0 to 15.3.
- tsrs's Bind time is lazy for declaration files by default: zod3 on an
  E-core, 6 ms as shipped, 9 ms with `TSRS_LAZY_DTS=0`; Trig 12-14. Parse
  25 against 18 ms there.

## Parse and bind after #236, #239, #240 (2026-11-01 17:45)

Trig main `07e4447` built by Rig main, pup E-core 13, one checker, fastest of
7 (whole ms):

| | Trig | tsrs as shipped | tsrs, `TSRS_LAZY_DTS=0` |
|---|---:|---:|---:|
| zod3 Parse time | 21 | 16 | 16 |
| ts-pattern Parse time | 22 | 16 | 18 |
| zod3 Bind time | 10 | 6 | 8 |
| ts-pattern Bind time | 10 | 6 | 9 |

Parse is about 1.3x tsrs (was 1.4x); bind on equal work 1.1-1.25x (was
1.4x). Self cycles, zod3, 30 runs each: Trig lexer 171 samples against
tsrs_scanner 104 (1.6x), parser 224 against 181 (1.24x);
`create_identifier_with_diagnostic` level (0.42% against 0.46%). What is
left in the lexer is `scan` itself (1.34% of Trig's samples).
