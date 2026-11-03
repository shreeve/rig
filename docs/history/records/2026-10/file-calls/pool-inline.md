# A regular file's read runs in its task, not on the blocking pool

Design note for the owner, Rig - Rust, 2026-11-01. Measurement arm: Rig
`ad5d9b043` plus std/file.zig changes (worktree `rig/pool-inline-ceil`, not
pushed). Head-phase context: [head-phases.md](../perf-stage/head-phases.md). The
ceiling arm is [pool-inline-ceiling-arm.diff](pool-inline-ceiling-arm.diff).

## What happens now

Every std.file call from a task (`file.read`, `exists`, `stat`, `realpath`,
`dir_entries`, and the rest) runs on the blocking pool (`sched.blockingStop`):
the task parks, a pool thread is woken by futex, makes the system call, and
wakes the task's worker. On a local disk the call itself takes a few
microseconds; the two hops cost more than the call, and pinned to one core
(as every one-thread race against tsrs is) each hop is a context switch.
Trig makes about 400 such calls checking zod3 (strace: 777 futex and 384
epoll_pwait calls against tsrs's 317 and 0).

Go and tsrs read files on the calling thread. Go blocks the thread on the
system call, and its sysmon hands the thread's other work to another thread
if the call takes more than about 20 us. tsrs, on rayon, just blocks.

## The change

A read of a regular file, and the calls that only look at a path (exists,
stat, realpath, dir entries), run in the calling task. Everything that can
wait on another process stays on the pool, so #835's cancel and SIGTERM work
is unchanged: FIFOs, devices, pipes, sockets, and every write, rename, mkdir
and remove (not measured here; a later step if they matter).

The arm measured tests the path with stat, then reads inline if it is a
regular file. The form to build has no race: open with `O_NONBLOCK`, fstat
the descriptor, read it inline if regular, otherwise hand the open
descriptor to the pool as today.

What it costs: an inline read cannot be canceled part way, and a slow disk
or network file system holds the task's worker for the call. A regular
file's read is bounded on a local disk; on NFS it is as slow as it is for Go
and tsrs.

## Numbers (pup, 2026-11-01 09:24-09:41, Swiss's slot)

time-ab.sh (seeded shuffle each round, warm-up, binaries from /tmp): base,
a byte-identical copy of base (the A/A), and the policy arm, all built from
the same sources with Rig `ad5d9b043`. Trig `dd43341`: one checker on P-core
6, four on 0,6,8,10; mitt, neverthrow and superstruct 60 rounds, the others
20. loco (`~/Data/Code/loc` `03f890e`) on Trig's and Rig's trees with
`--jobs 1` and `--jobs 4`, 20 rounds. Medians of wall time against base;
outputs identical in every run.

| case | base ms | A/A | policy | instructions |
|---|---:|---:|---:|---:|
| Trig mitt, 1 | 23.65 | 0.1% faster | 3.9% faster | level |
| Trig mitt, 4 | 27.12 | 0.8% faster | 6.4% faster | level |
| Trig neverthrow, 1 | 25.22 | 1.2% faster | 1.7% faster | level |
| Trig neverthrow, 4 | 27.76 | 0.8% slower | 5.2% faster | level |
| Trig superstruct, 1 | 31.50 | 0.2% faster | 2.4% faster | level |
| Trig superstruct, 4 | 23.45 | 0.5% faster | 5.7% faster | level |
| Trig tiny-invariant, 1 | 72.46 | 1.4% faster | 2.0% faster | level |
| Trig tiny-invariant, 4 | 75.14 | 1.2% faster | 4.9% faster | level |
| Trig zod3, 1 | 163.10 | 0.3% slower | 1.0% faster | level |
| Trig zod3, 4 | 103.91 | 0.2% slower | 5.3% faster | level |
| loco, Trig's tree, 1 job | 53.10 | 3.2% slower | 14.1% faster | 0.6% fewer |
| loco, Trig's tree, 4 jobs | 25.28 | 3.3% faster | 19.9% faster | 1.3% fewer |
| loco, Rig's tree, 1 job | 92.28 | 2.8% faster | 10.8% faster | level |
| loco, Rig's tree, 4 jobs | 37.99 | 0.9% faster | 28.5% faster | 0.8% fewer |

The time saved is system time (zod3 at four: 42.3 to 40.4 ms; loco on
Rig's tree, one job: 37.4 to 27.5 ms); user time and peak RSS are level
(mitt at one checker 0.5 MB higher, the rest within 0.5 MB either way).
The one-checker gains on neverthrow, tiny-invariant and zod3 are close to
their A/A spread; the four-checker and loco gains are well above it.

Rig's tests: std-file, std-io and concurrency-task pass under the arm (103
jobs). bench/net and bench/http do not call these functions: their code is
byte-identical with and without the arm (otool -t hashes), so their rows
cannot move.

## Decisions (defaults)

1. Run a regular file's read and the path-only calls (exists, stat,
   realpath, dir entries) in the calling task; keep everything that can
   wait on another process on the pool. Default: yes.
2. Build the race-free form (open with O_NONBLOCK, fstat, read inline if
   regular, else the pool with that descriptor). Default: yes.
3. Writes, renames, mkdir and removes stay on the pool until measured.
   Default: yes.
