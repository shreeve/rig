# One server, three ways

The same small HTTP server in Rig, in Go, and in Rust with Tokio and
hyper: `/hit` counts requests, a counter every request shares;
`/join?room=NAME` counts the people in a room; `/boom` panics, and is
answered with a 500 while the server goes on; anything else is a 404.

```sh
rig run rig/rooms.rig                 # from docs/launch/examples
(cd go && go run .)
(cd rust && cargo run --release)
```

Each listens on `127.0.0.1:8080`, or on the address given as its first
argument. Then:

```sh
curl localhost:8080/hit
curl 'localhost:8080/join?room=rig'
curl -i localhost:8080/boom
seq 1000 | xargs -P 50 -I{} curl -s localhost:8080/hit -o /dev/null
curl localhost:8080/hit
```

All three give the same answers, and the last `/hit` counts all 1,000
concurrent requests before it.

What each needs, beyond the routes:

- **Rig:** a `*Cell` for the counter and an actor for the rooms; the
  compiler checks that the closure's captures may be shared by every
  connection's task, and `http.serve` runs each request isolated.
- **Go:** an atomic for the counter, a mutex taken and released by hand
  for the rooms, and a wrapper of its own to answer a panic with a 500,
  since `net/http` closes the connection instead.
- **Rust:** an `Arc` holding an atomic and a `Mutex`, an `async fn`
  handler, and `catch_unwind` to answer a panic with a 500, since a
  panic would otherwise end the connection's task.
