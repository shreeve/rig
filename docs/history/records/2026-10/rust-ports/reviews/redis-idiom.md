# Idiom and beauty review: mini-redis (2026-10-30)

Every change below was made in a copy and run with
`RIG_OUT_DIR=$tmp RIG_SANITIZE=1 rig test --seeds=20 redis`, `bin/rig` at main `71bbc1820`: all
16 tests pass on seeds 1 to 20, sanitized, and on 5 seeds with `--release`; `server.rig` and
`cli.rig` check, and the two binaries were run against each other (ping with and without a
message, set with and without PX, get before and after expiry, publish to a subscriber). All
changes together are in `reviews/redis-idiom-probes/` (a full tree: `redis/`, `server.rig`,
`cli.rig`); `reviews/redis-idiom-probes/naming/` is the same tree with the naming option of
question 3. Nothing under `compare/` was edited.

The port is good Rig. `Bytes = *Frozen[String]`, `*Actor[Db]` with `get` checking the expiry,
shutdown as the cancel of `main`, the permit channel with `defer`, `pub ?subscribed`,
`fun Db.size` in the test file, `parts(...) -> (?List[Frame])? from f`, and `?? return` on every
early out are the right forms. The changes are about one form per idea, and the place of
subscribe mode's wait.

Counts (`sloc.py`): server library 381 lines and 3,807 tokens before, 384 and 3,776 after;
client 100/1,051 to 100/1,044; binaries 65/543 to 61/535; tests 205/1,823 to 201/1,785.

## Ranked

1. **Variant shorthand wherever the type is known** (27 lines). probed
2. **Subscribe mode's wait is `Subscription.next`**, and its comment is timeless. probed
3. **Write calls in the short form, and a discarded `Bool` with no `_ =`** (4 places). probed
4. **`bytes(s)` in the library** for the five `*Frozen(String(...))`. probed
5. **Publish lends each inbox to its send** instead of a new handle per message. probed
6. **`Args`: `@expected()`, `next` in reading order, `match lower(...)`.** probed
7. **cli: `msg` and `ttl` as values.** probed
8. **`db.set`: `at < (@next_expiration() ?? Int.max)`.** probed
9. **Comments: no probe paths in code; one `stop(t)` for both test files.** probed

## 1. Variant shorthand (probed)

```
before:                                              after:
  cmd = match name                                     cmd: Command = match name
    "get" => Command.get(key: !args.next_string()!)      "get" => .get(key: !args.next_string()!)
    ...                                                  ...
    _ => return Command.unknown(name: <name)             _ => return .unknown(name: <name)
  !conn.write_frame(Frame.simple(text: String("OK")))! !conn.write_frame(.simple(text: String("OK")))!
  !f.push(Frame.integer(n: n))                         !f.push(.integer(n: n))
  frame = match src[pos]                               frame: Frame = match src[pos]
    '+' => Frame.simple(text: ...)                       '+' => .simple(text: ...)
```
Why: the type is already said by the parameter (`push`, `write_frame`), the binding, or the
function's result; `Frame.` and `Command.` on 30 lines is noise, and the matches that read frames
already write `.bulk(data: d) =>`. The ray port took the same change. Kept qualified: errors
(`return Proto.not_array`, as SPEC writes them), `Frame.array(items: List())` bindings, and
`Frame.text(...)` (a function, not a variant). The `set` arm of `from_frame` drops from 106
columns to 99.

## 2. `Subscription.next` (probed; the builder's question 1)

```
before:                                          after:
  while next(!s.inbox, !conn)! as m                while !s.next(!conn)! as m
  ...
# ... It polls the inbox and the socket in       obj Subscription
# turn: one inbox, once a stream can be split.     ...
fun next(inbox: !*Chan[Msg], conn: !Connection)    # The next message or frame for the connection, or
  ...                                              # none once its client closes. It waits on the
    m = time.within(POLL, |!inbox| ...)            # inbox, then on the socket, for POLL each, in turn.
    ...                                            fun next(!@, conn: !Connection) -> Msg?!
    frame = <f ?? return none                        ...
    return Msg.frame(f: <frame)                        m = time.within(POLL, |!@inbox| !@inbox.recv()!) ...
                                                       ...
                                                       return Msg.frame(f: <f ?? return none)
```
Why: the inbox is the Subscription's, so its wait is its method, and the loop reads as "while
the subscription has a next message". The closure captures the one field, `|!@inbox|`. The old
comment ("once a stream can be split") said what is planned, not what is.

**Is the shape right for `split()`?** Yes, with one correction to "split changes only `next`":
the reader task must end subscribe mode with a message of its own, not by closing the inbox.
Publishers hold handles to the inbox, and a send on a closed channel panics
(`port-probes/redis-send-after-close.rig`). So `Msg` gains `closed` (or `frame(f: Frame?)`), the
reader task is started in `subscribe`, and `next` becomes `!@inbox.recv()!` with `conn` the
Writer.

## 3. One form for write calls (probed)

```
before:                                            after:
  _ = (!@subscribed).add(+c)                         !@subscribed.add(+c)
  _ = (!@channels).add(+name)                        !@channels.add(+name)
  (!@channels).ensure(<channel, Map()).put(...)      !@channels.ensure(<channel, Map()).put(...)
  if (!@channels).edit(channel) as subs              if !@channels.edit(channel) as subs
```
Why: SPEC: "A `Bool` call whose value is discarded is short too: a statement `!set.insert(k)`".
The port already wrote `if !@expirations.pop() as e` and `x = !v.pop()`; now it writes no long
form anywhere.

## 4. `bytes(s)` (probed)

`pub fun bytes(s: ?String) -> Bytes` beside `type Bytes` in frame.rig. `Frame.text` uses it,
cli writes `redis.bytes(words[1])` three times for `*Frozen(String(words[1]))`, and
client_test's private copy goes, which db_test was quietly using across files.

## 5. Publish lends each inbox (probed; clearer and faster)

```
before:                                            after:
  for inbox in inboxes                               for inbox in !inboxes
    ...                                                ...
    time.within(time.MS, |+inbox, <m| ...)             time.within(time.MS, |!inbox, <m| ...)
```
Why: the closure only sends, so it is lent the inbox to write, as `next` lends `|!conn|`. The
clone was an atomic count up and down per subscriber per message. Not timed (the speed
reviewer's).

## 6. `Args` (probed)

```
before:                                       after:
  @at += 1                                      f = ?@items[@at]
  ?@items[@at - 1]                              @at += 1
                                                f
  unit = lower(!@next_string()!)                scale = match lower(!@next_string()!)
  scale = match unit
  return Proto.expected(at: @at - 1)   (x4)     return @expected()
                                              # The argument just read, which is not of the kind
                                              # the command expects.
                                              fun expected(?@) -> Proto
                                                Proto.expected(at: @at - 1)
```
Why: `from @items` lets `@at` change while `f` views the item, so `next` reads in order; the
`- 1` arithmetic is said once.

## 7. cli values (probed)

```
before:                                           after:
  msg: redis.Bytes? = none                          msg: redis.Bytes? = redis.bytes(words[0]) if words.len == 1 else none
  if words.len == 1
    msg = *Frozen(String(words[0]))
  ttl: Int? = none                                  ttl: Int? = text.parse_int(words[2])! * time.MS if words.len == 3 else none
  if words.len == 3
    ttl = text.parse_int(words[2])! * time.MS
```
Why: no value made only to be overwritten (ray change 4). Run by hand: `set k v` and
`set t v 50` both work, so the `!` branch is not evaluated when not taken. cli's two lines over
100 columns (the subscribe print, the usage) are as before.

## 8. `db.set`'s wake test (probed)

`if not @woke and (@next_expiration() ?? at + 1) > at` becomes
`if not @woke and at < (@next_expiration() ?? Int.max)`: "it expires before the next one, or
there is none". `at + 1` was a trick to read past. (Merging the two `if`s above it into one
header was tried: 115 columns, kept as two.)

## 9. Comments and tests (probed)

- `server.rig`: `# Rebound, so each command is lent this one handle to write.` without the
  probe path; client_test and frame_test lose their probe-path comments. Gap notes belong in
  notes.md/README (the tml review's rule).
- `stop(t: Task[Void!])` ("Cancels `t` and waits for it to end: a test that gets this far
  passes") ends db_test too, replacing its copy of the two lines and its `use std.task`.

## The builder's other questions

- **`woke` (q2):** right. With no `try_send` it is the least that keeps the actor from blocking:
  the flag is clear only after the purge task took the wake, so the one-slot send never waits.
  The three words `wake`, `woke`, `woken` are a lot of one verb; `waking` (the reader's draft)
  is a candidate. Owner's call; not changed.
- **`Frame.text` / `Frame.str` (q3):** Rig's own word for "the text of a value" is `text`
  (`e.text` of an enum, `s.text` of a symbol), and `Frame.text("px")` makes a *bulk* frame
  beside a `simple(text:)` variant, which misleads. Candidates, each probed in `naming/`:
  - (default) `Frame.of(key)` and `f.text()`: `!req.push(Frame.of(key))`,
    `String(f.text() ?? return @expected())`;
  - `.bulk(data: bytes(key))` and `f.text()`, no constructor: 7 more characters a use, 11 uses;
  - keep `text` and `str` (std.json has `get_str`).
- **Strings, not a `Verb` enum (q4):** right. `Verb.from_text(name)` works only for a plain
  enum, so it would be a second closed set beside `Command`; `match name` with `"get" =>` is
  the one.
- **Directory module (q5):** right regardless of gap 1: it is what lets `*_test.rig` files and
  `fun Db.size` share the namespace, and it drops every `use frame`.

## Gaps

Each of the builder's six, re-run on main `71bbc1820`; all confirmed:

| # | Probe (`port-probes/`) | Result on main |
|---|---|---|
| 1 | `redis-actor-cross-module/` | rejected: "no method `bump` on `m.Counter`, the value of actor `a`" |
| 2 | `redis-optional-variant-eq.rig` | rejected: "`==` is not defined for `Tree?`: field `node.kids` is a `List[Tree]`" |
| 3 | `redis-actor-param-lend.rig` | rejected with the misleading "pass `+db`" message |
| 4 | `redis-frozen-field-compare.rig` | rejected: "cannot compare `*Frozen[String]` with `Static`"; also `c = ?m.content` then `c == "world"`: the view is of the handle |
| 5 | `redis-list-of-owners.rig` | rejected; note `[a, b]` of owned Frames is accepted as an array, only the List is missing. Same class: client_test's `strings` and cli's channel loop (List[String] from text) |
| 6 | `redis-void-catch-if.rig` | rejected: "`if` used as a value requires an `else` branch" |

New:

- **N1. A bare read argument through an actor is rejected** (`redis-actor-bare-read-arg.rig`).
  `d.get(k)` on a plain object is accepted; `a.get(k)` through `*Actor` is rejected with
  "`a.get(k)` keeps `k` lent in what `get` stores; write `a.get(?k)`", though `get` declares
  no `keeps` and returns an owned value. QUICK: "Reading is unmarked". It forces `db.get(?key)`
  and `db.subscribers(?channel)` in cmd.rig. A bug or a message to fix; to Rig - Helper.
- **N2. std.text has no ASCII lower case of a String** (`redis-text-lower.rig`):
  `text.to_lower` takes a byte, so cmd.rig carries a five-line `lower`. Small std ask.
- **N3. For `split()`:** `redis-send-after-close.rig` (above, question 1).

## Sigils and forms: used and not used

Counted in the improved tree, comments excluded (approximate where a regex counts).

| Used | Where |
|---|---|
| `<x` move (82), `+x` (22), `?x` (30), `!x` (254) | everywhere; `!` mostly `!conn.write_frame`, `!args.next_*`, `!req.push` |
| `?T`, `!T` parameters (23, 13); `!*Actor[Db]` (4) | views throughout; the actor handle lent down |
| `?@` (11), `!@` (31), `<@` (`Command.apply`, `Client.subscribe`) | `apply` consumes the command; `subscribe` turns the Client into a Subscriber |
| `*Frozen` (8), `*Actor` (11), `*Chan` (13) | Bytes, Db, inboxes, wake, permits |
| `T?`, `T!`, `e!` (219), `??` (27, 25 of them `?? return`) | the protocol's every early out |
| `as` (19), `while ... as` (4), `return x if c` (34), `x if c else y` (4) | |
| `catch` (12; `catch \|e\|` 8), `defer` (2), `new x = <x` (3) | |
| `f()&` (7), `>t` (3, tests only), `Tasks`, `time.within` (6) | |
| `from` (5), closures with `+ ! <` captures (8), a field capture `\|!@inbox\|` | |
| variant shorthand (27 lines), match guards (2), several results (`port, server = ...`) | |
| `pub ?field`, `obj T: Ord`, `type` alias, `fun Db.size` in a test file, `Static` | |

| Not used | Why |
|---|---|
| `~` weak | the natural place is the Db's subscriber list (a dead connection's inbox vanishes by itself), blocked by G15 (decision 2). The port's use of `~` is waiting on that gap, not missing |
| `^` box | nothing recursive needs a box: `Frame.array` holds a `List`, already on the heap |
| `<x` alone (drop now) | every drop falls where its block ends; nothing needs dropping early |
| `=!` | no local is ever rebound by mistake; no finished port uses it (examples do, twice) |
| `keeps`, `drop(!@)`, `Cell`, `Signal` | the actor holds what Rust shares, so nothing stores a view, runs a drop body, or shares a cell |
| `task.select` | it selects on channels only, and the wait is a channel and a socket (G6); after `split()` one inbox needs no select |
| `:symbol`, `api`/`add`, `?{A}`, `Table`, `Simd`, `raw`, compile-time functions | no use here; commands are runtime text |

For the owner's "why support them": in this port the unused ones are absent for a reason the
program shows (`~` blocked by G15, `select` made moot by `split`), except `=!`, which none of
the finished ports has needed.
