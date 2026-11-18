# HTTP/1.1 server review: correctness and security

Read-only review of `src/net.zig` (100-430, 831-2085), `std/http.rig`,
`std/http.zig` at a1742e713, against Zig 0.17.0's `std/http.zig`,
`std/http/Server.zig`, `ChunkParser.zig`, `HeadParser.zig`, and
`std/Io/Reader.zig` (paths below as `zig:` are under
`~/.local/share/mise/installs/zig/0.17.0/lib/std/`). Nothing was built
or run: every finding is from reading the path end to end. "CONFIRMED"
means the server's behavior is certain from the code; where an attack
also needs a lenient proxy in front, that part is marked PLAUSIBLE.

Rig programs are built `-Odebug` or `-Osafe` (`src/main.zig` 220-228),
so Zig's `assert`, `unreachable`, and integer overflow all panic. A
panic in a connection's task is not inside `tasks.isolate` (only the
handler is), so it ends the program by `abort` (`runtime.zig`
`panicWith`), unless the program itself wrapped `http.serve` in an
isolate, in which case it ends `serve` and every connection.

Not repeated here: 204/304 with a body, whitespace before a header's
colon, no Host check, headers and body as two writes.

---

## 1. CRITICAL. A GET, HEAD, DELETE, OPTIONS, TRACE, or CONNECT with a Content-Length or chunked body, on a kept-alive connection, ends the program

**CONFIRMED.** `net.zig` 987, 1017-1018, 1126-1135; `zig:http/Server.zig` 591-597; `zig:Io/Reader.zig` 274-276.

Trigger (one request, no proxy needed; `curl -X DELETE -d '{}' URL`
and `curl -X GET -d x URL` send exactly this shape):

```
DELETE /item/1 HTTP/1.1\r\n
Host: x\r\n
Content-Length: 2\r\n
\r\n
{}
```

`Content-Length: 0` does it too, and so does `Transfer-Encoding: chunked`.

Path:

1. `answer` decides `has_body` by the headers (987), as the docs say
   ("whatever its method"), and calls `request.readerExpectContinue(&buf)` (1017).
2. Zig's `readerExpectNone` decides by the *method*:
   `if (!request.head.method.requestHasBody()) return .ending;`
   (Server.zig 595). For these six methods it returns the shared empty
   reader and leaves `reader.state == .received_head`. The body is not
   read: the handler sees `req.body == ""`.
3. `respond` calls `discardBody` (1107). The state is `.received_head`
   and the head has a length, so it takes the branch at 1132, calls
   `readerExpectContinue(&.{})` again (again `.ending`), then
   `body.discardRemaining()`, whose first statement `r.seek = r.end`
   (Reader.zig 276) stores into `ending_instance`, a `const` global
   (`ending` is `@constCast(&ending_instance)`): a fault where constants
   are mapped read-only. Where the store survives, the next line,
   `std.debug.assert(r.state == .ready)` (1135), fails, since the state
   is still `.received_head`.

Either way the connection's task panics before the answer is written
and the program aborts. With `Connection: close` (or HTTP/1.0) the
branch is skipped and nothing crashes, but the body is still silently
dropped.

Zig's own `discardBody` gates the same branch on `requestHasBody()`,
which is why Zig never reaches this; Rig's copy changed the gate to the
headers (rightly, RFC 9112 §6.3) but still goes through Zig's
method-gated reader.

Nothing in `test/rig/std-http.rig.test` or `test/cli/std_http.sh` sends
a body-less method with a length or chunked on a kept-alive connection.

Fix: never call `readerExpectContinue`/`readerExpectNone`. In `answer`,
write `100 Continue` and flush when asked, then call
`request.server.reader.bodyReader(&buf, head.transfer_encoding, head.content_length)`
directly, for every method. `discardBody` then never sees
`.received_head` with a body (see "Dead or simpler"). Cases to add:
GET, DELETE, OPTIONS, HEAD each with `Content-Length: 0`, a length of
n, and chunked, kept alive, followed by a second request; the body must
reach the handler and the second request must be answered.

---

## 2. HIGH. A chunk size of 2^64-1 or 2^64-2 ends the program

**CONFIRMED.** `net.zig` 1018 (reads through Zig); `zig:http.zig` 587-588; `zig:http/ChunkParser.zig` 52-76.

```
POST / HTTP/1.1\r\n
Host: x\r\n
Transfer-Encoding: chunked\r\n
\r\n
FFFFFFFFFFFFFFFF\r\n
X
```

`ChunkParser` accepts 16 hex digits (its overflow check passes:
its own unit test shows `0xffffffffffffffff` reached before the 17th
digit is refused). `chunkedReadEndless` then reads at least one byte
(`n >= 1`) and computes `cp.chunk_len + 2 - n` (http.zig 588): `+ 2`
overflows `u64` for `chunk_len >= 2^64 - 2`, an "integer overflow"
panic in both build modes, in the connection's task: abort. `max_body`
does not help: the limit caps the read, not the arithmetic.

Related, harmless but wrong: the overflow check
(`new_len <= p.chunk_len and p.chunk_len != 0`, ChunkParser 72) misses
some wraps. `1F000000000000000` (17 digits) is read as
`0xF000000000000000`. It then runs into `max_body` and is answered 413.

Fix: Rig's own chunk-size reader (see 4), refusing a size past
`max_body` (or past 16 digits) before any data is read.

---

## 3. MEDIUM-HIGH. A Content-Length body cut short by the client closing is handed to the handler as complete

**CONFIRMED.** `net.zig` 1018-1023, 2058-2065; `zig:http.zig` 509-525; `zig:Io/Reader.zig` 384-392.

```
POST /upload HTTP/1.1\r\n
Host: x\r\n
Content-Length: 1000\r\n
\r\n
abc                      <- then FIN (close, or shutdown(SHUT_WR))
```

`Conn.stream` returns `error.EndOfStream` when `read` gives 0 (2062).
Zig's `contentLengthStream` passes it up unchanged (`try`, http.zig
518), leaving the state `.body_remaining_content_length`, and
`appendRemainingAligned` takes `EndOfStream` as the normal end:
`error.EndOfStream => return` (Reader.zig 388). `answer` sees success,
runs the handler with `req.body == "abc"`, and answers 200 (a client
that only half-closed reads it). RFC 9112 §6.3 item 6 and §8: a message
shorter than its Content-Length is incomplete, and the recipient MUST
treat it so and close. A client dying mid-upload, or a proxy that
streams a body and drops the upstream connection when its client goes
away, gets a truncated upload stored or acted on as whole.

The chunked path is right (Zig maps the early end to
`HttpChunkTruncated`); only the length path is wrong. The idle timeout
path is right too (`ReadFailed`). Not covered by the tests: the
half-closed cases there have no length.

Fix: after `appendRemaining` succeeds, `if (request.server.reader.state != .ready) return .close;`.

---

## 4. MEDIUM. Zig's chunk-size line is read far more loosely than RFC 9112 §7.1, in ways a proxy in front can read differently

**Parse CONFIRMED; smuggling PLAUSIBLE** (needs a proxy that reads the
same bytes the other way and passes the chunked body through as sent).
`zig:http/ChunkParser.zig` 35-100, reached from `net.zig` 1018.

RFC 9112 §7.1: `chunk = chunk-size [ chunk-ext ] CRLF`, `chunk-size = 1*HEXDIG`. Zig's parser:

| Bytes of the size line | Zig reads | Rule broken |
|---|---|---|
| `5\n` , `5;x\n` | size 5; a bare LF ends the line (61, 81) | CRLF only; the "funky chunks" class |
| `\r\n`, `;x\r\n`, ` 5\r\n`, `-1\r\n` | size 0, the last chunk: no digit is needed, and any byte that is not a letter or digit starts an "extension" (65-68) | `1*HEXDIG`; ext only after `;` |
| `z\r\n`, `1g\r\n`, `0x10\r\n` | 35, 32, 8464: `g`-`z` and `G`-`Z` count as digits 16-35 (55-56) | HEXDIG |
| `5 junk\r\n`, `5,6\r\n` | size 5 | ext grammar |
| an extension of any length | read and dropped, never counted against `max_body` | (see 6) |

One worked case, the bare LF, against a proxy that ends a chunk line
only at CRLF (so reads the LF as part of the extension) and forwards
the body unchanged. After a head of `POST /a HTTP/1.1`, `Host: h`,
`Transfer-Encoding: chunked`:

```
2;\n                      <- proxy: line is "2;\nxx", size 2. Rig: line is "2;", size 2
xx\r\n                    <- proxy: (still the line).         Rig: data "xx", CRLF
36\r\n                    <- proxy: data "36", CRLF.          Rig: size 0x36 = 54
0\r\n                     <- proxy: last chunk.               Rig: data ...
\r\n                      <- proxy: end of POST /a.
POST /b HTTP/1.1\r\n      <- proxy: second request, body of 39 bytes
Host: h\r\n
Content-Length: 39\r\n
\r\n                      <-                                  Rig: ... 54 bytes end here
\r\n                      <- proxy: body starts.              Rig: the chunk's CRLF
0\r\n                     <-                                  Rig: last chunk
\r\n                      <-                                  Rig: end of POST /a
GET /admin HTTP/1.1\r\n   <-                                  Rig: a request the proxy never saw
Host: h\r\n
\r\n                      <- proxy: body ends
```

The ` 5\r\n` and `0x10\r\n` rows do the same against a proxy that reads
sizes with `strtoul(.., 16)`, which skips leading space and takes `0x`.

Fix: read chunk framing in `net.zig` rather than with `ChunkParser`:
1 to 16 hex digits, then `;` or CRLF, CRLF only, anything else closes
with 400; a size past what `max_body` leaves is 413 at once (also fixes 2).

---

## 5. MEDIUM. A trailer section whose first line is 2 or 3 bytes long ends there, and the rest of the trailers are read as the next request

**Parse CONFIRMED; smuggling PLAUSIBLE.** `zig:http.zig` 680-705 (`parseTrailers`), `zig:http/HeadParser.zig` 281-307.

```
POST /a HTTP/1.1\r\n
Host: h\r\n
Transfer-Encoding: chunked\r\n
\r\n
0\r\n
a:b\r\n                   <- a valid field line of 3 bytes (or "a:\r\n", 2 bytes)
GET /admin HTTP/1.1\r\n   <- Rig: the next request starts here
X: y\r\n
\r\n                      <- everyone else: the trailers end here
```

`parseTrailers` peeks two bytes, finds no CRLF, and starts a
`HeadParser` in state `.seen_rn` with `trailers_len = 2`: the first two
trailer bytes are skipped, unfed, but the state still says "at a line
start". In `.seen_rn` the parser looks at the next two bytes: `\r\n`
finishes (the 2-byte line), and a second byte of `\r` goes to
`.seen_rnr`, where `\n` finishes (the 3-byte line: any byte, CR, LF).
So `a:b\r\n` is the whole trailer section to Rig (5 bytes), and
`GET /admin ...` is parsed by `Server.receiveHead` as a request.

Directly, a client whose first trailer line is that short gets its
remaining trailers answered 400 and the connection closed. Behind a
proxy that forwards trailers without checking each line is a field
(the smuggled request line has a space before any colon), it is a
request the proxy never saw.

The same parser's other false ends (a 1-byte line after a CRLF that
falls on a vector boundary, noted in `wantHead`'s comment) need an
invalid line, so matter less.

Fix: with Rig's own chunk reader (4), read trailers with the strictness
of `HeadScan`: lines to the first empty line, CRLF only, each with a
colon, within the head's size limit; or refuse any trailer with 400.

---

## 6. MEDIUM. Nothing bounds how long a body, or a response, may take as a whole; chunk extensions are free

**CONFIRMED** (and partly by design: STD.md says each read must make progress within the idle time). `net.zig` 868-870, 953, 1018; `zig:http.zig` 569-585.

A head has `head_ns` for the whole of it. A body has only `idle_ns`
per read. Trigger: send `Transfer-Encoding: chunked`, one chunk of
16 MiB (`1000000\r\n`, the data, `\r\n`: exactly the limit), then start
the next chunk's line, `1;`, and send one byte of extension every 59 s,
forever: `1;aaaaaaaa...`. The extension's bytes are tossed in
`chunkedReadEndless` without counting toward `max_body`, so 413 never
comes, each read "makes progress", and the connection keeps its 16 MiB
body (more, by the list's spare capacity), its 16 KiB block, and its
task. One upload of 16 MiB per connection pins that memory for as long
as the attacker likes; a few hundred connections exhaust a small
machine. The same trickle works with 1-byte chunks below the limit,
and, on the way out, by reading a large response one byte per 59 s.

Fix: a deadline for the whole body (as the head has), or a floor on its
rate; count chunk framing against a cap; the same for a response's write.

---

## 7. LOW-MEDIUM. HTTP/1.0 and the Connection header

**CONFIRMED** (behavior); `net.zig` 1403, 1420-1422, 992, 1105-1121, 985, 1015-1017.

`Connection` is compared whole with `close`
(`s.head.keep_alive = !eql(value, "close")`), and the last line wins.

a. Any `Connection` header on an HTTP/1.0 request other than exactly
   `close` makes it persistent: `GET / HTTP/1.0\r\nConnection: Upgrade\r\n\r\n`
   is kept alive. RFC 9112 §9.3: a 1.0 connection persists only when
   the `keep-alive` option is present.
b. To a 1.0 client that did ask (`Connection: keep-alive`), the answer
   carries no `connection: keep-alive`, so the client cannot tell the
   connection persists. One that then reads to the close (ApacheBench's
   `-k` mode, by my memory of its source; not run) waits out the 60 s
   idle time on every request.
c. `Connection: close, TE` or `Connection: keep-alive, close` on 1.1 is
   not seen as `close` (RFC 9110 §7.6.1: a list of options): the server
   answers without `connection: close` and holds the connection.
d. `POST / HTTP/1.0\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n...`
   is read as chunked and kept alive. RFC 9112 §6.1: a server that
   receives Transfer-Encoding in an HTTP/1.0 message MUST treat the
   framing as faulty and close after it (a 1.0 proxy in front does not
   know chunked and framed the message some other way).
e. `Expect: 100-continue` on HTTP/1.0 is honored: the server writes
   `HTTP/1.1 100 Continue` to a client that cannot read an interim
   answer, or 417 for another value. RFC 9110 §10.1.1: MUST ignore the
   expectation in a 1.0 request.

Fix: read `Connection` as a comma list; 1.0 persists only with
`keep-alive`, and is told so; 1.1 closes on a `close` member; version
1.0 with Transfer-Encoding closes after the answer (or 400); skip
Expect on 1.0.

---

## 8. LOW. CONNECT reaches the handler, and a 2xx answer is not a tunnel

**CONFIRMED.** `net.zig` 1105-1121.

`CONNECT h:443 HTTP/1.1\r\nHost: h:443\r\n\r\n` with a catch-all
handler (`|req| http.text("ok")`) is answered
`HTTP/1.1 200 OK\r\ncontent-length: 2\r\n...\r\n\r\nok`, and the server
goes on parsing the connection as HTTP. RFC 9110 §9.3.6: a 2xx to
CONNECT switches the connection to a tunnel; the server MUST NOT send
Content-Length, and the client ignores it, taking `ok` and everything
after as tunnel bytes. A proxy that passes CONNECT through and sees 2xx
then relays raw bytes, which this server parses as requests the proxy
no longer inspects. Fix: answer CONNECT 405 (or 501) before the handler.

---

## 9. LOW. Codings the server never decodes decide 400 or acceptance

**CONFIRMED.** `net.zig` 1433-1437, 1448-1454.

- `Content-Encoding: br` (or `GZIP`, or `gzip, deflate`, or a second
  Content-Encoding line) is answered 400 "bad request": the value is
  looked up in Zig's five names, case-sensitively, though the server
  never decodes a body and hands the handler `head` to read. RFC 9110
  §8.4.1: coding names are case-insensitive; an unsupported one is 415,
  and only if the server cares.
- `Transfer-Encoding: gzip, chunked` is accepted and the handler gets
  the still-compressed bytes as `body`, with no sign but the header.
  RFC 9112 §6.1: a transfer coding the server does not implement
  SHOULD be answered 501.

Fix: drop the Content-Encoding parse; answer 501 to any coding before `chunked`.

---

## 10. LOW. What is taken as a request line, a header line, and a header name

**CONFIRMED.** `net.zig` 1387-1407, 1409-1414; `std/http.zig` 41.

- Target bytes are unchecked beyond CR, LF, NUL: `GET /a b HTTP/1.1`
  gives `path == "/a b"` (the version is the last 8 bytes; RFC 9112 §3
  has no space in a target, and a proxy splitting at the first two
  spaces reads `/a`); `GET  HTTP/1.1` (two spaces) gives an empty path;
  tabs, other controls, DEL, and bytes over 0x7F pass.
- The absolute form is not reduced: `GET http://h/admin HTTP/1.1` gives
  `path == "http://h/admin"` (RFC 9112 §3.2.2: a server MUST accept
  it), so a handler routing on `/admin` answers 404 where a proxy's
  rule on the path matched, or the reverse.
- A header line with no colon (`NoColon\r\n`) is a header with an empty
  value, and ignored (RFC 9112 §5: 400).
- `header_of` trims spaces and tabs from the *name* before comparing
  (`std/http.zig` 41). Tied to the known item on whitespace before the
  colon, but a second site: the server ignores `X-Forwarded-For : 1.2.3.4`,
  a proxy that replaces `X-Forwarded-For` does not recognize it either,
  and `req.header("x-forwarded-for")` returns it (the first match
  wins, and a proxy appends its own line after). Refusing such a line
  in `HeadScan` closes both; otherwise `header_of` must not trim the name.
- An unknown method is 400; RFC 9110 §15.6.2 says 501. Cosmetic.

---

## 11. LOW. An accept error the system means as "try again" ends `serve`

**PLAUSIBLE.** `net.zig` 283-295.

`acceptOne` retries `CONNABORTED` and `INTR` and pauses on `MFILE`,
`NFILE`, `NOBUFS`, `NOMEM`; every other errno is returned, `serve`
fails, and every connection is canceled. Linux's accept(2) says pending
network errors on the new socket come back from `accept` and should be
treated like EAGAIN: `ENETDOWN`, `EPROTO`, `ENOPROTOOPT`, `EHOSTDOWN`,
`ENONET`, `EHOSTUNREACH`, `EOPNOTSUPP`, `ENETUNREACH`; `EPERM` (a
firewall rule) is per connection too. I could not make a remote trigger
concrete on a current kernel, hence PLAUSIBLE. Fix: retry those.

---

## Checked and found sound

- Views: `path`, `query`, `head` view the read buffer only when no body
  is read, and nothing reads or moves the buffer between `receiveHead`
  and the handler's return; with a body the head is copied first and
  the target re-based by offset (997-1001). `head.expect` and
  `head.content_type` are not read after the body. `Server.question`
  is an offset.
- `Conn.hold`/`release`/`fill`: `release` runs only with the reader
  empty and the writer flushed (`fill`), after `shutdown` (`linger`),
  or at `close`; no path reads or writes through a released buffer.
  `fillMore` is never called with a full buffer (the `max_head_len`
  guard at 1227; chunk heads toss all they fed; trailers stop at the
  buffer's length).
- Body reads never take bytes past the body: every read is limited by
  what remains of the length or chunk, so a pipelined request stays in
  the buffer.
- Content-Length: digits only, duplicates and lists refused, over the
  limit refused before `100 Continue`; both a length and chunked is
  read as chunked and closed after.
- `Transfer-Encoding: chunked, chunked`, `chunked` twice, a last coding
  not `chunked`: 400.
- Head: CR, LF, NUL that end no line, folded lines, more than two
  leading empty lines: 400 and close. Oversize and slow heads close.
- Expect: 417 and 413 are sent without `100`; a 413 after `100` (a
  chunked body past the limit) is final and closes.
- HEAD answers carry the length and no body; a status under 200 is 500.
- `linger` is bounded (256 KiB, about 100 sleeps); SIGPIPE has a
  handler, so a write to a closed socket fails rather than kills.
- One `close` per connection; the Registration is removed under its
  poller's lock before the descriptor closes.

---

## Dead, or could be simpler

- `respond`: `try request.writeExpectContinue()` (1106) never does
  anything: every caller has set `request.head.expect = null` (1026,
  1095). With it gone, `refuse`'s `expect = null` and the
  `HttpExpectationFailed` half of `respond`'s error set go too.
- `discardBody` (1126-1146): its `.received_head`-with-a-body branch is
  reached only by finding 1, where it crashes; for every other request
  the body was read (or the state set) before `respond`. Once `answer`
  reads every body through `bodyReader`, `discardBody` is
  `if (state == .received_head) state = if (keep_alive) .ready else .closing; return keep_alive;`,
  and since nothing in Rig's path reads `.ready` or `.closing` back
  (only `.received_head` is asserted, and `receiveHead` sets it), it
  can go entirely, with `respond` using `keep_alive`.
- `keep_alive and request.head.keep_alive` (1128): `keep_alive` is
  derived from `head.keep_alive` (992), so the second test is always true.
- `respond` computes `keep`, `after` is given `keep_alive`: two answers
  to one question, equal today.
- `Conn.fill`: `c.writer.flush()` (1976) is a no-op, `respond` having
  flushed; and it sets `c.limit` only to read `.idle` back from it
  (1975, 1977), which is `c.settings.idle_ns`.
- `Conn.limit` is set in `init`, `fill`, `connection` (twice), and
  `refuseHead`; a `head: bool` on `Conn` read by `waits()` would say it once.
- `HeadScan`: `content_type` (and `Head.content_type`) is recorded and
  never read by the server; the Content-Encoding branch and
  `transfer_compression` exist only to reproduce Zig's errors (finding
  9), as does the second-coding lookup.
- `readKept` and `readSome` are the same loop around a different buffer.
