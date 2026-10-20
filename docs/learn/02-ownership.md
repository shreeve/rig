# Ownership without a collector

Every program that allocates must answer one question: when is
memory given back? C leaves it to you, and a missed `free` leaks while
a second one corrupts the heap. Go, Java, and Python hand it to a
garbage collector, which frees memory at a moment you cannot see and
may pause the program to do it.

Rust answers at compile time, with no collector. The price is a
second language of lifetimes:

```rust
fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {
    if a.len() >= b.len() { a } else { b }
}
```

The `'a` says the result lives no longer than both arguments. You
write it, and thread it through every type that holds a reference.

Rig frees every allocation at a point you can see, with no collector
and no lifetime syntax. This chapter shows where each value is released,
how the compiler tracks a view without being told, and the one leak it
does not prevent.

## Four kinds of value

Every value in Rig is one of four kinds, and the kind decides what a
plain use does:

```rig
obj Point
  x: Int
  y: Int

sub main()
  p = Point(x: 1, y: 2)
  q = p
  q.x = 9
  names = List([3, 4])
  kept = <names
  shared = *Point(x: 5, y: 6)
  again = +shared
  view = ?kept
  print(p.x, q.x, kept.len, again.x, view.len)
```

```output
1 9 2 5 2
```

- **Plain** data owns nothing, so it copies: `q = p` makes a second
  `Point`, and changing `q` leaves `p` alone. Numbers, `Bool`, and
  objects and enums of plain parts are plain.
- An **owning** value holds a resource, such as a `List`'s memory. It
  has one owner, so it moves, and `<names` says so.
- A **handle** points at a value on the heap. `*Point(...)` makes a
  counted one, and `+shared` adds a count.
- A **view** sees a value it does not own. `?kept` lends `kept`, and
  the owner keeps it.

A bare owner never copies by accident. The compiler names the three
things you might have meant:

```rig reject
sub main()
  names = List([3, 4])
  kept = names
  print(kept.len)
```

```error
`names` owns a `List[Int]`, which can't be copied by `=`: write `<names` to move it, `+names` to clone it, or `?names` to view it
```

Only owners and handles release anything. So the rest of the chapter
asks two questions: where does an owner drop, and how long may a view
of it last?

## Where a value drops

An owner that is not moved drops where its scope ends, on every path
out of it:

```rig
obj Ticket
  id: Int

  drop(!@)
    print("ticket", @id, "closed")

sub file(t: Ticket)
  print("filed", t.id)

sub run(urgent: Bool)
  a = Ticket(id: 1)
  b = Ticket(id: 2)
  if urgent
    file(<b)
    return
  print("routine")

sub main()
  run(true)
  print("--")
  run(false)
```

```output
filed 2
ticket 2 closed
ticket 1 closed
--
routine
ticket 2 closed
ticket 1 closed
```

On the urgent path, `file(<b)` moves the second ticket into `file`,
which drops it when it returns, and the early `return` drops the first.
On the routine path, both drop at the end of `run`, the last declared
first. No path forgets a ticket, and none closes one twice.

## What `rig emit` shows

`rig emit` prints the Zig a program becomes. Here is `run`:

```text
pub inline fn run(__rig_in_urgent: bool) void {
    const urgent = rig.rt(__rig_in_urgent);
    var a = Ticket{ .id = 1 };
    defer rig.drop(&a);
    var b = Ticket{ .id = 2 };
    var __rig_alive_b = true;
    defer if (__rig_alive_b) { __rig_alive_b = false; rig.drop(&b); };
    if (urgent) {
        rig.rt(file(rig.take(&__rig_alive_b, b)));
        return;
    }
    rig.print(.{ "routine", "\n" });
}
```

Each owner gets a Zig `defer`, which runs on every way out of the
scope, in reverse order. `a` is never moved, so its `defer` is plain.
`b` may be moved, so its `defer` is **guarded** by a flag:
`rig.take` clears the flag as it hands `b` to `file`, and the `defer`
then does nothing. The cost of a move that might happen is one Boolean,
and you can read it in the output. That is the whole mechanism.

## A view out of a function

A function may hand back a view of what it was lent. Here is
`longest`, with no lifetime written:

```rig
fun longest(a: ?String, b: ?String) -> ?String
  if a.len >= b.len
    a
  else
    b

sub main()
  city = String("Lisbon")
  town = String("Porto")
  r = longest(?city, ?town)
  print(r, r.len)
  !town.add(" and Gaia")
  print(longest(city, town))
```

```output
Lisbon 6
Porto and Gaia
```

The signature is the whole contract. The result is a `?String`, and
both arguments could hold one, so `r` carries a loan on `city` and one
on `town`, until the last use of `r`. After the first `print`, `town`
may change. The lends are written where `r` keeps the result; in the
last line it is used at once, so they go unwritten.

A function may not return a view of something it owns, because that
value drops when the function returns:

```rig reject
fun longest(a: ?String, b: ?String) -> ?String
  joined = String(a, b)
  if joined.len > 10
    ?joined
  else
    a
```

```error
cannot return a view of `joined`, which this function was not lent
```

And a caller may not drop what a live result views:

```rig reject
fun longest(a: ?String, b: ?String) -> ?String
  if a.len >= b.len
    a
  else
    b

sub main()
  city = String("Lisbon")
  town = String("Porto")
  r = longest(?city, ?town)
  <town
  print(r)
```

```error
cannot drop `town` while it is lent
```

## Saying which argument: `from`

Sometimes a result views only one of the arguments. `from` says which:

```rig
use std.text

fun strip(s: ?String, prefix: ?String) -> ?String from s
  if text.starts_with(s, prefix)
    s[prefix.len..]
  else
    s

sub main()
  line = String("cmd: deploy")
  tag = String("cmd: ")
  rest = strip(?line, ?tag)
  <tag
  print(rest)
```

```output
deploy
```

Without `from s`, `rest` would keep `tag` lent too, and `<tag` would be
rejected. With it, the loan on `tag` ends as `strip` returns. The
standard library writes its own `text.strip_prefix` the same way.

`from` is not a promise you are trusted to keep. The compiler checks
the body against it:

```rig reject
use std.text

fun strip(s: ?String, prefix: ?String) -> ?String from s
  if text.starts_with(s, prefix)
    s[prefix.len..]
  else
    prefix
```

```error
`strip` returns a view of `prefix`, but its signature says it views only `s`
```

Rust would write `'a` and `'b` here. Rig writes one word, and only
when the default, every argument that could hold the result, is too
wide.

## A view a callee keeps: `keeps`

A call may also keep a view after it returns, by storing it in what it
was lent to write. `keeps` says so:

```rig
use std.text

obj Watcher
  page: ?String
  hits: Int

  sub watch(!@, page: ?String) keeps page
    @page = page

  sub look(!@, word: ?String)
    if text.contains(@page, word)
      @hits += 1

sub main()
  w = Watcher(page: "", hits: 0)
  page = String("the quick brown fox")
  !w.watch(?page)
  word = String("fox")
  !w.look(?word)
  <word
  !w.look("cat")
  print(w.page, w.hits)
  !page.add(" jumps")
  print(page)
```

```output
the quick brown fox 1
the quick brown fox jumps
```

`watch` keeps `page`, so `page` stays lent while `w` is used. `look`
keeps nothing, so `word` may drop the moment `look` returns. After the
last use of `w`, `page` may change, but not before:

```rig reject
obj Watcher
  page: ?String

  sub watch(!@, page: ?String) keeps page
    @page = page

sub main()
  w = Watcher(page: "")
  page = String("the quick brown fox")
  !w.watch(?page)
  !page.add(" jumps")
  print(w.page)
```

```error
cannot lend `page` to write while a read loan is live
```

The error's note names the call that kept it. A body that stores a
view without saying so is rejected, with the clause to write:

```rig reject
obj Watcher
  page: ?String

  sub watch(!@, page: ?String)
    @page = page
```

```error
its signature does not keep `page`; say so: `keeps page`
```

So a signature tells a caller everything a call does with its loans:
`from` says what the result views, and `keeps` what the call holds on
to. Every other loan ends when the call returns.

## Views in fields and containers

A view is a value like any other. A field may hold one, and so may a
`List`:

```rig
obj Shortlist
  all: ?List[String]
  short: List[?String]

sub main()
  names: List[String] = List()
  !names.push(String("ada"))
  !names.push(String("grace"))
  !names.push(String("alan"))
  short: List[?String] = List()
  for n in names
    !short.push(?n) if n.len <= 4
  s = Shortlist(all: ?names, short: <short)
  print(s.all.len, s.short)
  !names.push(String("edsger"))
  print(names.len)
```

```output
3 ["ada", "alan"]
4
```

No name is copied. `short` holds two views into `names`, and `s` a
view of the whole list, so `s` is a view itself and keeps `names` lent
until its last use. A `Shortlist` has no `drop` body that could read
its views, so its drop at the end of `main` is no use. The push comes
after the last use, and is accepted. Before it, the push would be
rejected: it could move the list's storage out from under `s`.

One shape is never allowed: a value that views a part of itself. Moving
such a value would leave the view pointing at its old place.

```rig reject
obj Doc
  body: String
  title: ?String

sub main()
  d = Doc(body: String("Notes on Rig"), title: "")
  d.title = ?d.body
  print(d.title)
```

```error
cannot store in `d.title` a view of `d.body`: a value never holds a view of itself
```

## Temporaries

A value that no name holds drops at the end of its statement:

```rig
obj Report
  title: String

  drop(!@)
    print("drop", @title)

fun load(name: ?String) -> Report
  Report(title: String(name))

sub main()
  print(load("monday").title.len)
  keep = load("tuesday")
  print(load("wednesday").title, keep.title)
  print("end")
```

```output
6
drop monday
wednesday tuesday
drop wednesday
end
drop tuesday
```

`load("monday")` makes a report that nothing names, a **temporary**.
It drops where its statement ends, even if the statement fails or
leaves early. `keep` names its report, so that one lasts to the end of
`main`. A view of a temporary may not outlive its statement:

```rig reject
obj Report
  title: String

fun load(name: ?String) -> Report
  Report(title: String(name))

sub main()
  t = ?load("monday").title
  print(t)
```

```error
a view of the temporary `load("monday")` outlives its statement, which drops it; bind the value to a name first
```

## Closures and their captures

A closure names everything it takes from outside, each with a sigil:

```rig
obj Log
  name: ?String

  drop(!@)
    print("log", @name, "closed")

sub main()
  count = 0
  step = 5
  bump = |!count, +step| count += step
  bump()
  bump()
  title = String("clicks")
  log = Log(name: "ui")
  show = |?title, <log, +count|
    print(log.name, title, count)
  show()
  show()
  print("count is", count)
```

```output
ui clicks 10
ui clicks 10
count is 10
log ui closed
```

The sigils mean what they mean everywhere else. `|!count|` lends
`count` to write and `|?title|` lends `title` to read, for as long as
the closure lives. `|+step|` takes a copy. `|<log|` moves the log in,
and the closure releases it once, when the closure itself goes. A bare
name in the bars is always a parameter, never a capture.

A capture's loan lasts until the closure's last use:

```rig reject
sub main()
  count = 0
  bump = |!count| count += 1
  bump()
  print(count)
  bump()
```

```error
use of `count` while a write loan is live
```

## Closures that outlive their function

A closure written as above lives in the stack frame that made it, so
it cannot be returned or stored:

```rig reject
fun counter() -> fun() -> Int
  n = 0
  |+n| n + 1
```

```error
closures cannot escape their defining scope
```

A `*` in front makes an **owned closure**: its captures move to the
heap, behind a counted handle, a `*fun(...)`. State that changes
between calls lives in a captured `Cell`:

```rig
fun counter(start: Int) -> *fun() -> Int
  n = *Cell(start)
  *|<n|
    !n.set(n.get() + 1)
    n.get()

sub main()
  next = counter(10)
  also = +next
  print(next(), next(), also())
```

```output
11 12 13
```

`also = +next` is a second handle to the same closure, so both count
from one cell. When the last handle drops, the closure drops, and the
cell with it.

An owned closure can go anywhere, so it holds no loan. It captures
owners, handles, and plain data, never a view: `*|?name| name.len` is
rejected, because the closure could outlive `name`.

## Shared state that changes

A shared handle only reads, since other handles see the same value.
What changes goes in a `Cell`, as the counter showed, by a marked call. A `Signal` is a
value plus a list of owned closures that run when it changes:

```rig
sub main()
  temp = *Signal(20)
  seen = *Cell(0)
  !temp.subscribe(*|~temp, +seen|
    !seen.add(1)
    if *temp as t
      print("now", t.get())
  )
  !temp.set(22)
  !temp.set(25)
  print("updates", seen.get())
```

```output
now 22
now 25
updates 2
```

The subscriber reads its own signal, so it captures it with `|~temp|`,
a **weak handle**. Inside, `*temp` upgrades it: a strong handle while
the signal lives, `none` after. `|+seen|` takes a second strong handle
to the counter. The signal owns the subscriber, so a strong `|+temp|`
would make each keep the other alive, and neither would ever drop.

## The one leak: a cycle

That is the one leak the compiler does not prevent: a cycle of strong
handles. A tree whose children point back at their parent is the usual
way to make one. Here the back pointer is weak:

```rig
obj Folder
  name: ?String
  files: Cell[List[*File]]

  drop(!@)
    print("drop folder", @name)

obj File
  name: ?String
  folder: ~Folder

  drop(!@)
    print("drop file", @name)

  fun path(?@) -> String
    if *@folder as f
      String(f.name, "/", @name)
    else
      String("(gone)/", @name)

sub main()
  docs = *Folder(name: "docs", files: Cell(List()))
  a = *File(name: "a.txt", folder: ~docs)
  b = *File(name: "b.txt", folder: ~docs)
  !docs.files.push(+a)
  !docs.files.push(<b)
  print(a.path(), docs.files.len)
  <docs
  print(a.path())
```

```output
docs/a.txt 2
drop folder docs
drop file b.txt
(gone)/a.txt
drop file a.txt
```

The folder owns its files through strong handles, and each file
reaches its folder through `~Folder`, which keeps nothing alive. So
`<docs` drops the folder and its list. `b.txt` had no other handle and
drops too. `a.txt` survives, because `main` holds `a`, and its `path`
finds the folder gone.

Make the back pointer strong, and the program still compiles:

```rig
obj Folder
  name: ?String
  files: Cell[List[*File]]

obj File
  name: ?String
  folder: *Folder

sub main()
  docs = *Folder(name: "docs", files: Cell(List()))
  a = *File(name: "a.txt", folder: +docs)
  !docs.files.push(<a)
  print(docs.files.len)
```

But the folder holds the file and the file holds the folder, so neither
count reaches zero. Rust and Swift leak here too. Rig does not hide it:

```text
$ rig run folders.rig
1
error: rig: memory leak detected: 3 allocations (128 bytes) never freed
note: build with RIG_LEAK_TRACE=1 set (`RIG_LEAK_TRACE=1 rig run ...`) to see where each was allocated
$ echo $?
1
```

So a child holds its parent weakly, and a callback that refers back to its owner captures it with `|~owner|`.

## What a debug build checks

`rig run` builds in Zig's debug mode with a leak-checking allocator.
When `main` ends, everything it owns is dropped, and then the check
runs: anything still allocated is reported, as above, and the program
exits with status 1. `RIG_LEAK_TRACE=1` shows where each leaked block
was allocated. Built with `RIG_SANITIZE=1`, a program also crashes at
the first use of freed memory, instead of reading a stale value.

These checks exist to catch the compiler, not you. Rig holds itself to
one rule, *accept means correct*: a program `rig check` accepts runs
with no leak, no double free, and no use of freed memory. The only
exceptions are a cycle of strong handles and code inside `raw`. Every
example here that runs does so under the sanitizing allocator, and a
leak in any of them fails the test suite.

## Summary

| Question | Rig's answer |
|---|---|
| When is an owner released? | where its scope ends, on every path, or at `<x` |
| When is a temporary released? | at the end of its statement |
| When is a shared value released? | when its last strong handle drops |
| How long does a loan last? | until the last use of every view that carries it |
| What does a result view? | every argument that could hold it, or those `from` names |
| What does a call keep? | only the arguments `keeps` names |
| What changes behind a handle? | a `Cell` or a `Signal`, by a marked call |
| What can leak? | a cycle of strong handles; break it with `~` |

Drops come from scopes, loans from the sigils, and what crosses a call
from its signature:

**Every release happens at a point you can see, and every view is
checked against the value it came from.**

## What is not there yet

- Rig has no lifetime syntax, so a few programs Rust accepts are
  rejected. A function called as a value, `f(?x, ?y)`, is known only
  by its type, which has no `from` or `keeps`: its result keeps every
  argument lent that could hold it.
- `?(a if c else b)` is planned. Today, lend each branch:
  `?a if c else ?b`.
- A `for` over a `List` of owners that a call makes, `for x in
  names()`, is planned. Today, bind the list to a name first.
- A cycle is reported at exit in a debug build, but not found or
  broken at run time. There is no cycle collector, by design.

## Where to go next

- [Errors and optionals: failure you can see](03-errors.md) shows how a
  function fails or finds nothing, and how a failure still drops every
  owner on its way out.
- [CORE](../CORE.md) states the ownership model in ten sentences, and
  [BEYOND-RUST](../BEYOND-RUST.md) compares it with Rust's lifetimes.
- The reference: [SPEC §7, Ownership](../../SPEC.md#7-ownership),
  [§8, Drop](../../SPEC.md#8-drop-and-drop-glue),
  [§9, Shared and weak handles](../../SPEC.md#9-shared-and-weak-handles),
  [§10, Cell and Signal](../../SPEC.md#10-cell-list-box-string-and-signal),
  and [§11, Closures](../../SPEC.md#11-closures).
