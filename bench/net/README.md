# Socket benchmarks

Times Rig's TCP sockets (`std.net`, docs/STD.md) against Go's `net` and
Tokio's `tokio::net`. Each program runs an echo server and its clients
in the same process, over the loopback interface, so the numbers are
the runtime's: its system calls, its poller, and how it wakes the task
a socket was waiting for. It is not part of the test suite or CI.

```sh
bench/net/bench-net
D=$(mktemp -d)
bench/net/bench-net --out $D --build-only
bench/net/bench-net --out $D --time-only --reps 9
```

It needs `bin/rig` built first, Cargo, and Go. `bench/net/bench-net
--help` lists the variants (`rig-fast`, `tokio` and `go` by default;
`rig-safe` on request) and the options. `--record "#PR: what changed"`
adds the Rig rows to [PROGRESS.md](PROGRESS.md).

## The benchmarks

Each program runs all three, times each with the monotonic clock, and
prints `NAME NS CHECK`; the driver rejects a run whose checks differ
between programs. A round trip writes 64 bytes and reads the 64 the
server echoes.

| Name | What it does | Per |
|---|---|---|
| `pingpong` | one connection makes 20,000 round trips | round trip |
| `echo` | 100 connections each make 1,000 round trips, at once | round trip |
| `connect` | 500 times: connect, one round trip, close | connection |

`pingpong` is the latency of one wake each way. `echo` is throughput
with many sockets ready at once. `connect` adds accepting and closing.
Each run leaves its connections in TIME_WAIT for a while, so many runs
in a row can use up the system's ports for outgoing connections; the
driver's runs stay well under that.

## The rules

As in [bench/tasks](../tasks/README.md): the same work and constants in
each program; each runtime as it is used; Tokio from the repository's
`misc/tokio` clone when there is one; the best of interleaved runs;
arm64 on the Mac and x86 on pup, on a quiet machine.

## Where it stands

On 2026-10-20, with std.net, best of 3. On the Mac (an Apple M5 with 10
cores):

```text
         rig-fast      tokio         go            vs tokio
pingpong 14.79 us/trip 14.10 us/trip 16.01 us/trip rig-fast 1.0x slower, go 1.1x slower
echo     5.98 us/trip  5.68 us/trip  5.68 us/trip  rig-fast 1.1x slower, go 1.0x faster
connect  57.29 us/conn 57.43 us/conn 58.58 us/conn rig-fast 1.0x faster, go 1.0x slower
```

On pup (Linux, x86-64, 22 cores):

```text
         rig-fast      tokio         go            vs tokio
pingpong 4.81 us/trip  5.07 us/trip  5.90 us/trip  rig-fast 1.1x faster, go 1.2x slower
echo     1.10 us/trip  1.60 us/trip  949 ns/trip   rig-fast 1.5x faster, go 1.7x faster
connect  25.86 us/conn 30.29 us/conn 49.63 us/conn rig-fast 1.2x faster, go 1.6x slower
```

On loopback, a round trip costs what the system calls and one wake each
way cost, so the three runtimes stay close; Rig is ahead of Tokio on
pup and even with it on the Mac.
