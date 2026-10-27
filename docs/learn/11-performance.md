# What it costs: reading the Zig a program becomes

Here is a loop from a program you have never profiled:

```python
def total(orders):
    t = 0
    for x in orders:
        t += x
    return t
```

How much does it cost? You cannot tell from the text. Each `x` may be a
heap object. The list holds pointers, and `t += x` may allocate an
integer. The answer comes from a profiler, after the program is slow.
In C the same loop shows its cost, but the language checks nothing, so a
bounds error or an overflow costs you a night instead of a nanosecond.

Rig is compiled to Zig, and you can read the Zig. This chapter shows
what a small program becomes, which lines allocate and which do not,
what each build mode checks, how to write a vector loop, how to call
C, and how the repository measures speed. Every program here runs with
`bin/rig run FILE.rig`, and prints what the `output` block below it
shows.

## Read what it becomes

`rig emit FILE.rig` checks a program and prints the Zig it becomes.
Here is a loop over a list:

```rig
fun sum(xs: ?List[Int]) -> Int
  total = 0
  for x in xs
    total += x
  total

sub main()
  orders = List([30, 12, 58])
  print(sum(orders))
```

```output
100
```

Its `sum` and `main`, as `rig emit` prints them with the startup lines
trimmed:

```zig
pub inline fn sum(__rig_in_xs: *const rig.List(i64)) i64 {
    const xs = rig.rt(__rig_in_xs);
    var total: i64 = 0;
    for (xs.*.items()) |x| {
        total += x;
    }
    return total;
}

fn __rig_run_main(__rig_init: std.process.Init.Minimal) void {
    // ...
    var orders = rig.List(i64).fromSlice(&[_]i64{ 30, 12, 58 });
    defer rig.drop(&orders);
    rig.print(.{ rig.rt(sum(&orders)), "\n" });
}
```

Read it against the Rig. `Int` is `i64`, a machine integer, and
`total` lives in a register. The loop is Zig's own `for` over the
list's storage. The read view `?List[Int]` is `*const rig.List(i64)`,
and `sum(&orders)` passes an address: the list is not copied. `orders`
is dropped by a `defer` where its scope ends, so the free is in the
text you can read. There is no collector, and nothing here that Zig
would not do.

The compiler writes the runtime, `rig/runtime.zig`, beside the
program, and `rig emit` prints a note saying where. Names that start
`__rig_` are the compiler's. `rig.rt` marks a value as known only when
the program runs, so Zig does not fold arithmetic that the checks
should see.

## What costs something

The sigils are where the costs are. This program uses a plain object, a
view, a copy, a shared handle, and a box:

```rig
obj Point
  x: Int
  y: Int

fun norm(p: ?Point) -> Int
  p.x * p.x + p.y * p.y

sub main()
  p = Point(x: 3, y: 4)
  q = p
  hits = *Cell(0)
  copy = +hits
  !copy.set(copy.get() + 1)
  boxed = ^Point(x: 1, y: 2)
  print(norm(p), norm(q), hits.get(), norm(boxed))
```

```output
25 25 1 5
```

The body of `main` becomes:

```zig
var p = Point{ .x = 3, .y = 4 }; _ = &p;
const q = p;
const hits = rig.shared(rig.Cell(i64){ .value = 0 });
defer hits.dropStrong();
var copy = hits.cloneStrong();
defer copy.dropStrong();
copy.value.set(copy.value.get() + 1);
var boxed = rig.Box(Point).init(Point{ .x = 1, .y = 2 });
defer rig.drop(&boxed);
rig.print(.{ rig.rt(norm(&p)), " ", rig.rt(norm(&q)), " ", hits.value.get(), " ", rig.rt(norm((&boxed).value)), "\n" });
```

`Point` is a plain object: two integers, held where it is declared.
`q = p` copies its bytes, with no allocation, and `norm(p)` passes a
pointer. `*Cell(0)` is the first allocation, one counted block, and
`+hits` is a count bump, not a second block. `^Point(...)` is the
second allocation, a box with one owner. A view of `boxed` reads the
box's value in place.

| Rig | Zig | Cost |
|---|---|---|
| plain value, `q = p` | `const q = p` | a copy of its bytes |
| `?x`, `!x`, a call's argument | `&x` | a pointer, checked while compiling |
| `<x`, `return x` | the value, or a flag cleared | none |
| `^x` | `rig.Box(T).init(x)` | one allocation |
| `*x` | `rig.shared(x)` | one allocation |
| `+h` of a handle | `h.cloneStrong()` | a count bump |
| `List`, `String` | `rig.List`, `rig.String` | a buffer, grown as needed; none for text of 23 bytes or fewer |
| the end of a scope | a `defer` that drops | the free, or a count drop |

A count changes only where `*x` or `+x` is written, and a view is never
counted. So to find where a program allocates, search it for `^`, `*`,
`+`, and the `List` and `String` values it builds. That is the whole
list.

## A check that was already made

Bounds checks are not free, and the compiler leaves out the ones the
program has already made. In the first function below a guard tests the
index before it is used:

```rig
fun byte_at(s: ?String, i: Int) -> U8
  if i >= 0 and i < s.len
    s[i]
  else
    0

fun byte_raw(s: ?String, i: Int) -> U8
  s[i]

sub main()
  print(byte_at("abc", 1), byte_at("abc", 9), byte_raw("abc", 2))
```

```output
98 0 99
```

The two functions index the same string, and become two reads:

```zig
return @as(u8, if ((i >= 0) and (i < rig.lenOf(s))) rig.atProven(s, i, .both) else 0);
// ...
return rig.at(s, i);
```

`rig.at` tests the index against the length and panics when it is out
of range. `rig.atProven(s, i, .both)` is the same read where the
compiler proved both tests passed, so an optimized build makes none.
`rig check --facts=proofs FILE.rig` lists the proven tests, here `3:5
index lower upper`. A Debug build still makes the test, as an
assertion, so a proof the compiler gets wrong fails a test instead of
reading past the end. The guard has to be the condition of an `if` or a
`while` on the path to the index. The proof does not follow an early
`return`.

## Three builds

A Rig program builds in one of three modes. `rig run` and `rig test`
use the first unless told otherwise.

| Mode | Flag | Checks |
|---|---|---|
| Debug | none | overflow, conversions, bounds; leaks at exit; proven tests as assertions |
| ReleaseSafe | `--release` | overflow, conversions, bounds |
| ReleaseFast | `--release=fast` | bounds and slicing only |

An overflow is a panic with status 134 in the first two. When the
compiler can see the values, it refuses the program:

```rig reject
sub main()
  level: U8 = 255
  print(level + 1)
```

```error
integer value `256` does not fit in `U8` (0..255)
```

When it cannot, the program stops at run time. This one holds a loop,
so the sum is not known while compiling:

```rig
sub main()
  level: U8 = 250
  for 0..10
    level += 1
  print(level)
```

```text
$ bin/rig run overflow.rig
panic: integer overflow
$ bin/rig run --release overflow.rig
panic: integer overflow
$ bin/rig run --release=fast overflow.rig
4
```

The fast build drops the overflow and conversion checks, and an
overflow there is undefined behavior. The `4` is what one build
printed, and nothing promises it. Indexing out of range still panics in
every mode. Debug alone checks for leaks, as [Ownership without a
collector](02-ownership.md) shows; the release builds take memory from
a faster allocator and do not look.

So develop in Debug, and build a program you ship with `--release`
unless a measurement says the checks cost too much. The terminal
benchmark below times both release modes, and the gap is small.

On Linux, a release build can also be laid out again by where it runs,
with LLVM's BOLT. `--bolt` runs the workload after `--` under `perf`,
which records the branches the program takes, and BOLT then puts the
hot code together and the cold code apart. It changes no instruction's
meaning, only where each one sits:

```text
$ bin/rig build --release --bolt -o prog prog.rig -- ./prog input.txt
$ bin/rig build --release --bolt --bolt-profile=prog.fdata -o prog prog.rig -- ./prog input.txt
$ bin/rig build --release --bolt --bolt-profile=prog.fdata -o prog prog.rig
```

The second keeps BOLT's profile, and the third lays a later build out by
it with no workload, matching what has changed since. BOLT wants many
samples: when the workload gives too few, `--bolt` says how many times
more it would like, and a longer workload, or one that runs the program
several times, gives them. It needs `perf`, and LLVM's `perf2bolt` and
`llvm-bolt` (Ubuntu's `bolt-21`, for LLVM 21). On Trig, a TypeScript
checker written in Rig, BOLT saved 7.6% to 7.9% of the cycles on
projects its profile had not seen, with the same output.

## Sixteen bytes at a time

`Simd[T, n]` is a vector of `n` lanes of one number type, held in one
register. It is plain data, so it copies like an `Int` and needs no
sigil. A comparison gives a mask, which can be asked where its first
true lane is:

```rig
type Block = Simd[U8, 16]

fun first_quote(text: ?String) -> Int?
  hits = text.read[Block](0) == 0x22
  hits.first()

sub main()
  text = "name: \"rig\", kind: lang"
  print(first_quote(text))
  v = Block.splat(200)
  print((v +| 100)[0], (v +% 100)[0])
  w = Block([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
  print((w > 8).bits().count_ones())
```

```output
6
255 44
8
```

`text.read[Block](0)` loads 16 bytes at offset 0 as one vector, after
one bounds test. `== 0x22` compares every lane with a quote at once,
and `.first()` gives the index of the first lane that matched, or
`none`. `Block.splat(200)` fills every lane. `+|` saturates and `+%`
wraps, so the lanes give 255 and 44; plain `+` would panic on this
overflow in Debug and ReleaseSafe, lane by lane, as a scalar does.
`.bits()` packs a mask into a `U64`, and `count_ones()` counts it.

The Zig is a Zig vector, which LLVM lowers to the target's own
instructions:

```zig
pub const Block = @Vector(16, u8);
// in first_quote:
const hits = rig.mask(rig.simdRead(@Vector(16, u8), text, 0, rig.Endian.little)
    == rig.rt(@as(@Vector(16, u8), @splat(0x22))));
return rig.maskFirst(hits);
```

A mask is not a `Bool`, so the compiler names the call you meant:

```rig reject
sub main()
  block = Simd[U8, 16].splat(0x22)
  hits = block == 0x22
  if hits
    print("quote")
```

```error
`hits` is a mask, `Simd[Bool, 16]`, not a `Bool`: write `hits.any()` or `hits.all()`
```

`std.json` uses this scan to find the end of a string 16 bytes at a
time. Vectors are plain data, so they cost the ownership checker
nothing.

## Calling C, and Zig

`extern fun` declares a C function, and a call to one needs a `raw`
block, which is where the checker stops vouching for the code. The
usual shape wraps the call in a safe function, so no caller needs
`raw`:

```rig
extern fun abs(n: I32) -> I32

fun safe_abs(n: I32) -> I32
  raw
    abs(n)

sub main()
  print(safe_abs(-5))
```

```output
5
```

It becomes `extern "c" fn abs(i32) i32;` and a call, and Zig links
libc. Only integers, floats, and `Bool` cross the boundary, because
the checker cannot say who owns anything else. Without the `raw`
block, the call is refused:

```rig reject
extern fun abs(n: I32) -> I32

sub main()
  print(abs(-5))
```

```error
call to extern function `abs` requires `raw` block
```

Zig is reached differently. The standard library binds functions to
Zig files with `extern zig "math.zig"`, and a call to one needs no
`raw`, since the Rig signature is checked against the Zig function's
type when the program compiles. `math.sqrt` in `std/math.rig` is one:
its emitted call is `__rig_m2_std_math.sqrt(@as(f64, 2.0))`, and in
`math.zig` its body is `@sqrt(x)`. A program of your own cannot do
this:

```rig reject
extern zig "fast.zig"
  pub fun twice(n: Int) -> Int

sub main()
  print(twice(2))
```

```error
only the standard library binds declarations to Zig code with `extern zig`
```

## How the benchmarks are run

The repository times itself in `bench/`. Each directory holds a driver
that builds Rig, Tokio, and Go versions of the same work, runs them
interleaved, keeps the fastest run of each, and compares a checksum so
that no program does less work. Each README states its rules: Rig
builds with `--release=fast`, Tokio with `cargo build --release`, and
Go with `go build`. Time on a quiet machine, since other work skews
every number.

[docs/launch/benchmarks.md](../launch/benchmarks.md) states, for an
Apple M5 with 10 cores, what a task costs:

| | spawn | chain | yield |
|---|---|---|---|
| Rig | 105 ns | 44 ns | 10 ns |
| Tokio | 172 ns | 118 ns | 42 ns |
| Go | 232 ns | 188 ns | 245 ns |

It also states where Rig is behind: `fanout`, ten tasks of CPU work,
takes 78.2 ms in Rig and 71.6 ms in Tokio, and a sleeping task holds
17.0 KiB against Tokio's 264 B.

To reproduce one, build the compiler, then run a driver on a quiet
machine. Each driver prints a table and takes `--help`. The task
benchmark needs Cargo and Go as well:

```sh
zig build                              # bin/rig
bench/tasks/bench-tasks --reps 7
```

The cost of a mode shows in `bench/terminal`, a terminal emulator
written in Rig. The README gives megabytes a second on an Apple M5,
with a load average of 8 to 28, so every number is low:

| Corpus | ReleaseSafe | ReleaseFast |
|---|---|---|
| text | 1496.2 | 1489.1 |
| scroll | 247.8 | 262.7 |
| sgr | 279.8 | 310.9 |
| tui | 455.1 | 478.0 |

Over its seven corpora the fast build is at most 13 percent ahead, so
the checks cost little here.

A smaller benchmark measures one design choice. `from_text` finds an
enum by its name, and `bench/names` times comparing the names one by
one against the table the compiler builds. The README gives
nanoseconds per lookup in ReleaseSafe on a shared Apple Silicon Mac:

| Names | Compare, hit | Compare, miss | Table, hit | Table, miss |
|---|---|---|---|---|
| 4 | 4.1 | 7.4 | 4.6 | 2.9 |
| 16 | 12.4 | 20.0 | 4.3 | 3.4 |
| 256 | 140.8 | 263.8 | 5.1 | 3.9 |

Comparing wins a hit among a few names. The table wins every miss, and
a word read from input is usually a miss, so every enum gets the table.
This one needs only Zig:

```sh
D=$(mktemp -d)
zig build-exe -O ReleaseSafe --dep nametable \
  -Mroot=bench/names/lookup.zig -Mnametable=src/nametable.zig -femit-bin=$D/lookup
$D/lookup
```

## What is not there yet

- **Raw pointers.** `raw` has Zig's builtins and C calls, and no
  pointer types, so a C function that takes a buffer or a string cannot
  be declared.
- **Your own Zig.** `extern zig` belongs to the standard library.
- **A widening vector conversion.** Widening 16 bytes into 16 `U64`
  lanes has no Rig operation, and Zig 0.17 turns LLVM's loop vectorizer
  off, so a plain loop stays scalar. The terminal writes that one loop
  in Zig for this reason.
- **A cached `rig build`.** `rig run` reuses its work, and `rig build`
  compiles in full.

## Summary

| Question | Rig's answer |
|---|---|
| What does a program become? | Zig, from `rig emit`, with the runtime written beside it |
| What allocates? | `^`, `*`, `List`, `String`; nothing else |
| What counts? | `*x` allocates, `+h` bumps, and views are never counted |
| What does a view cost? | a pointer, or a copy for a number |
| What does each build check? | Debug everything and leaks; `--release` all but leaks; `--release=fast` bounds only |
| How is C called? | `extern fun`, inside `raw`, with integers, floats, and `Bool` |
| How are benchmarks run? | `bench/*/`, same work, best of interleaved runs, on a quiet machine |

**The cost of a Rig line is the sigil on it, and the Zig it becomes is
there to check.**

## Where to go next

- [Ownership without a collector](02-ownership.md) covers the drops and
  the leak check that these builds differ on.
- [Concurrency without async](04-concurrency.md) explains the tasks that
  the benchmarks time.
- A real program, end to end, is the next journey, not written yet: a
  small service, tested and built for release.
- [WELCOME.md](../../WELCOME.md) holds the full Rig-to-Zig table,
  [INTERNALS](../internals/INTERNALS.md) the emitter and runtime,
  [simd.md](../design/simd.md) the vector design, and
  [SPEC](../../SPEC.md) the rules for `raw` and vectors.
