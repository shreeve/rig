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

The latest rows are in [PROGRESS.md](PROGRESS.md), which `--record`
writes, and the headline numbers against Tokio and Go are in
[docs/launch/benchmarks.md](../../docs/launch/benchmarks.md).

On loopback, a round trip costs what the system calls and one wake each
way cost, so the three runtimes stay close.
