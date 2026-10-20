# Panel 6: I/O and std

Probes: panel scratch `io-std/`.

## Findings

1. **One `Expect: 100-continue` request kills the server.** curl sends the
   header for bodies over 1 MB, and `readerExpectNone` asserts it is absent
   (src/net.zig:339). Probe: the process panicked and later requests were
   refused. Release: undefined behavior.
2. **The blocking pool ignores cancel and deadlines.** Its wait has no cancel
   and no deadline (src/sched.zig:968-969). Inside `time.within(50ms)`,
   `file.read("/dev/stdin")` succeeded after 3901 ms. A canceled read
   finished after 2892 ms.
3. **Running out of fds ends `http.serve`.** An EMFILE from accept stops the
   server, closes the listener and cancels every connection (probe:
   "serve ended NetError.failed").
4. **No server timeouts.** An idle or slow connection holds its
   task forever (`fill`).
5. **Bodies over 16 MiB are cut off without notice** (net.zig:340,
   `catch {}`). A 17 MB POST arrived as 16777216 bytes and got a 200.
6. **Missing:** DNS, TLS, an HTTP client, response headers beyond the
   content type (no `Location`), streaming bodies, and graceful shutdown.
7. **std-files branch:** stat, realpath and read_dir give `none` for every
   failure, EACCES and EIO included, though STD.md says "when nothing is".
   `os.cwd()` gives `""` when it fails. `Stat` has no modification time.

## Decisions for the owner

1. Every call on the pool is a fallible waiting point. Cancel or a deadline
   ends the wait at once; the call finishes on the pool, which drops its
   result, and a write may still happen. **Default: yes.**
2. `none` only for "nothing there". Other failures are `FileError` or `Stop`:
   `read -> String?!`, `stat -> Stat?!` (with `modified`),
   `read_dir -> List[Entry]?!`, `realpath -> String?!`,
   `os.cwd() -> String!`. **Default: yes.**
3. First file layer: `write(path, data)!`, which makes parent directories as
   Trig asks; `append`; `rename`; `mkdir` (makes parents, and an existing
   directory is fine); `remove -> Bool!`; `open` and `create`, which give a
   `File`. **Default: yes.**
4. One shape for files, sockets and HTTP bodies: `read(!@, into, max) -> Int!`
   and `write(!@, bytes)!`. Generic code relies on these two names, with
   `io.copy` first. **Default: yes.**
5. HTTP fixes first: handle `100-continue`; a body limit you can set, with
   413 beyond it; retry accept after EMFILE; 60 s idle and 10 s head
   timeouts; `Response.headers`. **Default: yes.**
6. Canceling `serve` stops accepting. Requests in flight run until the
   task's `time.within` deadline. **Default: yes.**
7. DNS through `getaddrinfo` on the pool next. TLS and the client get their
   own round. **Default: yes.**
