# Clarity review (expert 2, the reader's lens)

## Q1: the draft CORE line is false for Cells and channels
Probed with sched-pair-test's `bin/rig`: through a handle, `!` before a call lends one of two ways. A Cell's, a Cell-holding object's, or a channel's call lends **self to write**: `!c.add((!c).swap(4))` and `!ch.send((!ch.recv()! ?? 0) + 5)!` are rejected ("lent to write here, as `self`"). An actor's call lends **the handle to read**: `(!a).add((!a).add(1))` runs, and `grow(!xs)` in its argument is rejected ("lent to read"). So the line must name the actor, and "lends nothing" goes in both CORE and SPEC "Actors".

## Q3: the SPEC sentence
"Holds the channel's place to read" is vague: the loan sits on the place that holds the handle (`chs`), not on the channel. Knowing `!ch.recv()` lends to write, a reader guesses two arms clash; give the reason they do not.

## Q4: also inconsistent
- CORE §4 row `*T`: "`!h` lends the handle itself" is wrong for a value holding a Cell. `hit(!h)` to `h: !Hits` is accepted; `f(!u)` to `u: !User` is rejected. The cell should read: "the handle itself, `!*T`; of a value that holds a Cell, also a `!T` that changes only its Cells".
- Sentence 9 says only a Cell changes what you share; actors and channels do too. Add "(an actor or a channel changes as SPEC §18 says)".
- SPEC "Actors" should read: "The `!` marks the call, which lends the handle only to read: the actor changes its own value."

## CORE §4, after the table
Through a handle, `!` marks a change, and needs a handle you hold, never a read view of one. A value that holds a Cell, and a channel, are lent to write, and only their Cells or the channel change: `!c.set(5)`, `!h.bump()`, `!ch.send(<v)!` (sentence 9). An actor's `!a.add(x)` is a message: the actor changes its own value, and the call lends the handle only to read. Through any other `*T` a change is rejected, `!h.push(x)` too, and `!h` alone lends the handle itself, `!*T`. *(built)*

## SPEC "Channels", after "until the select returns."
An arm's `!ch` lends the handle only to read, since the arm changes nothing until the select commits it: two arms may name one channel, and a write to the handle's place before the select returns is rejected.

```rig
use std.task

sub main()!
  ch = *Chan[Int](1)
  !ch.send(7)!
  match task.select(got: !ch.on_recv(), put: !ch.on_send(8))!
    .got(v?) => print("got", v)
    .got(none) => print("closed")
    .put => print("put")
```

```output
got 7
```

```rig reject
use std.task

fun grow(chs: !List[*Chan[Int]]) -> Int
  !chs.push(*Chan[Int](1))
  8

sub main()!
  chs = List[*Chan[Int]]()
  !chs.push(*Chan[Int](1))
  match task.select(got: !chs[0].on_recv(), put: !chs[0].on_send(grow(!chs)))!
    .got(v?) => print("got", v)
    .got(none) => print("closed")
    .put => print("put")
```

```error
cannot lend `chs` to write while a read loan is live
```

Both checked: `got 7`, and the rejection at 10:72.
