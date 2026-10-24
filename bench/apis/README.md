# API object call benchmark

Times a call through an API object, `s.area()` of a `?{Shape}`
(docs/design/apis.md, Stage 4), against the same work through a callable
view, `f()` of a `?fun() -> Float`, and through a `match` on an enum. It
is not part of the test suite.

| Program | What each step does |
|---|---|
| `object.rig` | two calls through `?{Shape}`s of two types: load the entry from the type's table, call it with the value's address |
| `fun.rig` | two calls through `?fun`s of stack closures over the same values: call the view's function with its context |
| `enum.rig` | two calls of a function that matches on the variant |

Each loop runs in a `called` function, so its views are parameters and
no call can be resolved where it is made. Each program makes 600 million
calls and prints `900000000.0`.

```sh
D=$(mktemp -d)
for f in object fun enum; do bin/rig build --release bench/apis/$f.rig -o $D/$f; done
for i in 1 2 3 4 5; do for f in object fun enum; do /usr/bin/time -p $D/$f; done; done
```

On pup, the package `rig build` leaves (`RIG_OUT_DIR`) is built with
`zig build-exe -Osafe __rig_main.zig` and run pinned to a P-core
(`taskset -c 3`).

## Results

2026-10-23, `rig build --release` (ReleaseSafe), fastest of 5 (7 on
pup), interleaved:

| Machine | Object | `?fun` | Enum `match` |
|---|---|---|---|
| Mac (arm64) | 274.6 ms | 276.5 ms | 165.7 ms |
| pup (x86-64, P-core) | 916.7 ms | 894.4 ms | 120.5 ms |

A call through an object costs what a call through a callable view
does: 1% faster on the Mac, 2.5% slower on pup. The difference on pup
is the entry's load from the table, `call *(%r15)`, where a callable
view holds its function in the view, `call *%r15`. Each entry checks the
alignment of the address it casts, as a callable view's thunk does;
without the check pup is 2% faster than `?fun`, but the Mac is 30%
slower, since the entry then sets up a frame on every call.
