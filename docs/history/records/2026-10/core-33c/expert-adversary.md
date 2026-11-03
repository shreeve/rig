# Row 33C, draft 1: the adversary's review (programs)

Against main 928b44bf2 (`.git/rig-baseline/928b44bf2.../rig`), every program run with
`RIG_SANITIZE=1`. The oracle is the newest built one on the machine,
`~/Data/Code/worktrees/rig/hash-int-spread/bin/rig-oracle` (built 2026-10-31 01:25 from a base a
day before 928b44bf2; the worktree of this review has no `bin/rig-oracle`), run as
`rig-oracle --sema -v FILE`. The programs are in
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-rig-language-analysis-aa0a1d/67c60f05-c7b3-4699-a1a3-55125acb3379/scratchpad/c33/adv/`;
each one, with main's and the oracle's output, is in the appendix at the end.

## Verdict

The goal is right and the oracle agrees with it: a `for` over a call that returns a read view of
a place should read it in place, as the bound form `r = first_list(?ls); for x in r` already does.
The positive list as written would break three ways if it replaced the deciders it names, and it
gets five sound programs wrong. Two of the draft's claims are false on main.

The method: every program the draft would newly accept has a bound-name form and an Int-element
form that main already decides. Main and the oracle agree on all of them. The draft must give the
same verdict for the `for`-over-a-call form.

## 1. The oracle on the draft's main example

`a00_main.rig`: `main prod=sema ref=unknown (a type with an error)`. Typecheck gives the loop
element an invalid type, so the oracle abstains. It decides nothing on the draft's example today.
On the bound form (`a00b_bound.rig`) it gives `prod=accept ref=accept`, and on the Int-element form
(`c00_ints_ok.rig`) `prod=accept ref=accept`. The oracle's lowering of a `for` over a call
(`test/oracle/lower.zig`, `.iter` with `madeSubject`) takes the call's result, which here is a
view, into a hidden var of the loop, and that var carries the argument's loans. That is the
draft's reading. Once the compiler types the loop, the oracle should accept `a00` and reject
`a05` (the body writes `ls`) with C4, as it does for `a03`.

## 2. Programs the draft would wrongly accept

Main rejects every one of these today. The draft would accept them only if its fact replaced the
existing deciders (`isTemporary`, `rejectHeaderCopy`, the header subject rules) and the
ownership checker's carried loans, which is what "Who records it, who reads it" proposes.

### 2a. A made argument lent with no sigil (`b02`, `b03`, `e05`, `h02`, `h04`, `l02`)

`for x in first_list(mk())`, `for x in mk().all()` (self, `from @items`),
`for x in items_of(mk())` (`?{Src}`), `for x in boxed().items()` (`^{Src}`),
`if first(mk()) as s`, `first_list(+ls)`.

The IR has no lend node at the argument: `(call _ first_list (call _ mk))`, and
`(member (call _ mk) all)` for self. The argument expression `mk()` is of owning kind, so the
draft's first row gives it `none`. The call row then fails both ways: `mk()` is not "a place or
views one", and it does not "view a value made in the statement", because it *is* that value.
An implementation that reads "not made" as `place` lets the loop read a List inside a temporary
the header has already dropped.

- **Main:** rejected. Ownership reports "a view of the temporary `mk()` outlives its statement",
  or typecheck reports the loop rule.
- **Oracle:** rejects the Int forms with C5.
- **CORE:** reject (§3).
- **Fix:** the call row asks what each origin argument's *lend* views. A made value lent where a
  view goes (a bare argument, an unmarked `?@`, `+x` into a view) views `made`.

### 2b. The first row decides by the type's kind (`e01` to `e04`; `b07`, `b08`)

`if pick(?mk())[0] as s`, `match pick(?mk())[0]`, `if pick(mk())[0] as s`,
`if mk().all()[0] as s`.

The subject's type is `String?` or `Shape`, both of owning kind, so the first row gives `none`
("owns what it holds"). In fact it lies inside a temporary, reached through a view.

- **Main:** typecheck rejects: "this header binds a copy of its subject, since a temporary it
  makes ends with the header".
- **Oracle:** rejects with C5.
- **Under the draft:** if `isTemporary` reads the fact, these are accepted, and `s` views freed
  text.

The same row is wrong the other way for owning types that hold views. `List[?String]` (`b07`) and
`obj Mixed` with a `?List[String]` field (`b08`) view `ls`, but the row gives them `none`. Main and
the oracle reject the body's write (C4). The ownership checker must not take `none` to mean "no
loans to carry".

- **Fix:** a field or element *follows its base*, whatever the part's own kind:
  - through a view, the part views what the view views;
  - in a made value, it views `made`;
  - in a place, it views `place`.

  `none` is right only for a value that is neither a part nor a view and holds no view. Whether a
  value carries loans stays the per-type fact "may hold a loan". Note that `sema.pathHands`
  already says `.place` for any path through a view, even a view of a made value
  (`pick(?mk())[0]`). That wrong answer is today covered by `firstStmtTemp` and
  `rejectHeaderCopy`, and this fact is what must correct it.

### 2c. Made objects of the view kind (`k01`, `k02`)

`for x in Cur(xs: ?b.xs, i: 0)`, `for x in cur_of(?xs)`, `for x in ?b.each()`, where `Cur` is an
iterator holding `?List[String]`.

The draft rates the constructor (the join of its fields) and the call (by its origins) as
`place`. But the object's own bytes, the cursor, are made in the header. Only what it holds views
a place. Reading it "in place, as it reads the place" fails either way:

- SPEC rejects a bare place iterator ("write `!it`"), so the draft would reject what runs today
  (`k01` prints `p q` three times). That breaks "nothing accepted today is rejected".
- Or the loop advances a cursor in a temporary its header has ended.

**Fix:** separate *where the value lives* from *what it views*, or apply "reads in place" only to
results whose type is `?T`, `!T`, `[]T`, or `![]T`, never to an object of the view kind.

## 3. Programs the draft gets wrong that CORE accepts

| Program | Main | Draft | CORE | Oracle |
|---|---|---|---|---|
| `l03` `for x in ?first_list(?ls)`; Int form `b14` `?b.all()` | reject (`b14` says "temporary") | lend of a call, so `made`: reject | §4: a read view of a read view is that view, so `place` | `b14`: `prod=sema ref=accept` (`lendsHeldView`) |
| `b10` `for x in !first_mut(!ls)` | reject | lend of a call, so `made`: reject | lend table: a held `!T` is lent on | abstains ("a write lend of a made value") |
| `d03` `for s in pick(?lss)[0]`, `d04` `pick(?b).items` | reject | owning type, so `none`: reject | a part through a view of a place | abstains |
| `m01` `for x in wrap(?xs).items` (`W` holds `?List[String]`) | reject | a view-kind part of a made value, so `made`: reject | s7: through a read view a value holds, the part carries that view's loans | Int form `m02`: accept, and rejects the body's write (C4) |
| `b12` `for x in b.all()`, `from @items`, body `!b.other.push(x)` | reject: "read loan on `b`" | `place`, but it never says *which* place | s7: the loan is on `b.items` alone; the bound form `b11` runs | `stricter ... prod=reject ref=accept` |
| `f03` `for x in find(?lss, ?String("a","b"))`, `from lss` | reject | `place` (the key is not an origin): accept, correctly | accept | Int form `f02` runs clean |

`f03` matters for open question 4. Emit must end the key's temporary at the header while the view
lives. The storage plan already does this for plain elements (`f02`).

## 4. The draft's false claims

1. "The loop above, and its `if ... as` and `match` siblings ... (all fail today)." The siblings
   already run on main: `j01` (`if first_list(?ls) as x`) prints `["a"]`, and `j02`
   (`match first(?ls)`) prints `c`. What fails is the `placeOf(...).named()` check in
   `typecheck.elementTypeForLoop`: a `for` over a List, a table, or a shared handle of owners.
2. "Does anything in emit change?" Yes: the header temporaries in `f03` above. Emit must also
   still hold a made object of the view kind (`k01`).

## 5. Where the draft holds

- When the subject views a place, the body's writes, drops, and reassignments are rejected by the
  loans that exist today: `a03`, `a04`, `b09`, `g05`, `h03`, `j04`, and the bound forms `i01` and
  `i04`. Main and the oracle agree (C4 or C1).
- Nested calls (`j05`) and branches (`j06`, `j07`: a made leaf makes the whole `made`) follow
  joins.
- A closure called with no arguments (`g01`) is vacuously `place`, and that is right: a closure
  may return only views of what it captured by lending (`g03` is rejected).
- `?{A}` read through a parameter (`h01`) is a place.

A separate bug (not 33C): `f05`, a `for s in ls` element returned from a function whose `ls` is a
view parameter, is rejected with "bare use of loop view `s` in return value". CORE s7 allows
returning a view of what the function was lent.

## 6. Proposed test cases

Positions are left out, since the messages may move.

```text
test "for over a call's view of a place", "a"
  fun first_list(lists: ?List[List[String]]) -> ?List[String]
    ?lists[0]

  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in first_list(?ls)
    print(x)

fail "for over a call's view keeps the owner lent", "cannot lend `ls` to write while a read loan is live"
  fun first_list(lists: ?List[List[String]]) -> ?List[String]
    ?lists[0]

  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in first_list(?ls)
    !ls.push(List())
    print(x)

fail "for over a call's view: no drop of the owner", "cannot drop `ls` while it is lent"
  fun first_list(lists: ?List[List[String]]) -> ?List[String]
    ?lists[0]

  ls: List[List[String]] = List()
  !ls.push(List())
  for x in first_list(?ls)
    <ls
    print(x)

fail "for over a call's view: stored element keeps the loan", "cannot lend `ls` to write while a read loan is live"
  fun first_list(lists: ?List[List[String]]) -> ?List[String]
    ?lists[0]

  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  out: List[?String] = List()
  for x in first_list(?ls)
    !out.push(x)
  !ls.push(List())
  print(out)

fail "for over a call given a made argument unmarked", "temporary `mk()`"
  fun first_list(lists: ?List[List[String]]) -> ?List[String]
    ?lists[0]

  fun mk() -> List[List[String]]
    ls: List[List[String]] = List()
    !ls.push(List())
    ls

  for x in first_list(mk())
    print(x)

fail "for over a method of a made self", "temporary `mk()`"
  obj Bag
    items: List[String]

    fun all(?@) -> ?List[String] from @items
      ?@items

  fun mk() -> Bag
    Bag(items: List())

  for x in mk().all()
    print(x)

fail "for over an API object made unmarked", "temporary `mk()`"
  api Src
    fun items(?@) -> ?List[String] from @

  obj Bag: Src
    xs: List[String]

    fun items(?@) -> ?List[String] from @
      ?@xs

  fun items_of(s: ?{Src}) -> ?List[String]
    s.items()

  fun mk() -> Bag
    Bag(xs: List())

  for x in items_of(mk())
    print(x)

fail "header part through a view of a made value", "a temporary it makes ends with the header"
  fun pick(ls: ?List[String?]) -> ?List[String?]
    ls

  fun mk() -> List[String?]
    ls: List[String?] = List()
    !ls.push(String("abcdefghijklmnopqrstuvwxyz"))
    ls

  if pick(mk())[0] as s
    print(s)

fail "branch of a place view and a made view", "temporary `mk()`"
  fun first_list(lists: ?List[List[String]]) -> ?List[String]
    ?lists[0]

  fun mk() -> List[List[String]]
    ls: List[List[String]] = List()
    !ls.push(List())
    ls

  a = mk()
  c = a.len > 0
  for x in (first_list(?a) if c else first_list(?mk()))
    print(x)

test "for over a made iterator of the view kind is held", '''
  p
  p
'''
  obj Cur
    xs: ?List[String]
    i: Int

    fun next(!@) -> (?String)?
      return none if @i >= @xs.len
      @i += 1
      ?@xs[@i - 1]

  fun cur_of(xs: ?List[String]) -> Cur
    Cur(xs: xs, i: 0)

  xs: List[String] = List()
  !xs.push(String("p"))
  for x in cur_of(?xs)
    print(x)
  for x in Cur(xs: ?xs, i: 0)
    print(x)

test "for over a lend of a call's view", "a"
  fun first_list(lists: ?List[List[String]]) -> ?List[String]
    ?lists[0]

  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in ?first_list(?ls)
    print(x)

test "for writing through a call's write view", '["a!"]'
  fun first_mut(lists: !List[List[String]]) -> !List[String]
    !lists[0]

  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in !first_mut(!ls)
    !x.add("!")
  print(ls[0])

test "for over a part through a call's view", "a"
  fun pick(lss: ?List[List[String]]) -> ?List[List[String]]
    lss

  lss: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !lss.push(<inner)
  for s in pick(?lss)[0]
    print(s)

test "for over a view field of a made object", "w"
  obj W
    items: ?List[String]

  fun wrap(xs: ?List[String]) -> W
    W(items: xs)

  xs: List[String] = List()
  !xs.push(String("w"))
  for x in wrap(?xs).items
    print(x)

test "for over a from-path view leaves other fields free", "[1]"
  obj Bag
    items: List[Int]
    other: List[Int]

    fun all(?@) -> ?List[Int] from @items
      ?@items

  b = Bag(items: List(), other: List())
  !b.items.push(1)
  for x in b.all()
    !b.other.push(x)
  print(b.other)

test "for over a call with a temporary key", "z"
  fun find(lss: ?List[List[String]], key: ?String) -> ?List[String] from lss
    ?lss[0]

  lss: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("z"))
  !lss.push(<inner)
  for x in find(?lss, ?String("a", "b"))
    print(x)
```

## Appendix: every program, with main's output and the oracle's verdict

### `a00_main.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in first_list(?ls)
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a00_main.rig:9:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(?ls)` to a name first
  for x in first_list(?ls)
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `a00b_bound.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  r = first_list(?ls)
  for x in r
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `a01_place.rig`

```rig fragment
sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in ?ls[0]
    print(x)
  for x in ls[0]
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a
a
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `a02_place_write.rig`

```rig fragment
sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in ?ls[0]
    !ls.push(List())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a02_place_write.rig:7:5: error: cannot lend `ls` to write while a read loan is live
    !ls.push(List())
    ^
a02_place_write.rig:6:13:   note: `ls` lent to read here
  for x in ?ls[0]
            ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 7:6 cannot write `ls` while a read loan of it is live (L4, carried by `the `for` source`#9)`

### `a03_ints_write.rig`

```rig fragment
fun first_ints(lists: ?List[List[Int]]) -> ?List[Int]
  ?lists[0]

sub main()
  ls: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !inner.push(2)
  !ls.push(<inner)
  for x in first_ints(?ls)
    !ls.push(List())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a03_ints_write.rig:11:5: error: cannot lend `ls` to write while a read loan is live
    !ls.push(List())
    ^
a03_ints_write.rig:10:24:   note: `ls` lent to read here
  for x in first_ints(?ls)
                       ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 11:6 cannot write `ls` while a read loan of it is live (L6, carried by `the `for` source`#10)`

### `a04_ints_clear.rig`

```rig fragment
fun first_ints(lists: ?List[List[Int]]) -> ?List[Int]
  ?lists[0]

sub main()
  ls: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !inner.push(2)
  !ls.push(<inner)
  for x in first_ints(?ls)
    !ls[0].push(9)
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a04_ints_clear.rig:11:5: error: cannot lend `ls` to write while a read loan is live
    !ls[0].push(9)
    ^
a04_ints_clear.rig:10:24:   note: `ls` lent to read here
  for x in first_ints(?ls)
                       ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 11:6 cannot write `ls` while a read loan of it is live (L6, carried by `the `for` source`#10)`

### `a05_str_write.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in first_list(?ls)
    !ls.push(List())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a05_str_write.rig:9:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(?ls)` to a name first
  for x in first_list(?ls)
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `a06_made.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

fun mk() -> List[List[String]]
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  ls

sub main()
  for x in first_list(?mk())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a06_made.rig:12:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(?mk())` to a name first
  for x in first_list(?mk())
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `a07_made_ints.rig`

```rig fragment
fun first_ints(lists: ?List[List[Int]]) -> ?List[Int]
  ?lists[0]

fun mk() -> List[List[Int]]
  ls: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !ls.push(<inner)
  ls

sub main()
  for x in first_ints(?mk())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a07_made_ints.rig:12:24: error: a view of the temporary `mk()` outlives its statement, which drops it; bind the value to a name first
  for x in first_ints(?mk())
                       ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C5 12:3 a loan of a temporary outlives its statement`

### `b01_implicit_made_ints.rig`

```rig fragment
fun first_ints(lists: ?List[List[Int]]) -> ?List[Int]
  ?lists[0]

fun mk() -> List[List[Int]]
  ls: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !ls.push(<inner)
  ls

sub main()
  for x in first_ints(mk())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b01_implicit_made_ints.rig:12:23: error: a view of the temporary `mk()` outlives its statement, which drops it; bind the value to a name first
  for x in first_ints(mk())
                      ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C5 12:3 a loan of a temporary outlives its statement`

### `b02_implicit_made_str.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

fun mk() -> List[List[String]]
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  ls

sub main()
  for x in first_list(mk())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b02_implicit_made_str.rig:12:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(mk())` to a name first
  for x in first_list(mk())
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `b03_self_made.rig`

```rig fragment
obj Bag
  items: List[String]
  other: List[Int]

  fun all(?@) -> ?List[String] from @items
    ?@items

fun mk() -> Bag
  b = Bag(items: List(), other: List())
  !b.items.push(String("a"))
  b

sub main()
  for x in mk().all()
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b03_self_made.rig:14:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `mk().all()` to a name first
  for x in mk().all()
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `b04_self_made_int.rig`

```rig fragment
obj Bag
  items: List[Int]

  fun all(?@) -> ?List[Int] from @items
    ?@items

fun mk() -> Bag
  b = Bag(items: List())
  !b.items.push(1)
  b

sub main()
  for x in mk().all()
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b04_self_made_int.rig:13:12: error: a view of the temporary `mk()` outlives its statement, which drops it; bind the value to a name first
  for x in mk().all()
           ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C5 13:3 a loan of a temporary outlives its statement`

### `b05_self_place.rig`

```rig fragment
obj Bag
  items: List[String]
  other: List[Int]

  fun all(?@) -> ?List[String] from @items
    ?@items

sub main()
  b = Bag(items: List(), other: List())
  !b.items.push(String("a"))
  for x in b.all()
    !b.other.push(1)
    print(x)
  print(b.other)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b05_self_place.rig:11:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `b.all()` to a name first
  for x in b.all()
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `b06_self_place_int.rig`

```rig fragment
obj Bag
  items: List[Int]
  other: List[Int]

  fun all(?@) -> ?List[Int] from @items
    ?@items

sub main()
  b = Bag(items: List(), other: List())
  !b.items.push(1)
  for x in b.all()
    !b.other.push(1)
    print(x)
  for x in b.all()
    !b.items.push(2)
  print(b.other)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b06_self_place_int.rig:14:7: error: `x` is bound but never read; name it `_` to ignore the value
  for x in b.all()
      ^
b06_self_place_int.rig:12:5: error: cannot lend `b.other` to write while a read loan on `b` is live
    !b.other.push(1)
    ^
b06_self_place_int.rig:11:12:   note: `b` lent to read here
  for x in b.all()
           ^
b06_self_place_int.rig:15:5: error: cannot lend `b.items` to write while a read loan on `b` is live
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 15:6 cannot write `b` while a read loan of it is live (L7, carried by `the `for` source`#15)`

### `b07_views_list.rig`

```rig fragment
fun views_of(ls: ?List[String]) -> List[?String]
  out: List[?String] = List()
  for s in ls
    !out.push(s)
  out

sub main()
  ls: List[String] = List()
  !ls.push(String("a"))
  for s in views_of(?ls)
    !ls.push(String("b"))
    print(s)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b07_views_list.rig:11:5: error: cannot lend `ls` to write while a read loan is live
    !ls.push(String("b"))
    ^
b07_views_list.rig:10:22:   note: `ls` lent to read here
  for s in views_of(?ls)
                     ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 11:6 cannot write `ls` while a read loan of it is live (L2, carried by `the `for` source`#6)`

### `b08_mixed.rig`

```rig fragment
obj Mixed
  name: String
  items: ?List[String]

fun find(ls: ?List[String]) -> Mixed?
  Mixed(name: String("m"), items: ls)

sub main()
  ls: List[String] = List()
  !ls.push(String("a"))
  if find(?ls) as m
    !ls.push(String("b"))
    print(m.items)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b08_mixed.rig:12:5: error: cannot lend `ls` to write while a read loan is live
    !ls.push(String("b"))
    ^
b08_mixed.rig:11:12:   note: `ls` lent to read here
  if find(?ls) as m
           ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 12:6 cannot write `ls` while a read loan of it is live (L2, carried by `m`#7)`

### `b09_write_ints.rig`

```rig fragment
fun first_mut(lists: !List[List[Int]]) -> !List[Int]
  !lists[0]

sub main()
  ls: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !ls.push(<inner)
  for x in first_mut(!ls)
    print(ls.len)
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b09_write_ints.rig:10:11: error: use of `ls` while a write loan is live
    print(ls.len)
          ^
b09_write_ints.rig:9:23:   note: `ls` lent to write here
  for x in first_mut(!ls)
                      ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 10:11 cannot read `ls` while a write loan of it is live (L4, carried by `the `for` source`#9)`

### `b10_write_str.rig`

```rig fragment
fun first_mut(lists: !List[List[String]]) -> !List[String]
  !lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in !first_mut(!ls)
    !x.add("!")
  print(ls)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b10_write_str.rig:9:13: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_mut(!ls)` to a name first
  for x in !first_mut(!ls)
            ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a write lend of a made value)`

### `b11_from_bind.rig`

```rig fragment
obj Bag
  items: List[Int]
  other: List[Int]

  fun all(?@) -> ?List[Int] from @items
    ?@items

sub main()
  b = Bag(items: List(), other: List())
  !b.items.push(1)
  r = ?b.all()
  !b.other.push(1)
  print(r)
  for x in r
    !b.other.push(x)
  print(b.other)
```

main (`rig run`, RIG_SANITIZE=1):

```text
[1]
[1, 1]
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `b12_from_loop.rig`

```rig fragment
obj Bag
  items: List[Int]
  other: List[Int]

  fun all(?@) -> ?List[Int] from @items
    ?@items

sub main()
  b = Bag(items: List(), other: List())
  !b.items.push(1)
  for x in b.all()
    !b.other.push(x)
  print(b.other)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b12_from_loop.rig:12:5: error: cannot lend `b.other` to write while a read loan on `b` is live
    !b.other.push(x)
    ^
b12_from_loop.rig:11:12:   note: `b` lent to read here
  for x in b.all()
           ^
```

oracle (`--sema -v`): `b12_from_loop.rig main prod=reject ref=accept`

### `b13_from_loop_items.rig`

```rig fragment
obj Bag
  items: List[Int]
  other: List[Int]

  fun all(?@) -> ?List[Int] from @items
    ?@items

sub main()
  b = Bag(items: List(), other: List())
  !b.items.push(1)
  for x in b.all()
    !b.items.push(x)
  print(b.items)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b13_from_loop_items.rig:12:5: error: cannot lend `b.items` to write while a read loan on `b` is live
    !b.items.push(x)
    ^
b13_from_loop_items.rig:11:12:   note: `b` lent to read here
  for x in b.all()
           ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 12:6 cannot write `b` while a read loan of it is live (L3, carried by `the `for` source`#8)`

### `b14_from_loop_q.rig`

```rig fragment
obj Bag
  items: List[Int]
  other: List[Int]

  fun all(?@) -> ?List[Int] from @items
    ?@items

sub main()
  b = Bag(items: List(), other: List())
  !b.items.push(1)
  for x in ?b.all()
    !b.other.push(x)
  print(b.other)
```

main (`rig run`, RIG_SANITIZE=1):

```text
b14_from_loop_q.rig:11:13: error: the loop would walk a view of the temporary `b.all()` after its header drops it; take it with `for x in b.all()`, or bind it to a name first
  for x in ?b.all()
            ^~~~~~~
```

oracle (`--sema -v`): `main prod=sema ref=accept`

### `c00_ints_ok.rig`

```rig fragment
fun first_ints(lists: ?List[List[Int]]) -> ?List[Int]
  ?lists[0]

sub main()
  ls: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !ls.push(<inner)
  for x in first_ints(?ls)
    print(x)
  print(ls.len)
```

main (`rig run`, RIG_SANITIZE=1):

```text
1
1
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `d01_part_if_as.rig`

```rig fragment
fun pick(ls: ?List[String?]) -> ?List[String?]
  ls

sub main()
  ls: List[String?] = List()
  !ls.push(String("a"))
  if pick(?ls)[0] as s
    print(s)
  print(ls)
```

main (`rig run`, RIG_SANITIZE=1):

```text
a
["a"]
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `d02_part_match.rig`

```rig fragment
enum Shape
  circle(name: String)
  square(side: Int)

fun pick(ls: ?List[Shape]) -> ?List[Shape]
  ls

sub main()
  ls: List[Shape] = List()
  !ls.push(Shape.circle(name: String("c")))
  match pick(?ls)[0]
    .circle(name) => print(name)
    .square(side) => print(side)
  print(ls.len)
```

main (`rig run`, RIG_SANITIZE=1):

```text
c
1
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `d03_part_for.rig`

```rig fragment
fun pick(lss: ?List[List[String]]) -> ?List[List[String]]
  lss

sub main()
  lss: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !lss.push(<inner)
  for s in pick(?lss)[0]
    print(s)
  print(lss)
```

main (`rig run`, RIG_SANITIZE=1):

```text
d03_part_for.rig:9:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `pick(?lss)[0]` to a name first
  for s in pick(?lss)[0]
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `d04_part_field.rig`

```rig fragment
obj Bag
  items: List[String]

fun pick(b: ?Bag) -> ?Bag
  b

sub main()
  b = Bag(items: List())
  !b.items.push(String("a"))
  for s in pick(?b).items
    print(s)
  print(b.items)
```

main (`rig run`, RIG_SANITIZE=1):

```text
d04_part_field.rig:10:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `pick(?b).items` to a name first
  for s in pick(?b).items
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `d05_part_field_match.rig`

```rig fragment
obj Bag
  name: String?

fun pick(b: ?Bag) -> ?Bag
  b

sub main()
  b = Bag(name: String("n"))
  if pick(?b).name as n
    print(n)
  print(b.name)
```

main (`rig run`, RIG_SANITIZE=1):

```text
n
n
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `e01_part_made_if_as.rig`

```rig fragment
fun pick(ls: ?List[String?]) -> ?List[String?]
  ls

fun mk() -> List[String?]
  ls: List[String?] = List()
  !ls.push(String("abcdefghijklmnopqrstuvwxyz"))
  ls

sub main()
  if pick(?mk())[0] as s
    print(s)
```

main (`rig run`, RIG_SANITIZE=1):

```text
e01_part_made_if_as.rig:10:12: error: this header binds a copy of its subject, since a temporary it makes ends with the header: bind the argument to a name first
  if pick(?mk())[0] as s
           ^~~~
```

oracle (`--sema -v`): `main prod=sema ref=reject C5 10:6 a loan of a temporary outlives its statement`

### `e02_part_made_match.rig`

```rig fragment
enum Shape
  circle(name: String)
  square(side: Int)

fun pick(ls: ?List[Shape]) -> ?List[Shape]
  ls

fun mk() -> List[Shape]
  ls: List[Shape] = List()
  !ls.push(Shape.circle(name: String("abcdefghijklmnopqrstuvwxyz")))
  ls

sub main()
  match pick(?mk())[0]
    .circle(name) => print(name)
    .square(side) => print(side)
```

main (`rig run`, RIG_SANITIZE=1):

```text
e02_part_made_match.rig:14:15: error: this header binds a copy of its subject, since a temporary it makes ends with the header: bind the argument to a name first
  match pick(?mk())[0]
              ^~~~
```

oracle (`--sema -v`): `main prod=sema ref=reject C5 14:9 a loan of a temporary outlives its statement`

### `e03_part_made_implicit.rig`

```rig fragment
fun pick(ls: ?List[String?]) -> ?List[String?]
  ls

fun mk() -> List[String?]
  ls: List[String?] = List()
  !ls.push(String("abcdefghijklmnopqrstuvwxyz"))
  ls

sub main()
  if pick(mk())[0] as s
    print(s)
```

main (`rig run`, RIG_SANITIZE=1):

```text
e03_part_made_implicit.rig:10:11: error: this header binds a copy of its subject, since a temporary it makes ends with the header: bind the argument to a name first
  if pick(mk())[0] as s
          ^~~~
```

oracle (`--sema -v`): `main prod=sema ref=reject C5 10:6 a loan of a temporary outlives its statement`

### `e04_self_made_if_as.rig`

```rig fragment
obj Bag
  items: List[String?]

  fun all(?@) -> ?List[String?] from @items
    ?@items

fun mk() -> Bag
  b = Bag(items: List())
  !b.items.push(String("abcdefghijklmnopqrstuvwxyz"))
  b

sub main()
  if mk().all()[0] as s
    print(s)
```

main (`rig run`, RIG_SANITIZE=1):

```text
e04_self_made_if_as.rig:13:6: error: this header binds a copy of its subject, since a temporary it makes ends with the header: bind `mk()` to a name first
  if mk().all()[0] as s
     ^~~~
```

oracle (`--sema -v`): `main prod=sema ref=reject C5 13:6 a loan of a temporary outlives its statement`

### `e05_view_opt_made.rig`

```rig fragment
fun first(ls: ?List[String]) -> (?String)?
  if ls.len == 0
    return none
  ?ls[0]

fun mk() -> List[String]
  ls: List[String] = List()
  !ls.push(String("abcdefghijklmnopqrstuvwxyz"))
  ls

sub main()
  if first(mk()) as s
    print(s)
```

main (`rig run`, RIG_SANITIZE=1):

```text
e05_view_opt_made.rig:12:12: error: a view of the temporary `mk()` outlives its statement, which drops it; bind the value to a name first
  if first(mk()) as s
           ^
e05_view_opt_made.rig:12:21:   note: `s` still holds it after the statement
  if first(mk()) as s
                    ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C5 12:6 a loan of a temporary outlives its statement`

### `f01_key_temp_if.rig`

```rig fragment
fun find(ls: ?List[String], key: ?String) -> (?String)? from ls
  i = 0
  while i < ls.len
    if ls[i] == key
      return ?ls[i]
    i += 1
  none

sub main()
  ls: List[String] = List()
  !ls.push(String("ab"))
  if find(?ls, ?String("a", "b")) as s
    print(s)
  k = String("ab")
  if find(?ls, ?k) as t
    print(t)
```

main (`rig run`, RIG_SANITIZE=1):

```text
ab
ab
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `f02_key_temp_for.rig`

```rig fragment
fun find(lss: ?List[List[Int]], key: ?String) -> ?List[Int] from lss
  if key.len > 0
    return ?lss[0]
  ?lss[0]

sub main()
  lss: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !lss.push(<inner)
  for x in find(?lss, ?String("a", "b"))
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
1
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `f03_key_temp_for_str.rig`

```rig fragment
fun find(lss: ?List[List[String]], key: ?String) -> ?List[String] from lss
  if key.len > 0
    return ?lss[0]
  ?lss[0]

sub main()
  lss: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("z"))
  !lss.push(<inner)
  for x in find(?lss, ?String("a", "b"))
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
f03_key_temp_for_str.rig:11:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `find(?lss, ?String("a", "b"))` to a name first
  for x in find(?lss, ?String("a", "b"))
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `f04_key_temp_if_nofrom.rig`

```rig fragment
fun find(ls: ?List[String], key: ?String) -> (?String)?
  for s in ls
    if s == key
      return s
  none

sub main()
  ls: List[String] = List()
  !ls.push(String("ab"))
  if find(?ls, ?String("a", "b")) as s
    print(s)
```

main (`rig run`, RIG_SANITIZE=1):

```text
f04_key_temp_if_nofrom.rig:4:14: error: bare use of loop view `s` in return value would carry the viewed handle past the loop; a `for x in ?list` element is a read view of the List slot and cannot be cloned, moved, dropped, or stored
      return s
             ^
f04_key_temp_if_nofrom.rig:10:17: error: a view of the temporary `String("a", "b")` outlives its statement, which drops it; bind the value to a name first
  if find(?ls, ?String("a", "b")) as s
                ^
f04_key_temp_if_nofrom.rig:10:38:   note: `s` still holds it after the statement
  if find(?ls, ?String("a", "b")) as s
                                     ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C5 10:6 a loan of a temporary outlives its statement`

### `f05_loopret.rig`

```rig fragment
fun find(ls: ?List[String], key: ?String) -> (?String)? from ls
  for s in ls
    if s == key
      return s
  none

sub main()
  ls: List[String] = List()
  !ls.push(String("ab"))
  k = String("ab")
  if find(?ls, ?k) as t
    print(t)
```

main (`rig run`, RIG_SANITIZE=1):

```text
f05_loopret.rig:4:14: error: bare use of loop view `s` in return value would carry the viewed handle past the loop; a `for x in ?list` element is a read view of the List slot and cannot be cloned, moved, dropped, or stored
      return s
             ^
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `g01_closure_view.rig`

```rig fragment
sub main()
  lss: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !lss.push(<inner)
  f = |?lss| ?lss[0]
  for x in f()
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
1
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `g03_closure_take2.rig`

```rig fragment
fun mk() -> List[List[Int]]
  lss: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !lss.push(<inner)
  lss

sub main()
  v = mk()
  for x in (|<v| ?v[0])()
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
g03_closure_take2.rig:10:19: error: cannot return a view of `v`, which this function was not lent
  for x in (|<v| ?v[0])()
                  ^
g03_closure_take2.rig:10:15:   note: `v` is local to this closure
  for x in (|<v| ?v[0])()
              ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C6 10:18 a view of `v` leaves the function, which was not lent it`

### `g05_closure_body_write.rig`

```rig fragment
sub main()
  lss: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !lss.push(<inner)
  f = |?lss| ?lss[0]
  for x in f()
    !lss.push(List())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
g05_closure_body_write.rig:8:5: error: cannot lend `lss` to write while a read loan is live
    !lss.push(List())
    ^
g05_closure_body_write.rig:6:9:   note: `lss` lent to read here
  f = |?lss| ?lss[0]
        ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 8:6 cannot write `lss` while a read loan of it is live (L4, carried by `the `for` source`#11)`

### `h01_api_param.rig`

```rig fragment
api Src
  fun items(?@) -> ?List[Int] from @

obj Bag: Src
  xs: List[Int]

  fun items(?@) -> ?List[Int] from @
    ?@xs

sub show(s: ?{Src})
  for x in s.items()
    print(x)

fun mk() -> Bag
  b = Bag(xs: List())
  !b.xs.push(1)
  b

sub main()
  b = mk()
  show(?b)
  for x in (?b).items()
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
1
1
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `h02_api_made.rig`

```rig fragment
api Src
  fun items(?@) -> ?List[Int] from @

obj Bag: Src
  xs: List[Int]

  fun items(?@) -> ?List[Int] from @
    ?@xs

fun items_of(s: ?{Src}) -> ?List[Int]
  s.items()

fun mk() -> Bag
  b = Bag(xs: List())
  !b.xs.push(1)
  b

sub main()
  for x in items_of(mk())
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
h02_api_made.rig:19:21: error: a view of the temporary `mk()` outlives its statement, which drops it; bind the value to a name first
  for x in items_of(mk())
                    ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C5 19:3 a loan of a temporary outlives its statement`

### `h03_api_box_drop.rig`

```rig fragment
api Src
  fun items(?@) -> ?List[Int] from @

obj Bag: Src
  xs: List[Int]

  fun items(?@) -> ?List[Int] from @
    ?@xs

fun mk() -> Bag
  b = Bag(xs: List())
  !b.xs.push(1)
  b

sub main()
  h: ^{Src} = ^mk()
  for x in h.items()
    h = ^mk()
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
h03_api_box_drop.rig:18:5: error: cannot reassign `h` while it is lent
    h = ^mk()
    ^
h03_api_box_drop.rig:17:12:   note: `h` lent to read here
  for x in h.items()
           ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 18:5 cannot move `h` while a read loan of it is live (L0, carried by `the `for` source`#5)`

### `h04_api_box_made.rig`

```rig fragment
api Src
  fun items(?@) -> ?List[Int] from @

obj Bag: Src
  xs: List[Int]

  fun items(?@) -> ?List[Int] from @
    ?@xs

fun mk() -> Bag
  b = Bag(xs: List())
  !b.xs.push(1)
  b

fun boxed() -> ^{Src}
  ^mk()

sub main()
  for x in boxed().items()
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
h04_api_box_made.rig:19:12: error: a view of the temporary `boxed()` outlives its statement, which drops it; bind the value to a name first
  for x in boxed().items()
           ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C5 19:3 a loan of a temporary outlives its statement`

### `h05_api_str_param.rig`

```rig fragment
api Src
  fun items(?@) -> ?List[String] from @

obj Bag: Src
  xs: List[String]

  fun items(?@) -> ?List[String] from @
    ?@xs

sub show(s: ?{Src})
  for x in s.items()
    print(x)

sub main()
  b = Bag(xs: List())
  !b.xs.push(String("a"))
  show(?b)
```

main (`rig run`, RIG_SANITIZE=1):

```text
h05_api_str_param.rig:11:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `s.items()` to a name first
  for x in s.items()
           ^
```

oracle (`--sema -v`): `main prod=sema ref=accept`

### `i01_desugar_store.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  out: List[?String] = List()
  r = first_list(?ls)
  for x in r
    !out.push(x)
  !ls.push(List())
  print(out)
```

main (`rig run`, RIG_SANITIZE=1):

```text
i01_desugar_store.rig:13:3: error: cannot lend `ls` to write while a read loan is live
  !ls.push(List())
  ^
i01_desugar_store.rig:10:19:   note: `ls` lent to read here
  r = first_list(?ls)
                  ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 13:4 cannot write `ls` while a read loan of it is live (L4, carried by `out`#9)`

### `i02_desugar_ok.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  out: List[?String] = List()
  r = first_list(?ls)
  for x in r
    !out.push(x)
    print(ls.len)
  print(out)
  !ls.push(List())
  print(ls.len)
```

main (`rig run`, RIG_SANITIZE=1):

```text
1
["a"]
2
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `i03_desugar_move.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  out: List[String] = List()
  r = first_list(?ls)
  for x in r
    !out.push(<x)
  print(out)
```

main (`rig run`, RIG_SANITIZE=1):

```text
i03_desugar_move.rig:12:15: error: type mismatch: expected `String`, got `?String`; a `String` owns its text: write `String(<x)` to copy it, or declare the place `?String` to only read it
    !out.push(<x)
              ^~
```

oracle (`--sema -v`): `main prod=sema ref=accept`

### `i04_desugar_drop_owner.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  r = first_list(?ls)
  for x in r
    <ls
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
i04_desugar_drop_owner.rig:11:6: error: cannot drop `ls` while it is lent
    <ls
     ^
i04_desugar_drop_owner.rig:9:19:   note: `ls` lent to read here
  r = first_list(?ls)
                  ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C1 11:5 use of `ls` after move`

### `j01_if_as_sib.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> (?List[String])?
  if lists.len == 0
    return none
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  if first_list(?ls) as x
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
["a"]
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `j02_match_sib.rig`

```rig fragment
enum Shape
  circle(name: String)
  square(side: Int)

fun first(ls: ?List[Shape]) -> ?Shape
  ?ls[0]

sub main()
  ls: List[Shape] = List()
  !ls.push(Shape.circle(name: String("c")))
  match first(?ls)
    .circle(name) => print(name)
    .square(side) => print(side)
```

main (`rig run`, RIG_SANITIZE=1):

```text
c
```

oracle (`--sema -v`): `main prod=accept ref=accept`

### `j04_if_as_sib_write.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> (?List[String])?
  if lists.len == 0
    return none
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  if first_list(?ls) as x
    ls = List()
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
j04_if_as_sib_write.rig:12:5: error: cannot reassign `ls` while it is lent
    ls = List()
    ^
j04_if_as_sib_write.rig:11:18:   note: `ls` lent to read here
  if first_list(?ls) as x
                 ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 12:5 cannot move `ls` while a read loan of it is live (L4, carried by `x`#11)`

### `j05_nested.rig`

```rig fragment
fun pick(lss: ?List[List[List[String]]]) -> ?List[List[String]]
  ?lss[0]

fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  lss: List[List[List[String]]] = List()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  !lss.push(<ls)
  for x in first_list(pick(?lss))
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
j05_nested.rig:14:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(pick(?lss))` to a name first
  for x in first_list(pick(?lss))
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `j06_branch.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

fun mk() -> List[List[String]]
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("m"))
  !ls.push(<inner)
  ls

sub main()
  a = mk()
  c = a.len > 0
  for x in (first_list(?a) if c else first_list(?mk()))
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
j06_branch.rig:14:13: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(?a) if c else first_list(?mk())` to a name first
  for x in (first_list(?a) if c else first_list(?mk()))
            ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `j07_branch_ints.rig`

```rig fragment
fun first_ints(lists: ?List[List[Int]]) -> ?List[Int]
  ?lists[0]

fun mk() -> List[List[Int]]
  ls: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !ls.push(<inner)
  ls

sub main()
  a = mk()
  c = a.len > 0
  for x in (first_ints(?a) if c else first_ints(?mk()))
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
j07_branch_ints.rig:14:50: error: a view of the temporary `mk()` outlives its statement, which drops it; bind the value to a name first
  for x in (first_ints(?a) if c else first_ints(?mk()))
                                                 ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C5 14:3 a loan of a temporary outlives its statement`

### `k01_iter_viewkind.rig`

```rig fragment
obj Cur
  xs: ?List[String]
  i: Int

  fun next(!@) -> (?String)?
    return none if @i >= @xs.len
    @i += 1
    ?@xs[@i - 1]

obj Bag
  xs: List[String]

  fun each(?@) -> Cur from @
    Cur(xs: ?@xs, i: 0)

fun cur_of(xs: ?List[String]) -> Cur
  Cur(xs: xs, i: 0)

sub main()
  b = Bag(xs: List())
  !b.xs.push(String("p"))
  !b.xs.push(String("q"))
  for x in ?b.each()
    print(x)
  for x in cur_of(?b.xs)
    print(x)
  for x in Cur(xs: ?b.xs, i: 0)
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
p
q
p
q
p
q
```

oracle (`--sema -v`): `main prod=accept ref=unknown (an expression without a type: block)`

### `k02_iter_viewkind_write.rig`

```rig fragment
obj Cur
  xs: ?List[String]
  i: Int

  fun next(!@) -> (?String)?
    return none if @i >= @xs.len
    @i += 1
    ?@xs[@i - 1]

fun cur_of(xs: ?List[String]) -> Cur
  Cur(xs: xs, i: 0)

sub main()
  xs: List[String] = List()
  !xs.push(String("p"))
  for x in cur_of(?xs)
    !xs.push(String("r"))
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
k02_iter_viewkind_write.rig:17:5: error: cannot lend `xs` to write while a read loan is live
    !xs.push(String("r"))
    ^
k02_iter_viewkind_write.rig:16:20:   note: `xs` lent to read here
  for x in cur_of(?xs)
                   ^
```

oracle (`--sema -v`): `main prod=reject ref=unknown (an expression without a type: block)`

### `l01_clone_arg.rig`

```rig fragment
fun first_ints(lists: ?List[List[Int]]) -> ?List[Int]
  ?lists[0]

sub main()
  ls: List[List[Int]] = List()
  inner: List[Int] = List()
  !inner.push(1)
  !ls.push(<inner)
  for x in first_ints(+ls)
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
l01_clone_arg.rig:9:23: error: lend `?ls` instead: a clone into a read view is only read, then dropped
  for x in first_ints(+ls)
                      ^~~
```

oracle (`--sema -v`): `main prod=sema ref=reject C5 9:3 a loan of a temporary outlives its statement`

### `l02_clone_arg_str.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in first_list(+ls)
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
l02_clone_arg_str.rig:9:23: error: lend `?ls` instead: a clone into a read view is only read, then dropped
  for x in first_list(+ls)
                      ^~~
l02_clone_arg_str.rig:9:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(+ls)` to a name first
  for x in first_list(+ls)
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `l03_lend_view_str.rig`

```rig fragment
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in ?first_list(?ls)
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
l03_lend_view_str.rig:9:13: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(?ls)` to a name first
  for x in ?first_list(?ls)
            ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `m01_part_of_made_viewkind.rig`

```rig fragment
obj W
  items: ?List[String]

fun wrap(xs: ?List[String]) -> W
  W(items: xs)

sub main()
  xs: List[String] = List()
  !xs.push(String("w"))
  for x in wrap(?xs).items
    print(x)
```

main (`rig run`, RIG_SANITIZE=1):

```text
m01_part_of_made_viewkind.rig:10:12: error: a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `wrap(?xs)` to a name first
  for x in wrap(?xs).items
           ^
```

oracle (`--sema -v`): `main prod=sema ref=unknown (a type with an error)`

### `m02_part_of_made_viewkind_int.rig`

```rig fragment
obj W
  items: ?List[Int]

fun wrap(xs: ?List[Int]) -> W
  W(items: xs)

sub main()
  xs: List[Int] = List()
  !xs.push(7)
  for x in wrap(?xs).items
    print(x)
  for x in wrap(?xs).items
    !xs.push(8)
```

main (`rig run`, RIG_SANITIZE=1):

```text
m02_part_of_made_viewkind_int.rig:12:7: error: `x` is bound but never read; name it `_` to ignore the value
  for x in wrap(?xs).items
      ^
m02_part_of_made_viewkind_int.rig:13:5: error: cannot lend `xs` to write while a read loan is live
    !xs.push(8)
    ^
m02_part_of_made_viewkind_int.rig:12:18:   note: `xs` lent to read here
  for x in wrap(?xs).items
                 ^
```

oracle (`--sema -v`): `main prod=reject ref=reject C4 13:6 cannot write `xs` while a read loan of it is live (L3, carried by `the `for` source`#14)`

