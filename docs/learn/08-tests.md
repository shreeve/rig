# Tests that fail the same way twice

Here is a concurrency test in Python:

```python
def test_last_seat():
    seats = Seats(1)
    with ThreadPoolExecutor() as pool:
        a = pool.submit(seats.book)
        b = pool.submit(seats.book)
        a.result()
        b.result()
    assert seats.taken == 1
```

On most runs it passes. Once in a few hundred runs it fails on the build
server, and the log says only `assert 2 == 1`. You run it again, it
passes, and the bug stays. Which thread ran first? The machine knew, and
told nobody.

Timers cause the second trouble. A test of a retry after one minute
either takes a minute or patches the clock out of the code under test.
Then it tests the patch.

`rig test` removes both. It runs the tasks of a test on one thread, in
an order that a number picks, with a clock that jumps instead of
waiting. This chapter writes tests, finds a race with a seed, replays
it, and tests a minute of sleep in no time. It ends with how the
chapters of this series are tested.

A program with an `output` block runs with `bin/rig run FILE.rig`. A
test file runs with `bin/rig test FILE.rig`, which a doc block cannot
run. So a report from `rig test` is shown in a `text` block, after a `$`
line with the command.

## A test is a block

`test "name"` declares a case among the functions of a file:

```rig
error Price
  negative
  too_many

# The price of `qty` items at `unit` cents each, a tenth off from ten.
fun total(unit: Int, qty: Int) -> Int!
  return Price.negative if unit < 0 or qty < 0
  return Price.too_many if qty > 1000
  cents = unit * qty
  return cents - cents / 10 if qty >= 10
  cents

sub main()
  print(total(250, 4)!)
  print(total(250, 10)!)

test "four items cost four times the unit"
  total(250, 4)! == 1000

test "ten items get a tenth off"
  total(250, 10)! == 2250

test "a negative quantity is refused"
  _ = total(250, -1) catch |e| return e == Price.negative
  false

test "a crowd is refused"
  _ = total(250, 5000) catch |e| return e == Price.too_many
  false

test "twelve items, written wrongly"
  total(100, 12)! == 1200

test "the total can fail"
  total(-5, 1)!
  true

test "it prints and passes"
  print(total(1, 1)!)
```

```output
1000
2250
```

`rig run` ignores the test blocks, so the file runs as a program and
prints what `main` prints. `rig test` runs the tests instead:

```text
$ rig test price.rig
ok    test "four items cost four times the unit"
ok    test "ten items get a tenth off"
ok    test "a negative quantity is refused"
ok    test "a crowd is refused"
FAIL  test "twelve items, written wrongly": total(100, 12)! == 1200 is false
FAIL  test "the total can fail": Price.negative
1
ok    test "it prints and passes"
5 passed, 2 failed
seed 1: `rig test --seed=1` runs these tests the same way again
$ echo $?
1
```

A test body is checked like a function that may fail. Its last line
decides, as a function's last line gives its value. A `Bool` that is
`false` fails the test. So does a `!` that passes an error out, and so
does a panic. Anything else passes. What a test prints appears above
its report line.

The reason after `FAIL` names the cause. For a `false`, it is the source
of the `Bool`. For a `!`, it is the error. A `return false if n > 2`
gives the rest of its line, and a bare `false` as the last line gives
its place. To expect an error, `catch |e|` decides with a `return`, and
the `false` after it fails the test when no error came.

A run in which a test failed exits with 1, so a script sees it. The
final line names a seed, which the rest of the chapter explains.

## A test that leaks fails

`rig test` builds in Debug mode, where every allocation is recorded.
When a test ends, anything it left allocated fails it. The cycle from
[Ownership](02-ownership.md) is the leak the compiler allows:

```rig
obj Folder
  name: ?String
  files: Cell[List[*File]]

obj File
  name: ?String
  folder: *Folder

test "a file in a folder"
  docs = *Folder(name: "docs", files: Cell(List()))
  a = *File(name: "a.txt", folder: +docs)
  !docs.files.push(<a)
  docs.files.len == 1

test "a plain list"
  xs = List([1, 2, 3])
  xs.len == 3
```

```text
$ rig test leak.rig
error: rig: memory leak detected: 3 allocations (128 bytes) never freed
note: build with RIG_LEAK_TRACE=1 set (`RIG_LEAK_TRACE=1 rig test ...`) to see where each was allocated
FAIL  test "a file in a folder": memory leak
ok    test "a plain list"
1 passed, 1 failed
seed 1: `rig test --seed=1` runs these tests the same way again
```

The first test ends in `true` and still fails: the folder holds the
file and the file holds the folder, so neither is ever released. The
second test is not blamed. The check runs after each test, so a leak is
pinned to the test that made it. To see where the leaked blocks came
from, run the tests again with `RIG_LEAK_TRACE=1` set: after the
summary, each allocation a test left is shown with its stack trace.

`rig test --release` builds in Zig's safe mode, which records nothing.
The same file then reports `2 passed, 0 failed`. Run the suite in the
default mode.

## Tests beside the code

`rig test X` runs the tests of `X` and no others. For a file, those are
its own `test` blocks. The tests of the modules it imports, the standard
library's included, are checked and not run. A directory module also
reads its `*_test.rig` files:

```rig file=cart/cart.rig
error Price
  negative

pub fun total(unit: Int, qty: Int) -> Int!
  return Price.negative if unit < 0 or qty < 0
  discounted(unit * qty, qty)

fun discounted(cents: Int, qty: Int) -> Int
  return cents - cents / 10 if qty >= 10
  cents
```

```rig file=cart/cart_test.rig
test "ten items get a tenth off"
  discounted(2500, 10) == 2250

test "a negative price is refused"
  _ = total(-1, 2) catch |e| return e == Price.negative
  false
```

```rig
use cart

sub main()
  print(cart.total(250, 10)!)
```

```output
2250
```

The test file sees the private names of its module, `discounted` and
`Price`. `rig run`, `rig check`, and a program that imports `cart` leave
the test file out, so it adds nothing to a program that uses the module:

```text
$ rig test cart
ok    test "ten items get a tenth off"
ok    test "a negative price is refused"
2 passed, 0 failed
$ rig check --tests cart
```

`rig check --tests` checks what `rig test` would build, without
building or running it. It prints nothing when the tests are well formed.

## One thread, a clock, and a seed

A program that makes tasks runs them on a worker per core, so what
happens first depends on timing. This program starts three tasks:

```rig
sub say(id: Int)
  print("task", id)

sub main()
  a = say(1)&
  b = say(2)&
  c = say(3)&
  >a
  >b
  >c
```

It has no one right output. Run it a few times and the lines change
places:

```text
$ rig run said.rig | tr '\n' ' '
task 3 task 2 task 1
$ rig run said.rig | tr '\n' ' '
task 2 task 1 task 3
```

`--seed=N` runs the same program deterministically. The tasks share one
thread, and the seed picks which ready task runs next, and whether a
long loop lets another run. The same seed makes the same choices:

```text
$ rig run --seed=1 said.rig | tr '\n' ' '
task 2 task 1 task 3
$ rig run --seed=1 said.rig | tr '\n' ' '
task 2 task 1 task 3
$ rig run --seed=2 said.rig | tr '\n' ' '
task 2 task 3 task 1
$ rig run --seed=4 said.rig | tr '\n' ' '
task 1 task 2 task 3
```

`rig test` always runs this way, with seed 1 unless told another. A
program started with `RIG_SEED=N` in its environment runs as `--seed=N`
does. A seed is a whole number, and `--seed` applies to `run` and
`test`. Different seeds are different schedules, so a range of seeds
walks through many of the orders a real run could have chosen.

## A race, found and replayed

The compiler rules out one kind of race. Two tasks cannot write one
list, so a test never needs to look for that:

```rig reject
sub add(xs: !List[Int], n: Int)
  !xs.push(n)

test "two tasks append to one list"
  xs = List[Int]()
  a = add(!xs, 1)&
  b = add(!xs, 2)&
  >a
  >b
  xs.len == 2
```

```error
cannot lend `xs` to write while a write loan is live
```

What remains is a race of order: tasks that share state safely but are
not told who goes first. This test assumes that the task started first
speaks first:

```rig
obj Log
  lines: List[Int]

  sub add(!@, n: Int)
    !@lines.push(n)

  fun first(?@) -> Int
    @lines[0]

sub announce(log: *Actor[Log], id: Int)
  !log.add(id)

test "the first task started speaks first"
  log = *Actor(Log(lines: List[Int]()))
  a = announce(+log, 1)&
  b = announce(+log, 2)&
  >a
  >b
  log.first() == 1
```

Under seed 1 it passes. `--seeds=20` runs the tests again with each
seed from 1 to 20, and stops at the first run that fails:

```text
$ rig test --seeds=20 order.rig
ok    test "the first task started speaks first"
1 passed, 0 failed
FAIL  test "the first task started speaks first": log.first() == 1 is false
0 passed, 1 failed
seed 2: `rig test --seed=2` runs these tests the same way again
```

Seed 2 starts the second task first. The report ends with the command
that repeats the failure, and it repeats it every time:

```text
$ rig test --seed=2 order.rig
FAIL  test "the first task started speaks first": log.first() == 1 is false
0 passed, 1 failed
seed 2: `rig test --seed=2` runs these tests the same way again
```

`RIG_SEED=2 rig test order.rig` gives the same report. A `print` in
`announce`, or a look at the log, sees the same run each time. The failure is no longer luck. The failing order was possible
all along, and the seed found it. The fix is to stop asking for an order
the program never promised:

```rig
obj Log
  lines: List[Int]

  sub add(!@, n: Int)
    !@lines.push(n)

  fun len(?@) -> Int
    @lines.len

  fun total(?@) -> Int
    @lines.sum()

sub announce(log: *Actor[Log], id: Int)
  !log.add(id)

test "both tasks speak, in either order"
  log = *Actor(Log(lines: List[Int]()))
  a = announce(+log, 1)&
  b = announce(+log, 2)&
  >a
  >b
  log.len() == 2 and log.total() == 3
```

```text
$ rig test --seeds=20 fixed.rig | tail -2
ok    test "both tasks speak, in either order"
1 passed, 0 failed
```

All twenty runs pass. Each prints a report, and the pipe keeps the last.
`--seed` and `--seeds` exclude each other, and `--seeds` takes a count of
at least 1 and applies to `test` alone.

## Sleeps that take no time

The clock a test sees is virtual. It reads 0 at the start, and it moves
in two ways. When no task can run, it jumps to the next timer. So a
sleep ends at once, however long it asks for:

```rig
use std.time

fun slow(ms: Int) -> Int!
  time.sleep(ms * time.MS)!
  ms

test "a deadline stops a slow call"
  r = time.within(5 * time.MS, || slow(60_000)!) catch -1
  r == -1

test "a call inside its deadline answers"
  r = time.within(50 * time.MS, || slow(20)!) catch -1
  r == 20

test "a minute of sleep is a minute of virtual time"
  start = time.now()
  time.sleep(time.MINUTE)!
  print(start.elapsed() / time.SECOND)
  start.elapsed() >= time.MINUTE
```

```text
$ rig test deadline.rig
ok    test "a deadline stops a slow call"
ok    test "a call inside its deadline answers"
60
ok    test "a minute of sleep is a minute of virtual time"
3 passed, 0 failed
seed 1: `rig test --seed=1` runs these tests the same way again
```

`time.within(ns, f)` gives the closure `f` a deadline. The call that
sleeps sixty seconds stops at five milliseconds, with a timeout that
`catch` turns into `-1`. The third test sleeps a whole minute, and the
clock reads sixty seconds afterward. The file reports in a fraction of a
second once built.

The other way is a yield check. Each yield check and each `task.check()`
moves the clock one microsecond, so a loop that never waits still
reaches its deadline. Two calls of `task.check()` after a start read
2,000 nanoseconds there, and a sleep of two seconds then reads
2,000,002,000. The wall clock, `time.unix_ns()`, stays real.

Suppose every task waits on another and no timer is set. None can ever
run. Run normally, a wait on a channel that nothing will send to hangs,
as it would in Go. Under a seed, the clock has nowhere to jump, and the
run panics:

```rig
sub stuck(c: *Chan[Int])!
  v = (!c).recv()!
  print(v ?? 0)

test "a wait with no sender"
  c = *Chan[Int](1)
  t = stuck(+c)&
  >t!
```

```text
$ rig test stuck.rig
FAIL  test "a wait with no sender": panicked
0 passed, 1 failed
seed 1: `rig test --seed=1` runs these tests the same way again
panic: every task is waiting on another, and none can run: a deadlock
```

A stack trace follows the panic, and the status is 134. A panic ends the
whole run, so the tests after it never start. Put tests that may panic
last, or in a file of their own.

## Markdown that is tested

The chapters of this series are tests too. Every ```` ```rig ```` block in
the Markdown files of the repository is a case that the suite runs, so a
doc cannot say something the compiler no longer does. The words on the
fence set the contract:

| Block | The suite checks that |
|---|---|
| ```` ```rig ```` and an ```` ```output ```` block | the program runs, prints exactly the output, and leaks nothing |
| ```` ```stderr ```` after it, or ```` ```stderr exit=N ```` | stderr is exactly the block, and the status is N |
| ```` ```rig ```` alone | `rig check` accepts it |
| ```` ```rig reject ```` and an ```` ```error ```` block | the compiler rejects it, and each error line is in a diagnostic |
| ```` ```rig file=m.rig ```` | it is module `m.rig` of the next program |
| ```` ```rig fragment ```` | it parses |
| ```` ```text ```` | nothing: it holds what the suite cannot run |

Here is a block with a status:

```rig
fun main() -> Int
  print("checked")
  warn("exit status next")
  3
```

```output
checked
```

```stderr exit=3
exit status next
```

Change the 3, the text, or the output, and the build fails at the line
of the fence. Each doc is an area named for its file, so one chapter
runs alone: this one is `doc-learn-08-tests`, run with `swarm
test/rig.rip doc-learn-08-tests` from the Rig directory.

The suite starts a doc block with `rig run`, which cannot run a test
block. So the programs of this chapter that hold tests are checked as
programs, and their reports sit in `text` blocks, which nothing checks.
Rig's own tests use what this chapter teaches instead. They are files of
named cases, and the concurrency cases carry `seeds: 20`, so each runs
again under twenty schedules and must give the same result every time.

## Summary

| To | Write |
|---|---|
| declare a test | `test "name"` and a body that ends in a `Bool` |
| fail a test | a `false`, a `!` that passes an error out, a panic, or a leak |
| run a file's tests | `rig test FILE` |
| run a directory module's tests | `rig test DIR`, with tests in `*_test.rig` |
| check tests without running | `rig check --tests X` |
| run under many schedules | `rig test --seeds=20 FILE` |
| replay a failing schedule | `rig test --seed=N FILE`, or `RIG_SEED=N` |
| run a program on a seed | `rig run --seed=N FILE` |
| test a wait | sleep and deadlines in the test: the clock jumps |

A test runs with one seed and a virtual clock. **The same seed gives the
same run, and a failing run names the seed that repeats it.**

## What is not there yet

- A test cannot expect a panic. A panic fails the test and ends the
  run, with status 134. Expected errors are values, and `catch` tests
  them.
- `rig test` runs every test of a file, in order. There is no flag to
  pick one by name.
- `--seeds=K` stops at the first failing seed, so it names one race at a
  time.
- `RIG_LEAK_TRACE=1` shows a test's leaks with their traces only after
  the summary, all together, and only when the run ends without a
  panic.
- Tests run tasks on one thread. They find races of order, and never
  run two tasks at the same instant on two cores.
- A doc block cannot run `rig test`, so no suite checks the reports in
  this chapter.

## Where to go next

[Safety you can trust](09-safety.md) is the next journey: what Rig
promises, where `raw` suspends it, and how the promises are checked.
A real program, end to end, still to come, grows a service with seeded
tests.

- [SPEC, Tests](../../SPEC.md#tests) states every rule of test blocks,
  the seed, and the virtual clock.
- [Concurrency without async](04-concurrency.md) is the chapter on tasks
  that the seeds schedule.
- [The test runner](../internals/tests.md) gives the doc contract in
  full, and [the test suite](../../test/README.md) how the suite runs.
