# A FIFO read that never ends, on macOS (2026-11-15)

In a core suite run on the Mac under load (both build slots busy, 657 s
suite), `cli.std_file_ops` died: "debug fifomore: late: exit status
137", the script's `timeout -s KILL 20` on `./fifomore` (debug,
`RIG_SANITIZE=1`). Run alone it passed 3 of 3, the first in 41 s and the
others in 7 s. The question was whether that was slowness or a stall.

## Slowness or a stall

The 41 s is the whole script, which Swarm times: it builds seven
programs in debug and in release, and the first run after a compiler
change builds the runtime cold (other worktrees' `.swarm/times` show
the script at 50-70 s after a rebuild and 7-11 s warm). The 20 s limit
covers only the run of `./fifomore`, which takes 1.45 s.

The fifomore case run 150 times as the script runs it (its five writers
each under `timeout 10`, the program under `timeout -s KILL 20`), with 20
busy loops at nice 10 on the Mac's 10 cores, all under `tools/heavy`:

| | runs | 1.44-1.47 s | over 1.5 s | killed at 20 s |
|---|---|---|---|---|
| before | 150 | 143 | 0 | 7 (4.7%) |
| after | 150 | 149 | 1 (1.53 s) | 0 |

The distribution is bimodal: no run was slow, and every failure was
the same stall. Each killed run printed `late` (at 314-326 ms) and
nothing more, its `empty` writer exited 0 (it opened the FIFO and
closed it), and the three writers after it timed out (124) waiting for
a reader that never came. `sample` of each stuck process, at 8 s and
11 s, showed the same stack: the main fiber's worker parked in its
poller (kevent), and the one pool thread in

    poolMain > poolCall.C.run > std.file.readHere > readOpen > readRest > readSome > read

So the open of `r/empty` had returned, its writer had come and gone,
and the read waited for good. Nothing in the pool was lost: the call ran
on its thread, which never came back from read(2).

## The kernel

The same race without Rig, plain `cat` as the reader and `: >f` as the
writer starting 50 ms later, under the same load: 1 of 300 rounds hung.
A second reader that opened the FIFO nonblocking then read 0, the end,
so the kernel's state was the end; a new writer's open and close freed
the `cat`.

A C program of two threads on a fresh FIFO each round (the reader
opening first, blocking open and blocking reads; the writer 200 us
later), 2000 rounds each, on a lightly loaded Mac:

| the writer | lost |
|---|---|
| opens and closes, writing nothing | 4 |
| writes a byte, then closes | 0 |
| opens, waits 1 ms, closes | 0 |
| opens and closes; the reader waits 1 ms after its open before it reads | 0 |

Under the 20 busy loops the first row lost 84 of 2000 (4.2%), about
the fifomore case's rate. So the window is the reader entering its
first read as a writer that wrote nothing closes, and load widens it. And on macOS neither `poll` nor `kqueue`
(EVFILT_READ) reports a FIFO's writers leaving: after a blocking open,
with the descriptor made nonblocking, a writer that held the FIFO 0.5 s
and closed it left both waiting their full 3 s, and the read after gave
0. A blocking read entered while the writer is there does wake when it
leaves, written to or not (0.51 s each).

## The fix

A FIFO read on macOS never parks in read(2). `std.file.read` of a FIFO
(on the pool, `readHere`) opens it blocking, as before, so it waits for
a writer, then makes the descriptor nonblocking and reads it as
`fifoBytes`: a read of 0 is the end, since a writer came; a read that
would wait polls for at most 1 ms, doubling to 64 ms while nothing comes,
and reads again (`rig.net.FifoWait`). Linux's whole read of a FIFO
keeps its `poll` with no limit, which reports POLLHUP. `file.open` leaves a FIFO's descriptor
nonblocking on macOS, whether it waited or not, and a File's read
(`net.readOnto`, which `io.copy` uses too) waits the same way on EAGAIN.
That changes Linux too: a File read of any nonblocking descriptor, a
stdin a parent left O_NONBLOCK among them, waits in an unbounded poll
where it failed with `FileError.failed`; the `nbstdin` case shows it
(the base commit fails it, this one prints both writes).
The end a writer leaves while its reader waits comes at the next poll:
up to 64 ms later, about 5 ms over the fifomore case (p50 1.452 s
before, 1.457 s after).

The case that fails first is `fifoleave` in test/cli/std_file_ops.sh:
eight readers at once, 500 rounds each, each round's writer a task
that opens the FIFO a moment later and closes it having written
nothing. Before the fix, unloaded, it hung in 7 of 8 runs (killed at
15 s; the run that passed took 0.24 s); after, it passed 10 of 10 at
0.19-0.32 s unloaded and 30 of 30 under the 20 busy loops.

## Why polling

An independent review (2026-11-15) asked whether a readiness API could
see the end instead of a bounded poll, each wait with a 1 s limit, a
fresh FIFO a round, the reader opening first and the writer 200 us
later. With the writer still there when the wait begins, leaving after
2 ms (or 50 ms) without writing:

| reader waits in | lost |
|---|---|
| kqueue EVFILT_READ (EV_CLEAR, as the poller registers) | 30 of 30, and 5 of 5 at 50 ms |
| kqueue, the reader opened O_NONBLOCK (`wait: false`) | 20 of 20 |
| kqueue EVFILT_READ and EVFILT_VNODE (every NOTE_) | 5 of 5 |
| poll(POLLIN) | 30 of 30 |
| select() | 0 of 2000 |
| the bounded poll, 1 to 64 ms | 0 of 2000 (the end at worst 8.3 ms late; 72.5 ms with a 50 ms writer, against 61.7 ms for a blocking read) |

With the writer opening and closing at once, the race:

| reader | idle (load about 6) | 20 busy loops at nice 10 |
|---|---|---|
| blocking read (before) | 15 of 3000 | 35 of 2000 |
| select() | 4 of 3000 | 2 of 2000 |
| kqueue | 4 of 300 | 0 of 2000 |
| the bounded poll | 0 of 3000 | 0 of 2000 |

kqueue and poll never report a FIFO's writers leaving on macOS, race or
not. select() sees the ordinary end, but in a lost round never reports
the FIFO readable while a read gives 0: the kernel has lost the
socket's mark that nothing more comes, and only the writer count that
read(2) looks at is right. No readiness call (poll, kqueue, select,
EVFILT_VNODE) sees the end then, and macOS gives no writer count
(no F_GETPIPE_SZ; fstat has none; an O_RDWR open would count itself),
so a read made again, a poll with a limit, is what remains. The review
suggested waiting in select() on macOS, which sees the ordinary end at
once, with a backstop of about 1 s for the race; that is left for the
owner (descriptors past FD_SETSIZE, 1024, need `select$DARWIN_EXTSN`).

## Siblings

- Opens: a FIFO's open waits in the kernel for the other end; no lost
  open was seen (every stuck process had returned from its open). The
  other blocking open, a device's, has no writer to leave.
- Anonymous pipes: the same race in C, a pipe's write end closed with
  nothing written about as its reader thread enters a blocking read,
  lost 0 of 5000 rounds under the 20 busy loops. A pipe's reads stay
  blocking.
- A standard stream that is a FIFO (`prog <fifo`) is opened by the
  shell, its description shared with other processes, so std does not
  make it nonblocking; its reads keep the kernel's race, as `cat`'s do.
- Writes are not affected: a writer whose reader leaves fails with
  EPIPE.
