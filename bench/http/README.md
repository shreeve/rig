# HTTP benchmarks

Times Rig's HTTP server (`http.serve`, docs/STD.md) against Go's
`net/http` and hyper on Tokio: requests per second and latency under
load, and the memory an idle connection holds. These are the plan's
target benchmarks (docs/CONCURRENCY.md, "The target"). It is not part
of the test suite or CI.

```sh
bench/http/bench-http
bench/http/bench-http --idle 100000     # Linux: spread over 127.0.0.x
```

It needs `bin/rig` built first, Cargo (hyper comes from crates.io), and
Go. `bench/http/bench-http --help` lists the options.

## What it measures

Each server takes the address to listen on and answers `GET /` with
`Hello, world!`, 13 bytes of plain text, keeping connections alive.

- **Load.** One load generator, `bench/http/load` in Go, the same for
  every server, keeps 64 connections each sending a request and waiting
  for its answer, for 3 seconds, and reports requests per second and
  the 50th and 99th percentile latency. The best of 3 interleaved runs
  counts.
- **Idle connections.** It then opens N connections, each making one
  request and holding open, and the server's resident memory after,
  less before, over N, is what one idle connection costs. One address
  gives a client about 28,000 ports on Linux, so the connections spread
  over 127.0.0.1, .2, ...; macOS has only 127.0.0.1, about 16,000 ports,
  so 5,000 there.

The servers and the load generator share the machine, as in a loopback
benchmark they must; a server that spends less CPU leaves more to the
load generator.

## Where it stands

On 2026-10-20. On the Mac (an Apple M5 with 10 cores), 5,000 idle
connections:

```text
                 req/s       p50       p99 per idle conn
rig-fast        191526     326 us     597 us      16.6 KiB
tokio           180339     346 us     614 us      18.6 KiB
go              163675     366 us    1071 us      18.5 KiB
```

On pup (Linux, x86-64, 22 cores), 10,000 idle connections, and then
100,000 (one run):

```text
                 req/s       p50       p99 per idle conn
rig-fast        845844      51 us     427 us      16.6 KiB
tokio           294609     162 us     808 us      10.8 KiB
go              237436     153 us    1439 us      19.3 KiB

rig-fast        974848      41 us     538 us      16.6 KiB
tokio           297544     168 us     731 us      10.8 KiB
go              249642     136 us    1514 us      19.2 KiB
```

Rig answers as fast as hyper on the Mac and about three times as many
requests on pup. An idle connection holds no buffer: its read and write
buffers, 16 KiB, are a block of its worker's while it reads and answers
a request, given back while it waits for the next (`net.Conn.fill`,
`sched.takeBlock`), and a worker keeps 64 blocks, so a burst leaves no
memory behind. So an idle connection holds its task's stack page (16 KiB
on Apple Silicon) and a few small records: 16.6 KiB on the Mac and 8.6
KiB on pup (PROGRESS.md), below Tokio's and Go's on both. A million idle connections do
not fit on pup, whose processes may hold 524,288 descriptors and whose
19 GB free would not hold a million of any server's plus the load
generator's; 100,000 give the figure per connection.
