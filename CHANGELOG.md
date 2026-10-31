# Changelog

What changed in Rig. The entry under "Unreleased" lists what
`main` carries beyond the last tag; the tag's release notes take it
over, with its "Upgrading" section and the migration guide,
[docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md).
[HANDOFF](HANDOFF.md) says where the work stands, and
[docs/ROADMAP.md](docs/ROADMAP.md) lists what is planned.

## Unreleased (toward v0.3.0)

`v0.2.9` is the latest release (Zig 0.17.0, Nexus 2.0.0). `main` has
changed the language since it.

### Upgrading from v0.2.9

[docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md) takes a 0.2.9 program to
0.3.0 in order: `tools/migrate-0.3.py`, the spellings rewritten by hand,
`tools/state-bounds.py`, and what the compiler asks for. Each form
below was accepted by `v0.2.9` and is rejected by 0.3.0, most with the
form to write in the message. A form marked *unsound* let a program
read freed memory or write through a view it should not have; the rest
are renames and spellings.

Renamed, by `tools/migrate-0.3.py`:

1. `struct Name` is `obj Name`.
2. `Box[T]` and `Box(v)` are `^T` and `^v`.
3. `Vec[T]` is `List[T]`; a type of a program's own named `List` is
   renamed `Chain`.
4. `Text` is `String`, and 0.2's `String`, a read view, is `?String`.
5. Self is `@`: a method declares `?@`, `!@`, or `<@` and its body says
   `@x`, `@m()`; `?self`, `self.x`, and a typed `self: ?P` are rejected.
6. A label is `$outer:` and `break $outer`, not `:outer`.
7. A built-in call is `$size(T)`, `$truncate(x)`, not `@size(T)`.
8. A fixed binding is `x =! e`; `const` is rejected.

Renamed, by hand (no script):

9. `replace(!p, v)` is `swap(!p, v)`, and a Cell's `c.replace(v)` is
   `(!c).swap(v)`.
10. A statement `-x` no longer drops `x`; `<x` does.
11. `w.upgrade()` of a weak handle is `*w`.
12. A compile-time value parameter starts with a lowercase letter,
    `[n: Int]`, and a type parameter with a capital, `[T]`.
13. `text.valid_utf8` is gone; `utf8.is_valid` checks a `?String`.
14. A built-in named through a module, `lib.Vec[Int]()` or
    `lib.Cell(1)`, is "no member" (#646); write `List[Int]()`, `Cell(1)`.
15. `panic` is a keyword, so no function or binding takes the name.
16. `Task`, `Tasks`, `Chan`, `Actor`, `Frozen`, `Simd`, `Symbol`,
    `Static`, `Int`, `Float`, `Bool`, and the sized numbers name built-in
    types, and a program's own type may not take one.
17. An enum's variant may not be named `none`.

Public generics:

18. A `pub` generic states, by bounds, everything its body does with a
    type parameter (`[T: Num]`, `[T: Ord]`, `[T: Copy]`, `[T: Eq]`,
    `[T: Print]`, `[T: Clone]`); `tools/state-bounds.py` writes them.
    It states `Print` too where it passes a `T` to a generic that prints
    it, `pub sub show[T](x: ?T)` calling a private `helper(x)` that
    does `print(x)`, which the compiler reports with the fix.

Syntax:

19. An operator has the same spacing on both sides: `x -1`, `a <b`,
    `a *b`, `a +b`, `steps= 1`, and `n.. 3` are rejected with the two
    spellings each could mean.
20. A bracket, a call's parenthesis, a member's `.`, and a postfix `?`
    touch what they follow: `a [1]`, `obj Wrap [T]`, `xs .len`, `. red`,
    `Int? ?`, and `f(x) ?`.
21. `not a == b` is `a != b` or `not (a == b)`.
22. `catch` binds as `??` does, so a handler that compares or chooses is
    parenthesized: `f() catch |e| (1 if e == E.bad else 2)`.
23. A closure body below its bar list ends with its line; the `)` that
    closes the call goes on the next line.
24. A write call whose `Bool` value is used is parenthesized:
    `if (!s).add(k)`, not `if !s.add(k)`.
25. A lend is written on a whole path, not its base: `v.len` and
    `<s.o`, not `(?v).len` and `<(!s).o`.

Cells, handles, and views:

26. An object, enum, or element that holds a `Cell` or a `Signal` lives
    behind a shared handle, `*C(...)`.
27. A call that changes a Cell or a Signal is marked with `!`:
    `!c.set(v)`, `!s.subscribe(f)`, `(!b.c)[i] = e`; through a read view
    a Cell is not changed.
28. A write view, `!T`, is no field's or element's type.
29. One heap holding: `Box[Box[T]]`, `Box[*T]`, `*~T`, and a box of a
    function are rejected; and a type alias of a box is not called as a
    constructor (`^5`, not `BI(5)`).
30. `read[U8, .big]`, a byte order on a one-byte type, is rejected.
31. `!x` lent where the callee only reads, or a copy goes, is `?x` or
    `x`.
32. A method's result that views self, bound to a name, is written as
    the lend it is: `r = ?b.first()`, not `r = b.first()`.
33. *Unsound:* a function that stores a view of a parameter in what its
    caller reaches says so, `keeps t`.
34. *Unsound:* a lend of a branching value that may be a named value,
    `(a if c else b)[0].m()`, lends each branch; `o ?? w` does not copy
    out an object that holds a Cell.
35. *Unsound:* a temporary that owns a resource, with nothing to drop
    it, is bound to a name first.
36. *Unsound:* a scope's defers run after the value it gives, so a
    `defer` may not change, drop, or lend to write what a block's value,
    a `return` value, or a `break` value views (`defer !@xs.clear()`
    before a last value `!@xs[0]`); and `return s` or a last value `s`
    of a write view moves `s`, so no defer, closure a defer calls, or
    task waited for at the scope's end may use it after.

Effects and errors:

37. `time.sleep` can fail (a canceled task stops there): `time.sleep(n)!`
    or a `catch`.
38. Two caught errors are not compared with `==`; compare one with a
    member, `e == E.bad`, or match it.

Other:

39. A closure never called (`_ = |x| x + 1`) is rejected.
40. `*g` of a function, where a `*fun` goes, is `*|| g()`.
41. A method's parameter may not take the name of a module-level
    declaration.
42. A directory's `.rig` files are one module, sharing one namespace, so
    two files beside each other that 0.2.9 took as separate modules may
    not declare the same name; move one into a directory of its own.
43. A read view of text, `?String`, is not lent to write (`w = !s`);
    hold a `String` to change text in place.

43. A write view re-pointed inside a `match` arm at the payload the arm
    binds (`w = !p[0..1]` in `.has(p)` of `match !o`) is rejected: the
    binding ends with the arm. Write through `p` inside the arm instead.
44. *Unsound:* a closure parameter given `!?String` by the type the
    closure is checked against, as `|k, v|` passed to `update` or
    `retain` of a `Map[K, ?String]`, is rejected, as a written
    `!?String` is: the body could store the key's view in a value that
    outlives it. Leave the parameter out (`|k| ...`) or name it `_`,
    hold the values as `String`, or walk the Map with `items`.
45. *Unsound:* a generic body's value that it holds by value tracks no
    view, so an instance whose type argument can hold the view the body
    could put in one is refused (SPEC "Generic bodies"):
    - `update`, `retain`, and `ensure_with` of a `Map` or `HashMap`
      whose value type can hold the key's view: `(?String)?`,
      `List[?String]`, `?String` (`retain(|k| ...)` too), an object, an
      enum, or an API object that holds a `?String`, even with a closure
      that stores nothing. Hold a value that owns what it holds, or walk
      `items`;
    - a program's own generic body that gives a function value (a
      closure, a named function, an owned closure, one held in a field)
      a write view of a `T` it holds beside another view, or holds as a
      `T` a function value's result given a view of its own memory (a
      local, a parameter given by value, self's storage), at an
      instance whose `T` can hold the view; and one that holds as a `T`
      the result of a type argument's method that views self or an
      argument. Give the instance a type that owns what it holds.
46. A write view of a read view, `!?T` (`!?List[Int]`, `!?Int`), is
    rejected as `!?String` is, written or given by the type a closure
    is checked against (`update` of a `Map[K, ?List[Int]]`).
47. *Unsound:* a float provides no `Ord`, since a NaN is neither below
    nor above a number (SPEC "Floats in order"). `v0.2.9` ordered floats
    by Zig's `std.math.order`, which reaches `unreachable` on a NaN: a
    panic in safe builds, undefined behavior under `--release=fast`. And
    `sort.sort` left floats holding a NaN unsorted. Rejected now, each
    with the fix in the message:
    - `sort.sort`, `sort.lower_bound`, `sort.search`, and
      `sort.sort_by_key` with a float key: sort with
      `sort.sort_by(!xs, |a, b| a.total_order(?b) == .less)`;
    - `math.min`, `math.max`, and `math.clamp` of floats: write
      `a.min(b)`, `a.max(b)`, `x.clamp(lo, hi)`, where a NaN loses to a
      number;
    - a program's own `[T: Ord]` generic at `Float` or `F32`, and a
      body's `a.order(?b)` at a float;
    - `obj` or `enum` that names `Ord` with a float field: write its own
      `fun order(?@, other: ?Self) -> Order` with `total_order`;
    - `x.order(?y)` of floats: write `x.total_order(?y)`;
    - `<`, `<=`, `>`, `>=` on an optional, an array, or a slice of floats.
    `<` on two floats stays, IEEE 754's, and so does `math.abs`, which
    takes `T: Signed`.
48. A method with the very signature a built-in API fixes,
    `fun eq(?@, other: ?Self) -> Bool`, `fun order(?@, other: ?Self) ->
    Order`, `sub hash_into(?@, h: !Hasher)`, or `sub print(?@, out:
    !Printer)`, on a type whose header does not name the API, is
    rejected: `==` and the others passed it by. Name the API on the
    header, `obj P: Eq`, or rename the method; under another signature
    the method stays an ordinary one.
49. A parameter `?^T`, a read view of a box, is `?T`, which takes a
    `^T` too: `fun eval(e: ?Expr)`. A `!^T` parameter, which may
    replace the box, and a view of an optional box, `?^T?`, stay.
50. A clone that copies a String's bytes or a value's parts into a read
    view, `peek(+w)` where `peek` takes a `?T`, a `[]T`, or a
    `?String`, or `(+w).len()` of a `?@` method, is a lend:
    `peek(?w)`, `w.len()`. A clone the same call keeps apart from a
    write lend or a move of the original, `g(+w, !w)`, stays.
51. *Unsound:* a Cell or Signal reached through a read view of a
    handle is not changed: `!n.c.set(5)` with `n: ?*Node`, through `if
    n as x` of an `n: ?(*Node)?`, a `?@` method's `if @head as x`, a
    read match's or `for` loop's binding of a handle (`for h in hs`), or
    a closure's `|?h|`, is rejected, as `?Cell[T]` was ("cannot lend to
    write through a read view `?*Node`"). Change it through a handle of
    your own (`mine = +n`, then `!mine.c.set(5)`), or take a write view
    (`n: !*Node`, `if !o as x`, `for h in !hs`, `!@`).

52. `file.FileError` gains a member for each reason the system gives:
    `not_permitted`, `read_only`, `loop`, `name_too_long`, `busy`,
    `cross_device`, `no_space`, `invalid`, `bad_descriptor`,
    `broken_pipe`, and `io`. A `match` over a `FileError` with no `_`
    arm names them or adds one. `denied` is now only EACCES: EPERM is
    `not_permitted` and EROFS `read_only`, and EBADF (a write to a file
    opened to read), once `denied`, is `bad_descriptor`; a program that
    caught `denied` for those catches the new member too. What was
    `failed` for these reasons is its own member now.
53. *Unsound:* a member with fields written short without them, `.bad`,
    where an `error` or a union goes, was accepted and printed fields
    never written. Give it its fields, `.bad(at: 3)`, or name its set
    with them, `Oops.bad(at: 3)`.
54. A short-form member lent where a view of a union or of
    `error` goes, `.plain` passed to a `?Both`, is rejected, as
    `Oops.plain` there is. Bind it first, `k: Both = .plain`, then lend
    `?k`. Trig needs no migration: its emitted Zig is unchanged.
55. `Os` names a built-in type, the operating system `target.os` gives,
    so a program's own type may not take the name, as it may not take
    `Arch`. No program in Rig, Trig, or loco declares one, so Trig needs
    no migration.

One form changes meaning rather than failing: a binding with no type of
a loop's value that is a write view at every `break` (`l = while true`
then `break slot(!n)`) holds the write view, as an `if` does, so `l = 1`
writes 1 into `n`. `v0.2.9` copied the value, so such a program compiles
under both and now writes where it read. Give the binding its value's
type, `l: Int = while ...`, to copy as before, or keep the view.
`tools/migrate-0.3.py` prints a `MANUAL` line for each such binding and
rewrites none; 2 of the 4,836 v0.2.9 programs have the shape, at one
site each.

Programs written against `main` since `v0.2.9` also meet forms that
changed again before 0.3.0: `Moves` and `Shares` are `Sends` and
`Syncs` (`tools/rename-task-bounds.py`), `std.hash` is gone
(`tools/migrate-builtin-map.py`), `Symbols` is `text.Interner`
(`tools/rename-interner.py`), `rarely fun` is `rarely` in the body
(`tools/rarely-body.py`), `b'A'` is `'A'`, an iterator in a place is
`for x in !it`, `within:`, `wait_all`, and `task.both` are gone, and a
public generic that nests itself through a call through an API is
reported where it is declared (#647). MIGRATING-0.3 lists each.
`std.json` callers change nothing: `parse` still answers a `Bool`, and
`load`, failing with `JsonError`, is new.

### Language and compiler

- **`none` of a large optional is one store.** A `T?` over 16 bytes
  whose `T` is an object, a payload enum, or an array writes `none` by
  its flag alone, where Zig wrote every byte of it zero: an empty pop of
  sanstun's 176-byte `Event?` takes 0.26 ns, from 1.9. A payload enum's
  optional now goes through the optional helpers, as an object's does,
  and under `RIG_STRICT_OPTIONALS` is a tagged struct too. A payload
  variant literal compared with an optional (`o == .square(side: 2)`)
  is its payload's value.
- **`target.os`, the operating system a program is compiled for.**
  `std.target` gives `os: Os` beside `arch: Arch`: a value of the
  built-in enum `Os`, whose variants are Zig's (`std.Target.Os.Tag`:
  `.macos`, `.linux`, `.freebsd`, `.windows`, ...), lowered to Zig's own
  type and checked as `Arch` is. A constant that differs by system, a
  signal's number or a `sysconf` name, branches on it,
  `SIGBUS = 7 if target.os == .linux else 10`, and Zig keeps the branch
  the target picks.

- **`rig test std.NAME` runs a standard library module's own tests.**
  `rig test std.crypto` loads `std.crypto` from the library in use, the
  one built into `rig` or `RIG_STD`'s, as the library loads it, and runs
  its test blocks, a directory module's `*_test.rig` files included, so
  a test reaches the module's private names. `rig test std` is rejected,
  and a path still names a program's file.

- **A view of an array held where a slice goes is lent as one.** A
  `?[4]U8` parameter or binding passed bare where a `[]U8` goes, as an
  argument, a binding's value, or an assignment's, reaches Zig as the
  address it holds, where it was written as the array and rejected by
  Zig; a field or an element always was.
- **A short form a fallback gives is written with its type.** The
  checker records each `.name` and `.name(fields)` a `??` or `catch`
  fallback gives, through a branch, an arm, or a block, a bound
  `catch |e|`'s handler included, since its enum's type comes from the
  value the fallback stands for, which Zig does not see: `f() catch |e|
  .err(e)` for an `Out?!E`, and `o ?? (.red if n == 1 else .blue)`,
  were accepted and then rejected by Zig.

- **A lent String or List is appended to in registers.** A function
  lent a `String`, or a `List` with no inline room, to write, which uses
  it in a loop, holds the String's or List's header (its pointer,
  length, and capacity) in a local for its body and writes it back as it
  returns: the storage fact `held_header`. The call's write loan is the
  header's only one while the function runs, so no other code can see
  the difference, and a loop of appends no longer stores and reloads the
  length each time. coreutils' `basenc --base16` encode, whose loop
  appends to a lent String, takes 81 ms of user time on the Mac, where
  it took 218 (and 119 before #780, whose paired load of the length and
  capacity stalled on Apple cores). Not held: a parameter a task, a
  closure, or a `raw` block names, or one of a function whose result
  holds a view (docs/history/records/2026-10/store-forward/).

- **`std.hint.keep`, `net.Ip` and `net.Addr`, and an `Instant` that
  adds and orders.** `hint.keep(?x)` is Rust's `black_box`: an empty
  `asm volatile` that takes `x`'s address and clobbers memory, so a
  benchmark's result is computed and no load moves out of its round.
  `net.Ip` is an IPv4 or IPv6 address and `net.Addr` one with a `U16`
  port, plain data that compares, hashes, prints in the usual text
  (RFC 5952 for IPv6), and parses (`Ip.parse("::1")`,
  `Addr.parse("[::1]:51820")`); `ip.prefix(n)` keeps the first `n`
  bits, the key of a limit by /32 or /64. `time.Instant` is `: Ord`,
  with `t.add(ns)` and `Instant.at(ns)` for code handed the time. A
  Zig-backed function of the standard library may take bare type
  parameters, which its Zig function takes first, when it cannot fail.
- **std.io gives the standard streams.** `io.stdin()`, `io.stdout()`,
  and `io.stderr()` are `file.File`s on descriptors 0, 1, and 2, left
  open when dropped, so `cat` is `io.copy(!f, !out)` and stdin reads as
  any file does, a block at a time, without opening `/dev/stdin` (which
  on Linux opens the file again, losing a shared offset and truncating
  a `>>` target). A write to stdout goes through `print`'s buffer, and
  one to stderr writes that buffer out first, so all four stay in order;
  a write adds no newline, and `File.flush` writes the buffer out. A
  write that fails is a `FileError`, not the end of the program.
- **`File.read` reads into the caller's buffer.** The read fills the
  room `into` has, on the blocking pool, and allocates nothing when it
  has room for `max` more: one buffer, cleared and read into again,
  carries a whole file. Reading 247 MB 64 KiB at a time into one buffer
  takes 19.3 ms on an M-series Mac, against 32.6 ms before (24.9 ms with
  a fresh String for each read, now 19.7 ms) and 19.6 ms for `cat`.
- **`FileError` keeps the system's reason.** Each errno a file call
  meets is its own member (`no_space`, `broken_pipe`, `loop`,
  `cross_device`, and seven more), and `file.reason(e)` gives the
  system's words for it, as `strerror` does: `true: No space left on
  device` prints as the system's tools print it, not as `Input/output
  error`.
- **A member written short, `.name` or `.name(fields)`, is the error
  value its set makes, wherever the set goes.** The checker records the
  set it names, and emit writes from that: `.bad(at: 3)` passed for an
  `Oops`, returned, held in a field, a List, an array, a Map, a branch,
  an arm, a closure, or a fallback was accepted and then rejected by Zig
  as a field of `rig.ErrorValue`, and so was `.plain()`. Where `error` or
  a union goes, `.name(fields)` is the member of the one set that has
  it, as `.name` was; `.bad` without its fields there is rejected, where
  it was accepted and read fields never written (*unsound*). A member of
  a set without fields is widened to an error value there, and a
  default `.plain` of a set with fields is one. A short-form member lent
  where a view of `error` or a union goes is rejected as `E.name` is.
  `.bad(at: 3)` where a `T!` goes says to name the error set. A payload
  variant as a `??` or `catch` fallback in print's arguments names its
  enum, which Zig needs there.
- **`os.on_broken_pipe(how)`:** a program that calls
  `os.on_broken_pipe(.die)` dies by SIGPIPE when the reader of its
  stdout closes the pipe, as a C program does, so `yes | head -1` gives
  a shell status 141, whether it writes by `print` or through
  `io.stdout()`; `.exit`, the default, still ends a `print` quietly with
  status 0 and fails an `io.stdout()` write with
  `FileError.broken_pipe`. A failed `warn` is still dropped, and a socket's closed peer
  is still `net.NetError.closed`.
- **A SIGSEGV or SIGBUS that was sent ends the program by that
  signal.** `kill -SEGV`, `kill -BUS`, or a program's own `kill` of
  itself ends it as the signal's default action does, status 139, or
  138 for SIGBUS on macOS and 135 on Linux, with no message. The stack
  guard's handler and the sanitizer's took every such signal for a
  fault outside their pages and returned, so a sent one was lost: the
  program went on, a second one aborted it (134), and a later stack
  overflow lost its message. A real fault is reported as before.
- **`std.crypto`: WireGuard's primitives, in Rig and in constant
  time.** `crypto.ChaCha.of(key)` and `crypto.XChaCha.of(key)` seal and open
  ChaCha20-Poly1305 and XChaCha20-Poly1305 in place
  (`tag = c.seal(!packet, nonce, header)`, `c.open(!packet, tag, nonce,
  header)!`) or from one buffer into another (`seal_into`,
  `open_into`); an open with a wrong tag fails with `crypto.Forged` and
  leaves zeros. `std.crypto.x25519` has `Secret` with `public()` and
  `share(peer)!`, which refuses a low-order key with
  `KeyError.low_order`; `std.crypto.blake2s` has `hash`, `mac[n]`,
  `Hasher`, `hmac`, and `Hmac.of(key)`; `crypto.wipe`,
  `crypto.equal`, and `crypto.random` round it out. Key objects keep
  their keys private, print as `ChaCha(…)` and the like, and wipe
  themselves when they drop. A small Zig file sets Arm's DIT bit around X25519, wipes so the
  optimizer keeps it, and keeps masks from becoming branches. On the
  Mac X25519 is 1.3x as fast as dalek and BLAKE2s 5% to 14% faster than
  blake2; the AEAD beats ring at 8192 bytes and on most opens, and
  trails it on shorter seals (record:
  docs/history/records/2026-10/std-crypto/).
- **ChaCha20-Poly1305 on x86-64 MACs a block at a time.** Past 192
  bytes, the loop on x86-64 runs Poly1305 on 64-bit limbs, four blocks
  one at a time after each of the first 8 double rounds, as a measured
  Zig ceiling does: its one multiplier port makes arm64's 44-bit,
  four-block step twice the work. arm64 keeps that step, as fast as it
  was. The loop is one function, generic over its MAC, and
  `rig test std.crypto` checks both MACs on any machine.
- **A range's counter has its bounds' type.** The counter of `for _ in
  a..b`, and of a bare `for a..=b`, has the type the checker records on
  the range, as a named binding's always did: a range of `U64`, `U128`,
  or `I128` bounds was accepted and then rejected by Zig, which got an
  `i64` counter, and a narrower one counted in `i64`. Every integer type
  runs through its largest value with `..=` and from its smallest.
- **A HashMap's `ensure` lends the value where its table found the
  key.** The table's `ensure` peels the home group, as a lookup does, so
  a key found there returns before the probe keeps a free lane, and it
  lends the value from the slot it found rather than giving an index
  that `value_mut` turns back into the slot; it writes the HashMap's
  `len` only for a new key. A put keeps its own pass, which lays out
  faster for new keys. `ensure_with` and `ensure_by` lend a key's
  value from `edit` when it is there. knucleotide's counts on tables of
  4, 16, and 256 keys (`kn12.rig`) take 9%, 15%, and 13% less time on
  the Mac, within 5% of Rust's hashbrown either way, and 33%, 28%, and
  34% less on pup, less than hashbrown's; bench/hash's `ensure` and
  `ensure_with` rows take up to 13% less on the Mac and 24% on pup, no
  row slower
  ([small-table.md](docs/history/records/2026-10/hash-race/small-table.md)).
- **A large optional result through an API object goes out through
  the caller's place.** A table entry whose result is an optional wider
  than three words, a `Hit?`, writes the value through a place the
  caller lends and returns whether there is one, so a `none` writes
  nothing; the call gives the same `T?` as before. A `none`'s payload,
  and that place, are no longer filled with 0xaa in a safe build.
  ray-dyn: 10% fewer cycles in a fast build and 28% fewer in a safe one
  on the Mac, 18% and 21% fewer on pup, where it is now level with the
  Rust's `Box<dyn>`.
- **A loop of appends keeps a String's or a List's fields in
  registers.** A String's `push`, `reserve`, `push[T, e]`,
  `push(v, keep: k)`, and `add`'s bytes, and a List's `push` and
  `reserve`, grow through one out-of-line function each that takes the
  buffer and returns the grown one by value, so no append passes the
  String's or List's address to a call, and a local's length is no
  longer loaded and stored back on every append. On the Mac a loop of
  pushes to a local String takes 32% less time, to a local `List[Int]`
  39% less, and to a List in a field 21% less; the Benchmarks Game's
  revcomp plain takes 25% less, knucleotide plain 11% less, and Trig on
  pup runs ts-pattern 1.6% and zod3 1.0% faster.
- **A shared value made in a variant's call is the payload's value.**
  `Frame.bulk(data: *Frozen(String("x")))`, and a `*Chan[T](n)` or
  `*Actor(x)` made there, recorded its own signature on the variant's
  callee, so the variant was written as a Zig call that did not
  compile; each call now records only its own. `*Actor(x)` takes its
  type from `x` wherever an `*Actor[T]` is expected (a typed binding,
  an argument, a field, a payload), as `*Frozen(x)` does; it was
  rejected as an opaque type before.
- **`slices.reverse` swaps the first half with the last, its indexes
  proven.** It counts `i` over `0..n / 2` and swaps `xs[i]` with
  `xs[n - 1 - i]`, and the proof pass now proves both: a `for` over
  `0..b / c` bounds its binding by `b`, an index `b - c - i` counted
  down from the end is in range when `i + c <= b` and `0 <= i`, and a
  `!s.swap(i, j)` whose two indexes are proven omits their tests
  (`rig.swapProven`). Its loop was 13 instructions a swap on arm64
  against Rust's 6, and fannkuchredux, which flips with it, took 10%
  more cycles than Rust's; it now takes the same (n = 11: 6.32 billion
  cycles on the M5 against Rust's 6.33, 8.67 on x86 against 8.69).
- **A generic function is inlined by the size rule.** The compiler
  inlined no function with compile-time type parameters unless it was
  marked `inline`; it now judges one as any other function, under the
  largest frame of its instances, so a small generic helper costs what
  the same helper written for one type does. The ray tracer's generic
  `ray_color` needed `inline` for that: without it ray-dyn took 3% more
  cycles, and now takes the same as with it.
- **An instance calling another instance is no cycle.** The yield
  checks of recursion (docs/internals/scheduler.md) treat each instance
  of a function whose compile-time parameters are values as a function
  of its own, and skip a call in an `if` branch its values rule out, so
  `at[true]` calling `at[false]` no longer puts a check at `at`'s
  entry. The check on every call kept LLVM from vectorizing the calls
  of `at` in spectralnorm's inner loop: without it spectralnorm-fast
  takes 1.65 times fewer cycles. An instance that reaches itself, as
  `down[true]` calling `down[false]` calling `down[true]`, still checks.
- **A method call's self is lent where it is, an element too.**
  `?@balls[i].hit(lo)` on a `List[Ball]` whose `Ball` copies gave `hit`
  a view of a copy of the element, so a result that keeps self (`from
  @`) viewed a temporary the next turn of a loop wrote over: every hit
  took the last ball's material. Each element on the path of a lent
  self (`?xs[i].m()`, `?xs[i].f.m()`, `?g[r][c].m()`, a slice's element,
  a generic method's self) is now reached in place, as a `!` self
  already was. *Unsound before.*
- **A write call whose value is used is written short,** `x =
  !v.pop()`, `t = !@new_node(k)`, `while !it.next() as x`, in a
  binding, an argument, an `as` header, under `??`, and in a result.
  Only a call whose method declares a `Bool` result (or `Bool!`) keeps
  its `!` in parentheses where its value is used, `if (!seen).add(k)`,
  so it never reads as `not`; a call returning a `T` is short even
  where `T` is a `Bool`. The long form `(!v).pop()` stays valid
  everywhere. The change only accepts programs rejected before, and
  `tools/drop-write-parens.py` drops the parentheses no longer needed.
- **`^T?` and `~T?` are a pointer's size:** `none` is the null
  address, as it is for a `*T?`, so an optional box or weak handle is 8
  bytes, not 16, and a list node of an `Int` and a `^Node?` is 16 bytes.
- **A field taken with `<p.f` and assigned again drops nothing:** the
  ownership checker knows it holds `none` until it is written or lent
  to write, so `@head = ^Node(elem: <e, next: <@head)` stores without a
  drop of the old value; a drop of an optional tests for `none` where
  it is, before it calls out.
- **The last drop of a short chain of boxes or handles calls nothing
  more:** the queue that deep chains are released through is drained
  only when a release left something in it.
- **A `*T` handle's drop is inline while the count stays above zero:**
  the decrement and its test are where the handle drops, and only the
  last handle's release is a call.
- **An optional view compares as the optional of what it views:**
  `(?Int)? == 3`, `!=`, beside `none`, an `Int?`, or another `(?Int)?`,
  `(?String)?` beside any text or optional of text, and `(?P)?` of an
  object that provides `Eq`, as `?Int == 3` and `Int? == 3` did.
- **A taken binding that owns a resource is lent to write:** `if <o as
  node` then `bump(!node)` of a `bump(h: !*Node)` compiles, as it did
  for a `String`, a List, or a box, for a handle too, in `if … as`,
  `while … as`, `match <x`, and `for x in <v`, in a generic body as in
  a plain one; the binding is a Zig `var` wherever it is written
  through, where a handle's was a `const` that Zig rejected. A taken
  binding of plain data stays a copy that is not written, and one of a
  type parameter's value is moved into a new binding: `new x = <x`.
- **A read view of a handle changes nothing.** A write lend reached
  through any read view is rejected, a Cell or Signal behind a handle
  the view holds or reaches included, with the read view's message,
  "cannot lend to write through a read view `?*Node`"; a handle field
  under a read view (`!w.h.c.set(5)` with `w: ?W`) named the shared
  handle instead. The emitted Zig had written through a `*const`
  (Upgrading, item 51).
- **A generic object holds an optional view of itself:** `prev:
  (?Frame[T])?` in `obj Frame[T]`, a pair of generic objects that view
  each other, and an enum that views itself compile, as their plain
  forms do; a view of an object is a pointer whatever its type
  arguments. A field that names the object's own optional, `T?`,
  anywhere the object's layout needs it (`?Node?`, `List[Node?]`,
  `^(Node?)`, `*(Node?)`, or a generic instance whose fields name it)
  is rejected with the two forms to hold instead, `(?Node)?` or
  `^Node?`; Zig rejected each before.
- **A literal is self of a call through an API:** `Twice.twice(4)` and
  `5.twice()`, given `add Int: Twice`, call `Int`'s method, as
  `Twice.twice(x)` of an `x: Int` does, and a literal that does not fit
  `Int` is reported there.
- **`async` and `await` say what Rig writes instead:** a task is
  started with `f(x)&` and waited for with `>t`.
- **`rarely` in a branch is unlikely:** a `rarely` that starts a branch,
  a `catch` handler, or a loop's body emits Zig's unlikely hint, which
  keeps the block near and lays out the code around it for the path
  that skips it; a `rarely` that starts a function's body still emits
  the cold hint, which moves the function out of line.
- **A frozen value's allocation has no weak count.** A `*Frozen[T]`
  holds a strong count and the value, 8 bytes less than before, and its
  last drop is one atomic decrement that frees the allocation, as a
  frozen value has no weak handle. A `*T` is unchanged
  ([frozen-no-weak](docs/history/records/2026-10/frozen-no-weak/README.md)).
- **`!s.swap(i, i)` leaves the element in place** without handing Zig's
  `std.mem.swap` one place twice, which Zig leaves undefined.
- **A `*Cell` of one word has a cache line of its own** in a program
  that makes tasks: its allocation is aligned and sized to 128 bytes,
  where it took 24. Four tasks each adding to its own Cell, the Cells
  made one after another, took 4-10× as long as one task did. They now
  take the same time
  ([atomics](docs/history/records/2026-10/atomics/README.md)). Every
  other `*T` keeps its size.
- **`for x in ?h` walks a List or an array that a shared handle
  holds**, `*List[T]`, `*Frozen[List[T]]`, or `*[N]T`: it reads each
  element in place, with the loan on `h`, as `?h` lends the value the
  handle holds (SPEC §6 "for"). Tasks walk one frozen List each through
  its own handle. `for x in !h` and `for x in <h` stay rejected, each
  with its own message, since nothing is written or taken through a
  handle.
- **A type that contains itself is told to box the field that leads
  back:** "`Node` contains itself by value through `next`, so it would
  have no finite size; own it through a box (`next: ^Node?`), or share
  it through a handle (`*Node`)". The message suggested only `*Node`, a
  shared handle, which a tree or a list of its own nodes does not want.
- **The runtime's hot helpers make none of Zig's checks that the
  runtime's own invariants prove** (`len <= buf.len`, `len < n`, a
  block aligned by its class) in an optimized build: List's `pop`,
  `items`, and `IntoIter.next`, `at`, `elemPtr`, and `swap` after their
  index test, a table's `push`, String's copies, `FnRef`'s context,
  `freeSlice`, and the allocator's `free`. A debug build keeps the
  checks and asserts each invariant. Trig retires 1.7% fewer
  instructions on ts-pattern and 1.3% fewer on zod3, with `.text` 2.2%
  smaller
  ([runtime-unchecked.md](docs/history/records/2026-10/perf-stage/runtime-unchecked.md)).
- **A Map or Set is 64 bytes, a cache line** (it was 112): the table's
  small tags share their place with an indexed table's index pointers,
  and its counts are narrower; an indexed table of 33 to 48 entries holds
  room for 48 rather than 64. Lookups, puts, takes, and walks run as
  before. On pup, Trig's peak memory is 3.5% lower on ts-pattern (9.8 MB)
  and 4.3% on zod3, with 5-7% fewer L3 load misses and 3-6% fewer kernel
  cycles, user cycles level
  ([small-maps.md](docs/history/records/2026-10/hash-race/small-maps.md)).
- **bench/hash's guard builds its key lists out of line** (`called`), so
  each row's loop runs to the List's length rather than to a constant
  LLVM knows and may build again on every lookup. With it, Rig before
  and after growth by value counts the same on every row (HashMap
  text-hit 100.78 and 100.84 instructions, text-miss 61.96 and 62.15),
  where with the constant the HashMap's text rows read 3.3 and 3.6% more
  after it. The baseline is written again.
- **bench/hash's guard gives the same counts every run.** Each row's two
  runs differ by about 1,000 million instructions, and each count is the
  least of 5, so the 1 to 2 million instructions the kernel adds to a
  run move a row by 0.2% at most, where they moved a cheap row by up to
  7% and failed the guard on `main` in 2 runs of 5. The baseline
  is written again for the Map of 64 bytes, whose rows it predated.
- **bench/hash times each row in a function of its own**, for every
  contestant (`called`, `noinline`, `#[inline(never)]`,
  `__attribute__((noinline))`, `//go:noinline`), so a row's loop is
  compiled for itself and not with the other rows of its group. Every
  line's checksum is unchanged; the guard's program already timed each
  row alone, and its baseline is unchanged.
- **A HashMap grows without waiting on its own stores, on x86-64.** A
  growth to twice the groups places each entry at the next free lane
  of its new group, kept as a count, where it loaded the group's control
  bytes just after the entry before it wrote a tag there, a load that
  waits for the store to commit. bench/hash's growing inserts are 5-36%
  faster on pup and no row is slower; arm64, whose random-key inserts
  were 4-6% slower with the counts, keeps its placement
  ([rehash-counts.md](docs/history/records/2026-10/hash-race/rehash-counts.md)).
- **The built-in tables have a guard.** `bench/hash/guard.py` counts the
  instructions per operation of `Map` and `HashMap` on Int, text, and
  two-word keys, and fails any row more than 2% over its baseline, as
  `bench/json/guard.py` holds std.json; AGENTS.md makes it a gate for
  compiler, runtime, and std changes.
- **`String(...)` is one block of its length.** Text of up to 256 bytes
  is written on the stack and allocated once, as Rust's `format!` makes
  one block, where it grew the String's buffer piece by piece and left
  each key scattered with spare room. bench/hash's text hits at 100,000
  keys take 7.0 ns, not 16.3, against the Zig prototype's 5.7, and text
  removes are faster than the prototype's. A HashMap walk steps by the
  table's `next_slot`, with no checked arithmetic in the loop, so its
  iterate rows are level with the prototype; a HashMap prefetches its
  40-byte text slots; and a Map's rebuilt index clears only its tags
  ([table-gaps.md](docs/history/records/2026-10/hash-race/table-gaps.md)).
- **A float provides no `Ord`.** A NaN is neither below nor above a
  number, so `T: Ord` takes no `Float` or `F32`, a header that names
  `Ord` takes no float field, and a float has no `order`; each
  rejection names `total_order`, or a float's `min`, `max`, or `clamp`
  in place of `math`'s. Comparing two `obj V: Ord` values with a NaN
  field reached Zig's `unreachable`, and `sort.sort` left floats with a
  NaN unsorted. `<` on floats stays IEEE 754's.
- **Floats have methods that compare them.** `x.min(y)` and `x.max(y)`
  give the smaller and the larger float, and a NaN loses to a number
  on either side. `x.clamp(lo, hi)` limits `x` to `lo..hi`.
  `x.total_order(?y)` is the `Order` of IEEE 754's totalOrder, which
  places every float, NaN too, so floats that may hold a NaN sort with
  `sort.sort_by(!xs, |a, b| a.total_order(?b) == .less)`. A `T: Num`
  (and so a `T: Integer` or `T: Signed`) is compared with `<`, `<=`,
  `>`, and `>=` as a number is, and `math.abs` takes `T: Signed`.
  They take the place of `Ord` for floats (SPEC "Floats in order").

- **A generic body's own values hold no untracked view.** A `T` the
  body holds by value carries no loan it tracks, so an instance whose
  type argument can hold the view the body could put in one is refused
  at the call or type that makes it, with a note at the body line:
  where a function value is given a write view of one beside another
  view, where the body holds as one a function value's result given a
  view of memory it owns, and where a type argument's method gives a
  view of self or an argument held as one. The function value's type at
  the instance decides (`sema.defaultOrigins`), so `update` of a
  `Map[?String, Int]` passes. A method's requirement is checked at each
  call of it, so a `Map[String, (?String)?]` is refused only where
  `update`, `retain`, or `ensure_with` is called on one, and
  `ensure_with` keeps nothing of `make`. The oracle refuses those three
  calls alike. A write view of any read view, `!?T`, is rejected as
  `!?String` is, which also ends the Zig a closure's `!?List[Int]`
  parameter could not compile.
- **`HashMap[K, V]` and `HashSet[K]`**, built in beside `Map` and `Set`:
  hash tables whose iteration order is unspecified, with every member
  of `Map` and `Set`, declared as theirs are, but `Map.at`. Their
  entries are held by the compiler built-ins `UnorderedMap[K, V]` and
  `UnorderedSet[K]`, bench/hash's `zig-hash` in the runtime
  (src/unordered.zig). Against the Map, on the Mac and pup: removes at
  4M keys 25-35% faster, turnovers of 1,000 keys and up 23-52% faster,
  misses at 3M-4M 52-81% faster, random hits there 35-45% faster; walks
  and text removes stay the Map's. Of bench/hash's 104 rows, 60 on the
  Mac and 77 on pup are within 5% of zig-hash or faster; 4,000,000 Int
  keys take 51.1 and 54.5 bytes an entry
  ([hashmap-builtin.md](docs/history/records/2026-10/hash-race/hashmap-builtin.md)).
  A program's own type named `HashMap`, `HashSet`, `HashItems`,
  `HashKeys`, `HashValues`, or `HashMembers` hides the built-in one.
- **Map and Set hold their entries in a table built into the compiler**,
  `OrderedMap[K, V]` and `OrderedSet[K]`, which only std/prelude.rig
  names: bench/hash's `zig-ordered` in the runtime (src/ordered.zig),
  as a List's buffer is. `Map` and `Set` keep every declaration in the
  prelude, so every member, its ownership, the order, printing, and
  every diagnostic a test names are unchanged; a message about a Map's
  `==` or `.hash()` names its field `t` where it named `ps`. On pup,
  Trig takes 2.9% fewer cycles on ts-pattern and 3.6% fewer on zod3,
  with 2.2% and 3.1% fewer instructions, and peak memory 0.55% higher
  and 0.8% lower. A Map is 112 bytes (176 before), and holds 4,000,000 Int keys in
  30.7 bytes an entry on the Mac. In bench/hash, 108 of 130 rows on the
  Mac and 109 of 114 on pup are faster than before
  ([map-builtin.md](docs/history/records/2026-10/hash-race/map-builtin.md)).
- **A Map or Set of plain wide keys keeps no hash in its entries:** a
  key of at most four words of integers, plain enums, and `Bool`s
  (through nested objects, none with its own `==` or hash) is hashed
  again when the index grows rather than kept beside it, so a two-word
  key's entry is 24 bytes, not 32, and a probe compares the key where it
  compared the hash. On pup, Trig's peak memory is 3.1% lower on
  ts-pattern and 1.4% on zod3, its time unchanged; bench/hash's
  hits on two-word and three-word keys are 22% and 7% faster on pup,
  as fast as the hand-written Zig table they came from
  ([map-wide-keys.md](docs/history/records/2026-10/hash-race/map-wide-keys.md)).
- **`Map.ensure_by` checks its key**: the key `key(k)` makes must
  equal `k`, and one that differs panics, rather than leaving two equal
  keys in the Map.
- **The built-in Map and Set take zig-ordered's design**
  (std/prelude.rig, still safe Rig): the entries in one List in first-put
  order, with no optional for plain keys and values (16 bytes for a
  `Map[Int, Int]`); up to 16 entries a tag byte each inside the Map, and
  past that an index of 16-byte tag groups (15 tags and an overflow
  byte) beside 32-bit entry indexes, matched a group at once by
  `m.lanes()`, its group and lane indexes masked so they make no test.
  A take drops its key at once and marks the entry gone, so the order
  holds; the gone entries are compacted only when the List is full and
  a quarter gone, as the index grows, or when the last is taken, and a
  walk passes them by runs. Every member, the order, and printing are
  unchanged. On pup, Trig takes 6.0% fewer cycles on ts-pattern and
  4.4% fewer on zod3, with 0.2% and 1.4% more instructions, and peak
  memory 8.0% and 2.8% lower. A Map is 176 bytes, and holds 4,000,000
  Int keys in 32.8 bytes an entry on the Mac (51.0 before; zig-ordered
  37.1). A Map holds at most 4,294,967,295 entries.

- **Masked indexes are proven:** `s[e & m]`, where `m` is `s.len -% 1`
  (or `s.len - 1`) taken inside a guard `s.len > 0`, or any `Int` known
  not negative whose room below `s.len` is known, makes no bounds test,
  for any `e`, a negative one too; and a loop whose every write of `i`
  is `i = e & m` keeps `0 <= i < s.len` at every step, so a probe of
  slot `(home +% d) & mask` is tested nowhere
  (docs/internals/INTERNALS.md, "Proven checks").
- **Prefetch:** `xs.prefetch(i)` asks for element `i` of a List, an
  array, or a slice ahead of its read. It reads `xs` for the call and
  does nothing a program can see: an `i` out of range does nothing and
  never panics. It is one prefetch instruction, `prfm pldl1keep` on ARM
  and `prefetcht0` on x86, with no range test (`test/cli/prefetch.sh`),
  and nothing where a target has none. In bench/prefetch, lookups into
  a 256 MiB List that branch on what they read take 7.8 ns with it, 64
  lookups ahead, and 47 ns without it on Apple M5; 11.3 and 73 ns on
  pup.
- **A mask's true lanes:** `for k in m.lanes()` visits each true lane of
  a mask `Simd[Bool, n]`, lowest first, as an `Int`. `lanes()` gives the
  prelude's `Lanes`, an iterator, so `break`, `continue`, a resumed
  loop, and std.iter work on it. The compiler holds the lanes in the
  form the target reaches fastest: one bit a lane from `pmovmskb` on
  x86 and WASM, and on ARM the nibble mask of 16 lanes (`cmeq`, `shrn`,
  `fmov`) and the bytes of 8 (`cmeq`, `fmov`), with no reduction or
  constant load. Each lane is a count of trailing zeros, a clear of the
  lowest bit, and the branch back: four instructions on Apple M5 and
  x86-64-v3, five on Apple M1 and baseline x86-64
  (`test/cli/mask_lanes.sh`).
- **A view of a generic `as` binding views the optional:** in a generic
  body, `if o as x` and `while o as x` over a view of a `T?` (`o: ?T?`,
  `?h.item`, `?xs[0]`, `?@item`) bind `x` to the value inside where it
  stands, so `return ?x` from a function `from o` views the caller's
  value. It was a copy the body made, which the view outlived: an
  object's fields read back as garbage once the stack was reused.
- **The prelude:** the built-in Map and Set are written in
  `std/prelude.rig`, module `std.prelude`, which every program has with
  no `use`; error messages and profiles name it so. `use std.prelude` is
  rejected with the reason, and a program's own module named `prelude`
  stays its own.
- **Runs of lines for tasks, and counting by a viewed key:**
  `text.chunks(s, n)` cuts text into at most `n` runs of whole lines, to
  hand to `par.workers` a run at a time rather than a line at a time,
  and `(!m).ensure_by(k, key, v)` is `ensure` with the key viewed, its
  key made by `key` only when it is new: `(!m).ensure_by(word, |w| +w,
  0) += 1`. STD's `std.par` says why a task should take runs.
- **Removing from a List in one step:** `(!v).swap_remove(i)` hands
  over the element at `i` and moves the last element into its place,
  where `remove(i)` moves every element after `i`: on a List of 100,000
  elements, 4-5 ns against 63 microseconds to take the first. The order
  of what is left changes.
- **Hashing objects of integers:** an object whose parts are integers,
  plain enums and Bools hashes its words two at a time, one folded
  multiply a pair, as foldhash and abseil do, where it took two
  multiplies a word: Trig's two-word cache keys hash in one, its
  three-word instantiation keys in two
  (docs/history/records/2026-10/pair-hash/).
- **`$plain(T)` narrows a generic body (SPEC "Generic bodies"):**
  `$plain(T)` is whether `T` is plain data, known when the program
  compiles. Where it is an operand of a condition's `and` chain (an
  `if`, an `else if`, a `while`, or a statement's or arm's guard), the
  code that runs once it has held is checked with `T` known to copy and
  to hold no loan, and only the instances where `T` is plain compile
  it: `if $plain(K)` lets a generic body copy a `K` that every other
  instance never reaches. A generic that tests it takes each instance's
  answer as a compile-time Bool, and every generic that builds it from
  its own parameters passes the answer on, so `f[Int]` and `f[?Int]`
  are two Zig instances there; a program that tests no `$plain` emits
  the Zig it did. SPEC's copy rule says what the compiler already did:
  where a body copies a `T`, every instance must be plain data or a read
  view.
- **Generic calls' messages name what they mean:** a conflict between
  the type expected of a call's result and an argument names "the type
  expected of the result", not "argument 0" (`s: String = apply(3, |x|
  x + 1)`), and a numeric one converts the argument, not "argument 0";
  a bracketed generic call is named as written (`` `id[Int]` ``, not
  `` `expression` ``); and an argument whose type differs from a generic
  parameter's inside it names both whole types, as for any call
  ("expected `?fun(Int) -> Int!E`, got `fun(Int) -> Int`", not
  "expected `Int!E`, got `Int`"). A conflict inside one argument says
  where in it each type came from: `ap(h, 3)` of an `h: fun(Int) ->
  String` reads "`Int` (the parameter of argument 1) and `String` (the
  result of argument 1)", not "`String` (argument 1) and `Int`
  (argument 1)", and a numeric one no longer offers to convert the
  argument.
- **`os.exit(code)`:** ends the program now, from `main` or any task,
  with `code` as its status: what `print` and `warn` wrote is flushed,
  and no drop, `defer`, or leak check runs.
- **A Map's lookup and an insert into room are inlined** (Trig's PGO
  build 1.4-1.7% fewer instructions, about 1% faster; release 3.0-3.5%
  fewer; [records](docs/history/records/2026-10/map-inline/README.md)):
  `find` and `insert` are `inline` in Map and Set, so a probe keeps its
  state in its caller's registers and an insert copies no key into a
  call, and only making room (`grow`) is a call. The Map's spills and
  reloads in Trig fell from 412M to 47M instructions a run.
- **Reads cost Trig fewer instructions** (1.5% fewer on ts-pattern
  and zod3, 1.2-2.2% fewer cycles;
  [records](docs/history/records/2026-10/perf-stage/table-reads.md)):
  an inlined call's optional or fallible result is made a run-time
  value in place rather than passed through `rig.rt`, whose memory
  round trip stalled every `m.get(k) ?? x` (`rig.copiedOut` is inline
  too), and a signed index is tested against a List's or slice's length
  with one unsigned compare. A `rarely` function is `noinline`, out of
  line as SPEC says, no longer left to LLVM.
- **A signed index against a compile-time bound is one compare**
  (Trig PGO 0.5-0.7% fewer instructions, 1.5-1.7% with #706's yield check;
  [records](docs/history/records/2026-10/perf-stage/bounds-enum.md)):
  a `Table` read by an `Int`, `Slot[n].of(i)`, an array's element, and a
  vector's lane test `i` as unsigned against `n`, which a negative `i`
  always fails, where a sign test and a bound test made two.
- **A function's name given to `par.map` or `par.each` is checked
  against what they pass:** each element's view, or the value of a
  scalar's read view; a write view as itself. `par.map(?xs, f)` with
  `xs: List[Int]` and `fun f(s: ?String)`, and `par.each(!xs, show)`
  with `sub show(x: Int)`, were accepted and failed in Zig; the first is
  "`par.map` calls `f` with each element as `?Int`, and `f` takes
  `?String`".
- **A view lent through a write-view binding may outlive it:**
  `if !@slots[j] as s` / `return !s.value` in a method `-> (!Int)? from
  @` is accepted, as are the same through `s = !@a`, a `for s in !@xs`
  element, a call's result (`if (!@).find(j) as e`), and a `match !`
  payload (CORE sentence 7). Such a view carries the binding's own
  loans and a loan on the binding that ends with the binding's scope;
  each was "cannot return a view of `s`, which this function was not
  lent". What it views stays lent while it lives, and nothing in the
  binding's scope, its defers included, uses the binding while it
  does; a block's value through a binding of its own block keeps that
  binding from its defers (CORE §7, Defer). A view of a local
  (`s = !x`, then `!s.value`) is still the local's.


- **A field of an owned object moves like a name (CORE §5):** `<p.f`
  of a field that is neither optional nor copies, from an object a
  local or parameter owns, moves the field and leaves `p` partly moved.
  Its other fields stay usable, `p.f = x` makes a local's field usable
  again, and only the fields still held drop, at the scope's end and at
  every exit, each behind a drop flag of its own. Until every moved
  field is assigned again on every path, no use touches all of `p`
  except `p = x`. No field moves through a view, a handle, a box, an
  element, or an optional's value, nor out of a type on its path with a
  `drop` body. Owned bindings (`if <o as s`, `match <x`, `for x in <v`,
  `<@`) are names too. Nothing accepted before is rejected; the
  programs that moved a field out of an owned object, rejected before,
  now run.
- **An optional field of a binding whose fields cannot be assigned
  moves like a name (CORE §5):** `<p.tags` of a parameter, a capture, or a `=!`
  local moves the field and leaves `p` partly moved, where it was
  rejected as a take no one could write (``cannot take parameter `p` ``).
  A local that can be assigned, and a write view, keep the take, which
  leaves `none`. Only programs rejected before are accepted.
- **A public generic states the `Print` of what its callees print:**
  `pub sub show[T](x: ?T)` passing `x` to a private generic that prints
  it is rejected, `` `pub sub show[T]` prints a `T`: write `[T:
  Print]` ``, as printing `x` in `show` is; through any number of
  calls, from a method of a `pub` generic type, through an instance of
  a generic type whose method prints it (`Box(v: x).show()`), and for
  a bounded `T` of any generic. Every instance without `Print` was already rejected
  at the callee's instance, under the callee's name, or printed as
  `print` writes it. Newly rejected: such a `pub` generic without
  `Print`, and a bounded `T` without it passed to a generic that
  prints it.
- **A generic body printing `T`s in a slice or a List checks each
  instance:** `print(xs)` of a `[]T` or a `List[T]` took `T = []U8` and
  wrote its bytes as text, `["Hi"]`; the instance is now rejected, as
  `print` of a `[][]U8` is. Newly rejected: such an instance, and a
  `pub` generic printing a `[]T` without `[T: Print]`.

- **A value of an associated type views its base per instance:** a
  value of `S.Item` that a call on `s` gives (an item of `next`, or of
  `fun one(!@) -> Item from @`) keeps `s` lent only at an instance whose
  `Item` may view memory `s` owns, as Stage 3 checks a call through a
  bound at each instance. A body that holds one past a change of its
  base (a write, a move, a drop), itself or through the generic bodies
  it calls, is rejected at each such instance, with a note at the
  change; a body that holds none, as `iter.count` does, takes every
  iterator. Such an
  instance was rejected whatever the body did, so `iter.count` of an
  iterator whose items view its own memory was refused.

- **A scope's defers run after its value, which they may not touch:**
  the checker re-checks each `defer` at every exit with the loans of
  the value the exit leaves with in force (a block's or an arm's value,
  a `return` or `break` value, a function's last value), so `if c` /
  `defer !@xs.clear()` / `!@xs[0]` is "use of `@xs` while a write loan
  is live", where the caller wrote into a freed element; an `errdefer`
  runs only where that value is an error, and is checked without it.
  `return s`, `return s, n`, and a last value `s` of a write view move
  `s`, as `<s` does (CORE sentence 1), so a later `defer s = ...`, a
  deferred `|!s|` closure, or a task lent `!s` and waited for at the
  scope's end is rejected. The reference checker now holds a task's
  loans until the task's drop waits for it, and keeps a write view
  handed where a `(!T)?` goes a view.

- **A Map and a Set print their entries:** `print(m)` writes
  `{"a": 1, "b": 2}` and `print(s)` writes `{1, 2}`, `{}` when empty,
  the entries in the order their keys were first put in, each key and
  value as an element of a List prints. They wrote their hidden fields,
  `Map(len: 1, es: [...], hs: [...], table: ...)`. `String(m)` and
  `!t.add(m)` write the same text.
- **A release build of objects nested by value is linear:** the
  runtime's `==`, `.hash()`, and `+` reach a field that nests objects
  more than eight deep through a call of its own, so a chain of 400
  objects nested by value builds in 4.9 s, not 211 s, and 1000 in 11 s,
  where it ran past 20 minutes. Shallower objects compile as before.
- **A function value held in an object holds nothing:** the checker
  counted a `fun` field as a view that may point anywhere, so a call
  through a `?sub` lent `!@` and `!n` kept `n` lent past it when `@`
  held a `fun` field. A function value is a named function's address
  (CORE §7); a function type walked itself (a closure binding's), a
  lent `?fun`, and an owned closure still count as anything.
- **API objects' messages give the fix:** `?{Shape}?` and `?{Shape}!E`
  read as a view of a suffixed `{Shape}` and say to write `(?{Shape})?`
  or `(?{Shape})!E`; `[T: {Shape}]` says a bound names the API,
  `[T: Shape]`, and nothing more (it spoke of a value parameter); `+s`
  of a `?{Shape}` says a view copies, and of a `!{Shape}` to lend it on
  with `?s`. An API object's braces join lines as brackets do.
- **Instances reached through an API are named as written:** an
  addition's method shows its type's arguments and its own,
  `Map[Int, Int].look[Float]` (it was `Map.look[Int, Int, Float]`), and
  a public generic that nests itself through a call through an API on
  a type of its module is reported where it is declared, as one that
  calls itself is, though no module calls it (it was reported only at
  an instance another module made).
- **A module's members are its own declarations:** `lib.List[Int]`,
  `lib.print`, or `lib.Cell[Int]`, a built-in named through a module,
  is "no member `List` in module `lib`" as an expression and as a type.
  As an expression it reached the built-in, and as a type it was "not
  public". One lookup, `SemContext.moduleMember`, serves every pass.
- **A method makes the instances it names where it is reached:** a
  generic type's method that names a deeper instance of its type
  (`$name(Wrap[T?])` in `Wrap[T]`'s method) makes it only where the
  program reaches the method, and that instance's methods only where
  they are reached, so it is no longer "ever deeper instances". A
  method that reaches itself on ever deeper instances still is, at the
  call, or where it is declared for a `pub` type. An instance a method
  the program never reaches would make is no longer checked against the
  body's requirements (`Holder[*B]`'s uncalled method making an
  `Opt[*B]`), as Zig compiles no such method.
- **A code lent where a view of a union with fields goes:** an error of
  a set without fields, `B.y` or a binding of one, is lent where a `?L`
  of `error L = A | B` with fields goes, or a `?error`, as the error
  value of the code, a constant (`code(B.y)` was "bind it first"). An
  error with fields where a `?error` goes is told to bind it first, as
  where a `?L` goes, moving a place that moves (`k: error = <a`); it was
  told to write `?a`, which is rejected too.
- **API objects crossing tasks (Stage 5, the proof):** formal/ proves,
  in Lean, that erasing a type keeps what a crossing check reads: an
  object holds what its hidden value holds, so a value that may not
  cross before erasure may not cross after (`crosses_erase`); an object
  whose bound was checked at erasure holds nothing that stays on one
  thread and no task, so a free task may take it (`erase_sends`); one
  naming no bound goes to no task (`bare_no_spawn`); and after a spawn
  of an erased value, two tasks holding one value that stays on one
  thread are still pinned to one core (`erase_confined`).

- **API objects (Stage 4, the proof):** formal/ proves, in Lean, that
  erasing a type keeps its loans: the checker's rule for an access to an
  owner reads only each name's loans, so an object's type, rebuilt from
  its kind and loans alone, gets the verdicts the erased type got
  (`allows_erase`); an object's value carries a live loan on each owner
  its type names (`erase_live`); and a λRig program with API objects,
  reached only by calls checked against their APIs' clauses, runs
  without a fault (`erased_runs`), while a program without erasure
  checks as before (`checkE_lift`).

- **Shared and weak API objects (APIs Stage 5, phase 2):** `*{Shape}`
  is a counted handle to a value of some type that provides `Shape`, and
  `~{Shape}` its weak handle. A `*Square` moves into a `*{Shape}` and
  keeps its allocation (`<h`, `+h`, and `*Square(...)` or `*<sq`
  written where one goes), and a frozen value's handle only into a
  `*{Shape + Syncs}`, which counts atomically, goes to any task, names
  no `Owned`, and has no weak handle; neither becomes the other, and a
  handle is erased only as it moves or counts, never through a view.
  It only reads: a call through it reaches `?@` methods, `?s` lends the
  `?{Shape}` it holds, `+s` adds a count, and the last count's drop
  drops the value through the table, a long chain without deep
  recursion. `~s` makes a `~{Shape}`, `*w` gives a `*{Shape}?`, and both
  carry the loans of what they hold until the last count is dropped. A
  frozen value may hold `*{A + Syncs}` handles, so a
  `*Frozen[List[*{Plugin + Syncs}]]` is a registry many tasks read. An
  API's table gains three entries, the weak count's, and its function
  a holding, `__rig_table_Shape_of(T, W, .counted)`. A Cell of an API
  object is rejected for good, no longer as not built. The reference
  checker gains the kinds of both forms.
- **One reason for an API object that may hold a loan:** an owned
  closure's capture, a channel's values, a generic body's Cell, Signal,
  or owned closure, and an `Owned` bound name the object and its fix ("a
  `*{Shape}` may hold one: write `*{Shape + Owned}`"), where a channel
  called a `*{Shape}` one that "may hold a view" and an instance said
  "a view keeps what it views lent" of a `^{Shape}`.
- **`I.Item` of any iterator:** a generic body bounded by `Iter` that
  names `I.Item` compiles for an iterator whose item's optional holds
  its none in the item (an object with a `Bool` or enum field, or one
  that names its none); it failed in Zig.
- **A fallible result erases its value:** a function returning
  `(^{Shape})!`, `(*{Shape})!`, or `(?{Shape})!` erases its last
  expression, `return`'s operand, and `f()!` into the object, as a
  binding of the object's type does (`^Square(...)` was "type mismatch:
  expected `^{Shape}!`"), by the erasure's own rules.
- **One rule for a value hidden from a task's waiting:** an erasure to
  an API object, a value given out of `task.isolate`, and an owned
  closure's capture check that it holds no task by one function, for
  its known type and for each instance's `T`. A generic owned closure
  over a `T` made with a `Task[Int]` is refused by the task rule
  ("captures a value that holds a `T` in an owned closure, which would
  hide a task"), no longer by the loan rule.
- **Frozen values:** `Frozen[T]` is no type argument, inferred as well
  as written, so a `*Frozen[T]` given where a generic `*T` goes is
  rejected toward a `T` (it failed in Zig); and the last handle of a
  long chain of frozen values, or of `*{A + Syncs}` objects, drops it
  through the queue a `*T`'s chain takes, not by deep recursion.
- **API objects cross tasks by a bound in their braces (APIs Stage 5,
  phase 1):** `Sends` and `Syncs` may stand in an object's braces where
  its form uses them (`^{Job + Sends}`, `^{Shape + Syncs}`,
  `?{Shape + Syncs}`, `!{Shape + Sends}`) and in its API's
  (`api Job: Sends + Owned`). Each is checked on the hidden value where
  its type is erased, a type parameter's by its bounds, and the error
  names the part that keeps it from crossing; then each form crosses by
  its row of SPEC §18's table, to tasks, channels, actors, and `par`,
  and a call through an object is a task when its self may go. A bound
  a form cannot use is rejected toward the one it can
  (`?{Shape + Sends}` toward `Syncs`), and a box's views name only the
  bound their form uses. An object without the bound a task needs goes
  to none, a local one included, naming the bound to write. An API's
  `Owned` now counts as the braces' does, and every built-in API an
  object's API builds on is checked at the erasure, so a generic type
  that provides the API only where its arguments do is erased only
  there (`^Wrap[Tok](...)` into `^{Shape}` of an `api Shape: Clone` was
  accepted and cloned a unique value). An owned closure captures no task
  or set of tasks: `*|<t| 7` was accepted, and let a task leave
  `task.isolate` or hide in an API object. The reference checker gains
  rule T1, an object given to a task without its bound. Of what this
  rejects, v0.2.9 accepted an owned closure that captures a task,
  `f: *fun() -> Int = *|<t| 7`; wait for the task first and capture its
  value. A generic body's erasure of a value holding a type parameter
  its bounds do not decide, `^Wrap[U](...)`, is checked at each instance
  for every bound the object names: it had passed them all, so a box of
  `Owned` could outlive what it viewed and a box of `Sends` could carry
  a `*Int` to another core. `par.map` over read views of objects no
  longer fails in Zig. A value erased where a task or an actor takes an
  object crosses by that object's braces, not its known type:
  `work(^Sum(...))&` to a `^{Job}` is rejected toward `^{Job + Sends}`.
- **`rig check` and `rig lsp` on a file of a directory module:** the
  file is checked as its module, whose imports are beside the
  directory, so opening `src/ast/ast.rig` in an editor no longer reports
  its `use core` as a module it cannot read. A directory is a program's,
  and each file its own root, when one of its files declares `sub main`
  or `use`s a module found in it and not beside it (SPEC §1).
- **Docs: shared and crossing API objects in the Core (APIs Stage 5,
  phase 0):** CORE §1, §4, and sentences 8 and 9 state, as planned, that
  `*{Shape}` counts a value of hidden type and `~{Shape}` is its weak
  handle, that a frozen value's handle erases only to
  `*{Shape + Syncs}`, and that an API object crosses tasks only by a
  bound it names, with five `rig pending` examples; SPEC §18's crossing
  table gains the objects' rows, marked planned. docs/design/apis.md's
  Stage 5 and its build plan follow the approved text. Nothing is built
  yet.
- **A generic instance gives no task what goes to none:** a generic
  body that gives or lends a task a `T`, or a value holding one (a
  task's arguments, self, and result, an actor's value, arguments, and
  result, `par`'s elements, values, and captures), is checked at each
  instance with the crossing walk that checks a known type, at the call
  that makes the instance, with a note at the task. An instance whose
  `T` holds an owned closure, an API object, or a set of tasks is
  rejected, and so is one whose `T` stays on one thread (`*Node`) where
  the body's task crosses, which ran on another core. A method of a
  generic type, or an API's default, is checked at each type that
  reaches it (a call, a call through a bound, or erasure to an object
  of its API); one never reached is not compiled and is not checked. A
  generic body that erases a `T` to an API object, or gives one out of
  `task.isolate`, is checked at each instance for a task the `T` holds.
  A bounded or `pub` generic whose calls give its `T` to a task that
  crosses states `Sends` or `Syncs`. Whether an API object crosses
  (`Sends`, `Syncs`) is decided by the same walk. v0.2.9 accepted the
  forms this rejects, each of which let a value reach a task its known
  type could not: `spawn(<cb)` of `fun spawn[T](x: T)` whose body runs
  `use(<x)&`, with `cb: *fun() -> Int` or `n: *Node`; `par.map(xs, f)`
  over a `?List[T]` of owned closures; `*Actor(Box[T](x: <x))` with `T`
  an owned closure; a `fun go[T](f: fun() -> T)` whose task `call(f)&`
  gives back an owned closure; `h.go()`, an API default whose task
  takes `?@`, on a type holding an owned closure;
  `task.isolate(|<x| keep(<x))` with `T = Task[Int]`; and a `pub fun
  outer[U]` that passes a `U` to a generic whose task crosses, which
  now writes `[U: Sends]` or `[U: Syncs]`.
- **Boxes of API objects (APIs Stage 4, phase 3):** a `^T` moves into a
  `^{Shape}` and keeps its allocation, `<c` or a `^Square(...)` written
  where one goes, and a `^T?` into a `^{Shape}?`. A box lends its
  `?{Shape}` and `!{Shape}`, is replaced by assignment, and drops its
  value through its table and the drop queue, so `next: ^{Node}?` chains
  of any length drop without deep recursion; a List of boxes grows,
  sorts by a key, and clears. `<b.close()` ends the box, which drops its
  value once even when the method fails. A box clones through its table
  where its braces or API name `Clone`, and prints where they name
  `Print`. Its loans last to its drop; with `Owned` in its braces,
  checked on the erased type, it holds none, and an owned closure takes
  it. An object has no default value (`Table[^{Shape + Owned}?, n]`), an
  error's field holds none, and a Cell of one is Stage 5's. An object
  goes to no task, a local one included, since its hidden value may hold
  an owned closure or a set of tasks: this narrows Stage 4's default 14,
  which made a task over a call through one local (the owner's decision,
  2026-10-23). A call through a generic type at
  arguments that hold an object, `Ph[^{Shape}].mk()`, is built too. No
  value that holds a task or a set of tasks is erased, and a generic
  body prints an object only where its braces or API name `Print`. A
  channel and an actor print as `<chan>` and `<actor>`, where printing
  one failed in Zig.
- **API objects lend and call through a table (APIs Stage 4, phase
  2):** a value lends `?{Shape}` and `!{Shape}` by the lend table's last
  row, through boxes, handles, frozen handles, and optionals, unwritten
  where it lasts only for a call (`area_of(sq)`), and `s.area()` or
  `Shape.area(s)` calls the hidden type's method, an addition's, or a
  default through the API's table, `__rig_table_Shape_of(T, W)`, which
  Zig makes once per API and type. A call is checked by the API's
  declaration, passes on only its `from` and `keeps`, and fails with
  its set, a set's fields through the slot. An object carries every loan
  of its value to its last use; through a `!{Shape}` nothing assigns,
  swaps, or copies the value; an object is never cloned, compared, or
  hashed, and prints only by the braces' or API's `Print`. An object of
  a read view of plain data, or of a type parameter's value, views a
  copy local to its block, and is rejected where it would leave it. A
  call through an object costs what a call through a `?fun` does
  (bench/apis).
- **API object types (APIs Stage 4, phase 1):** a type may name an API
  in braces behind a view or a box, `?{Shape}`, `!{Shape}`,
  `^{Shape}`, with `Owned`, `Print`, and `Clone` beside it, `^{Shape +
  Owned + Print}`. The compiler checks what the braces name (one API
  of a program's own; a type, a type parameter, a second API, `Copy`,
  `Eq`, `Hash`, `Ord`, and the number APIs each rejected with why;
  crossing tasks and `*{Shape}` Stage 5's), rejects a bare `{Shape}`
  anywhere a value's type or a type argument goes, inferred too, and
  decides the bounds an object meets and the methods a call through
  one reaches. A type alias names such a type and `$name` spells it; a
  value holding an object, an erasure, a call through one, and a call
  through a type that holds one (`Ph[S].mk()`) are rejected as not
  built yet, and no frozen value holds one. A brace in an expression
  says to name the type with an alias, and one anywhere else keeps its
  message, "Rig has no braces".
- **Docs: API objects in the Core (APIs Stage 4, phase 0):** CORE §1
  and §4 state, as planned, that an API object (`?{Shape}`, `!{Shape}`,
  `^{Shape}`) hides its value's type, never its loans, with two
  `rig pending` examples; docs/design/apis.md's Stage 4 and its build
  plan follow the approved text. Nothing is built yet.
- **Public generics state their bounds (APIs Stage 3, the last step):**
  a `pub` function, a `pub` type, and a `pub` method of a `pub` type
  name, by bounds, everything their bodies do with each type parameter
  that an API names: a copy, `==`, ordering, `.hash()`, printing,
  arithmetic, keeping a `T` where no loan is tracked, crossing to other
  tasks, a call of another generic or a type bounded so, and a method
  call, which goes through an API. The error is at the parameter, with
  the bounds to write: `` `pub fun sum[T]` adds `T`s: write `[T: Num]`
  ``. A bound a signature's types already require counts as stated:
  `K` named in `Map[K, V]`, or in a type whose field names one, is
  `K: Hash` without saying it, whether or not it has bounds of its own,
  so `[K: Print]` no longer restates `Hash`. A private generic keeps
  per-instance checking, and what no API names (a literal's fit, a
  table's default, freezing) is checked at each instance everywhere. A
  bound asked of an argument made of other types in a signature
  (`Chain[Pair[T, U]]` under `Chain[T: Copy]`) is checked once every
  type's contents are known, where it crashed the compiler. Printing a
  view of a `T` (`print(x)`, `x: ?T`) needs `Print`, as printing a `T`
  does. *Rejected now:* a `pub` generic whose body does with a type
  parameter what its bounds do not name, which earlier releases checked
  at each instance. `tools/state-bounds.py PROGRAM.rig` writes every
  such bound from the compiler's own fixes (`--dry-run` prints the
  diff); std and examples/ need none, and Trig's src/ needs 51 bounds
  on 49 declarations.

- **A method's view names the path of self it views:** `-> ?String from
  @text` (also `from @a.b`, and beside parameters, `from @map, k`) lets
  the result carry the loans self holds and a loan on that path alone,
  so the caller may write self's other fields while it lives (Core
  sentence 7). A path that is a field declared as a read view (`?T`,
  `[]T`, `?String`) puts no loan on self, so self may be lent again,
  even to write: a Map's and a Set's iterators say `from @map` and
  `from @set`, so their items outlive the step of the loop, a function
  lent an iterator holds two items at once, and `iter.count` and any
  body bounded by `Iter` take them. The body is checked against the
  path. A path in `keeps`, in an API, through a read view, beside `@`,
  or of more than 8 fields is rejected with the fix. A task through
  such a method (`(!it).next()&`) keeps all of self lent until it is
  waited for.

- **A slot compares with a literal below its count:** `s == 0`,
  `0 == s`, `s != 3`, and `s < 3` for a `Slot[n]` were "cannot compare",
  though the literal is a `Slot[n]` at an assignment, an argument, and a
  return; beside a slot in a comparison it is one too, checked to fit
  below `n`.

- **A narrowed error is a view of the caught one:** a `g: E =>` arm
  under `match e` bound nothing the ownership checker saw, so `<g`,
  `y = g`, and a `?g` kept past the handler were accepted and read
  freed memory. The arm binds `g` as a payload is bound: a view of `e`
  under `match e`, the error itself under `match <e`. The reference
  checker (`bin/rig-oracle`) found it, now that it models CORE's "A
  failure moves its error": the hidden `E?` a fallible call's statement
  holds, which `!` returns, `catch |e|` moves into the handler's own
  binding, and a nameless catch drops, and the `g: E =>` arm, on which
  it abstained.

- **A generic body hands its caller no view it never declared:** a body
  that called a `keeps` method on a `T` it held by value, then moved the
  value into its caller's List, let the caller drop what the view read
  and read freed memory. Such an instance is refused at the call that
  makes it, as the call through a bound already was.

- **Errors compared with a member:** an `L?` of a union with fields
  tested with a member of a set without fields (`o == .y`) failed in
  Zig; it tests the member. A member with fields written as a shorthand
  beside an error (`l == .x(n: 3)`) failed in Zig or with an internal
  error; it is told to name the set, `A.x(n: 3)`, and beside an
  optional, to unwrap it first. SPEC says that a comparison of made
  `T`s in a generic body needs `Copy`, or a binding of each. The HTTP
  server test's descriptor check waits up to 2 s for the server to
  accept again.

- **A wait fails with the set its work declares:** `task.all`,
  `par.map`, `par.each`, `task.isolate`, and `task.supervise` failed with
  any error even where what they wait for declares a set, so a function
  declaring that set could not pass their failure on with `!`. Each now
  fails with that set when it holds `task.Stop` (for `task.all`, the one
  of its tasks' sets that holds the others), as a set of tasks does.

- **A generic body takes a `T`'s failure as the value's fallible:** a
  call on a `T` caught in a `-> Int!` body was taken as an `Int!!`, which
  the message showed; it is an `Int!`. A body declaring a set of its own
  that passes such a failure on with `!` is told that a call on a `T` is
  taken to fail with any error.

- **A frozen value's handles order by what they reach,** as they compare
  and hash: `*Frozen[T]` provides `Ord` when `T` does, so `<`, a `T: Ord`
  bound, and `sort` take it.

- **A variant written with an empty payload, `a()`, is bare:** an enum
  of `a()` and `b` compared with `==` but was refused `<` and `Int(x)` as
  having payloads. One classifier now says an enum is plain
  (`sema.isPlainEnum`), and the values `Int(x)`, ordering, and
  `$variants` read go through it.

- **An API object prints as the value it hides:** `print(b)` of a
  `^{Shape + Print}`, `?{Shape + Print}`, or `*{Shape + Print}` hiding
  a String writes its text as is, as `print` of the String does, and
  quotes it only inside a List or a field; the table's print entry
  takes `print`'s `top` flag, as a box passes it on.
- **A generic `?T` of an error with fields:** `show(a)` for a
  `sub show[T](x: ?T)` and `a` of an error set with a member with
  fields, or `A?` of one, checked and then failed in Zig: sema lent it
  as a copy, and the runtime's `ReadView`, which a generic body's
  parameter is, held its `rig.ErrorValue` by address. Sema now lends
  every error that is a `rig.ErrorValue` by address
  (`sema.isErrorValueForm`, the one test emit asks too), the rule the
  runtime applies.

- **`.len` of a List behind a shared handle is an `Int`:** `0..f.len`,
  `n = f.len`, and `f.is_empty()` of a `*Frozen[List[T]]` or a
  `*List[T]` passed the check and then failed in Zig. One classifier
  (`hasLenReached`) now says a length is read through handles and
  boxes alike.

- **`[T: Clone]` clones:** `+x` of a `T`, a `?T`, or a `T?` in a
  generic body asked for `Copy` ("`T` is bounded by `Clone`, which does
  not give a value that copies"), though `Clone` is the bound that
  gives `+x`; a `|+x|` capture too. It now clones as each instance
  does (`rig.cloneAs`), a body without bounds is checked at each
  instance (`Requirement.clones`), and an instance that does not
  clone, a type with a `drop` body or a unique one, is rejected there.
- **`if ?o as v` of a `?T?` in a generic body views the `T`:** under
  any bound, `if ?o as v` and `while ?o as v` asked for `Copy`; the `T`
  is now read where it stands, as a `for` reads an element of a
  `?List[T]`, the optional stays lent while `v` lives, and only taking
  `v` out needs a `T` that copies at each instance.
- **A loop over a slice of a `T` reads its elements in place:** in a
  generic body, `for s in xs` and `for s in ?xs` of a `[]T` (or an
  array of `T`) asked for `Copy` under any bound, where a loop over a
  `?List[T]` did not; both now read each element where it stands, and
  only taking one out needs a `T` that copies at each instance.
- **Inference sees through a box or a handle lent as a view:**
  `first(?bx)` of a `^List[P]` for `first[T](xs: ?List[T])` was a type
  mismatch, and `f(?fz)` of a `*Frozen[Square]` for `f[T: Shape](s: ?T)`
  bound `T` to the handle, which provides no `Shape`; each now binds the
  value the lend reaches, as `first[P](?bx)` and `f[Square](?fz)` did.
- **A box or a handle of an object that holds no loan views nothing:**
  an API's method giving `^{Job + Owned}` or `*{Job + Syncs}` had to say
  `from @`, as if the object could view what it was passed; the view
  targets of a type now stop at a box or a handle whose braces say it
  holds no loan (`sema.heldObjectOwned`, which `objectUnowned` asks
  too), and such a result takes no `from`.

- **Small fixes the Learn Rig journeys found:** a local a closure uses
  without capturing it is reported once for each closure, at its first
  use; `List(...)` of objects, and an array lent where a `?List[T]`
  goes, name the form that works (an empty List pushed into, or a `[]T`
  parameter); `RIG_LEAK_TRACE=1 rig test` shows each leaked
  allocation's trace after the summary, and the leak note names the
  command that was run; what `print` buffers is written out before the
  program goes idle waiting on I/O or time, so a server piped to another
  program shows its first line while it waits; and `rig check
  --facts=proofs` names the file of each line in a directory module.

- **`rig check --tasks` lists each local task,** each task that stays
  on its maker's thread, in source order, module by module: its file,
  line, and column, the call that makes it, the part that pins it, and
  the type in that part that cannot go to another core. A directory
  module's lines name their file; a program with no local task prints
  nothing.

- **An ordering in a generic body reads its operands as `==` does:** a
  made `T` beside `<`, `<=`, `>`, or `>=` is a temporary of `T`, which an
  instance that owns a resource cannot leave, and which a body bounded by
  `Ord` alone cannot leave either (`[K: Copy + Ord]`, or bind it to a
  name). Before, `f() < f()` with `K = String` leaked both Strings, and
  so did `sort.sort_by_key` with an owned key; it now binds each key to a
  name and drops it. A generic body that ordered made values of a type
  parameter without `Copy` is now rejected.

- **An error code widens to a union that holds it where a view of the
  union goes:** for sets without fields, `m.get(B.y)` for a
  `Map[L, Int]` of `error L = A | B`, and `take(B.y)` for a `?L`
  parameter, were rejected with a hint, `?B.y`, that led to another
  error, and `o == A.x` for an `L?` was "cannot compare". Each now takes
  the member as a value of `L`. Where the union has fields, the error
  says to bind it as the union first. Fixed with it: an `L?` of a union
  with fields compared with one of its members (`o == .w`) failed in
  Zig.

- **Three programs `rig check` accepted that Zig rejected, and a message
  that blamed recursion on a chain.** A vector's and a number's built-in
  methods (`with`, `select`, `bits`, `lookup`, `lag`, `not`,
  `count_ones`, `to_bits`, ...) read their `self` through a call's
  write view (`vs(!v, 0).with(0, 7)`), as an operator's operand is
  read. The runtime's walk over a type's parts (`rig.needsDrop`) takes
  the budget an emitted function does, so an object of many fields, or
  a chain of objects, kept in a `List` compiles. A type nests at most
  1000 levels by value (an object, enum, optional, array, or vector each
  a level), past which Zig's compiler runs out of stack; a deeper one is
  rejected once, at the first type past it. A clone, an error's fields,
  and the drop-body check follow a type to any depth, not only 32
  types down. A chain of distinct generic functions whose type arguments
  nest more than 24 deep is reported as that, not as a function calling
  itself. *Rejected now:* a type nesting more than 1000 levels by value,
  which Zig could not compile past about 1250.

- **What a function value is where a call runs it** is decided once
  (`Checker.fnArg`): a closure written in the call, a function's name, a
  closure binding, a closure's view or an owned closure, or none. Fixed
  with it: `http.serve` took a closure's view or binding whose captures it
  could not check, so a closure lending a local to write ran on every
  connection's task at once; it now refuses one, as `par.map` does.
  `task.isolate` and `task.supervise` refuse a closure written in the call
  that captures a closure or a write view, which could write outside
  them and leave the change half made after a panic. Every arm of
  `task.select` takes a closure's view, the first as well as the rest.

- **A lend of a branch is decided where it is reported:** inference checks
  a generic call's arguments quietly first, and a lend of a branch that
  was refused there (`look(?(a if c else b))`, `T` inferred, or the same
  inside a closure given to a generic) kept the verdict without its error,
  so the program was accepted and Zig failed. The verdict is now kept
  only from a check that reports. Two siblings are fixed with it: a kept
  view in a closure given to a generic lost its error the same way, and
  the trial of whether `<t[i]` could take a table's optional element
  recorded the slot as written, so a read through `?Table` failed in Zig.
  Debug and self-check builds also refuse to accept a module that types
  an expression `invalid` with no error.

- **APIs of a program's own (Stage 3, declarations and conformance):**
  `api Shape` declares the methods a type provides, required or with a
  default body, and may build on other APIs and on the built-in ones
  (`api Job: Moves`). A type provides one on its header, `obj Square:
  Shape + Print`, and `add Int: Shape` or `add Wrap[T: Shape]: Shape`
  gives one to a built-in type, another module's type, or a type under a
  bound. Each method meets its API exactly, but for a narrower `from`
  and `keeps`, and compile-time parameters match in kind, type, and
  bounds; a type provides an API once in the program, in its module or
  the API's, the APIs an addition's API builds on included; an addition
  names no member its type has, a String's `push` included; and a bound
  by an API, `[T: Shape]`, holds at each instance. `api` and `add` are keywords only at the start of a
  module-level declaration, before the name it declares or the type it
  names, so `user.api`, `!set.add(x)`, and a binding named `add` stay
  names; `trait` and `impl` say to write `api` and `add`. A type, an
  API, or an alias named `Int`, `Float`, `Bool`, or a sized number is
  rejected, as one named `String` is: an `obj Int` was accepted and
  never reached, since the name named the built-in type.

- **APIs of a program's own (Stage 3, calls through a bound):** a call
  on a bounded `T`, `x.area()`, is typed from the API's declaration: its
  self, parameters, compile-time parameters, and result with its failure,
  so `x.size()!` passes the API's set into a frame whose set holds it,
  `catch |e|` gives `e` that set, and a set with fields passes them
  through the slot; ownership reads the API's `from` and `keeps`, which
  every implementation is within. A call through a bound may be a task
  and may stand in a closure. `Shape.area(c)` calls a method through the
  API by name, and `c.area()` on a type with no `area` of its own
  reaches the default or addition of the one API the module sees that
  gives it one; two such APIs make the call name one. A call on a `T`
  with no bound that would reach a default or an addition says to write
  the bound. Each conformance has a witness, `__rig_impl_Shape_Square`,
  beside it, naming the type's methods, an addition's, and the defaults
  it takes; each bound adds one compile-time parameter, its witness,
  after the type it bounds, a generic type's included, so `Bag[Square]`
  stays one Zig type. Defaults' bodies and additions' methods are
  checked and lowered: a default as a method generic over `Self`. Every
  method call records how it dispatches, `direct` or `static`, and `rig
  check --facts=sema` prints it. A call through a bound that would store
  a view of a local in a value of a type parameter's type is rejected. A
  type parameter with no bound meets no bound by an API (`Bag[U]` or
  `total(x)` in a body whose `U` has none), which phase 1 left to each
  instance: the error gives the bound to write.

- **APIs of a program's own (Stage 3, method bounds and additions):** a
  method declared outside its type's body may bound the type's
  parameters, `fun Wrap[T: Print].show(?@)`: its signature and body have
  the type's bounds and these, a call's type argument provides them, and
  it takes a witness, after self, for each API of a program's own they
  name. A bound the type already gives, and `Copy`, `Clone`, `Owned`,
  `Moves`, or `Shares` (or an API built on them), are rejected toward the
  type's brackets; such a method meets no API on the type's header, gives
  no own meaning, and is no loop's `next`, and a call on a `T` with no
  bound, or on a `Wrap[U]` whose `U` has none, reaches it with an error.
  `add` names a type's value parameters as its type parameters, `add
  Slot[n]: Shape` and `add Table[T, n]: Shape`, whose witnesses are
  functions of `n`; every `Slot[n]` is one type constructor for
  coherence.

- **APIs of a program's own (Stage 3, associated types and `Iter`):**
  `type Item` in an API names a type each provider chooses, by what its
  methods give where the API's required methods name it; a bounded body
  reads it `S.Item` and bounds it by built-in APIs as an entry of its
  own, `[S: Source, S.Item: Ord]`, checked at each instance with what it
  does that no API names. A witness carries each associated type (`pub
  const Item = i64;`). `Iter` is the built-in API a `for` loop walks: a
  type with `next(!@) -> T?` provides it, by the loop's own rule, with
  `Item` its `T`; `[I: Iter]` loops over and calls `next` on an `I`, an
  API may build on it, and no header names it. std.iter gives `count`
  and `sum` over any iterator; every std iterator is an `Iter` whose item
  is what the loop gives. A body that holds an item past a change of
  its iterator is rejected at each instance whose items may view memory
  the iterator owns.

- **APIs of a program's own (Stage 3, the proof):** formal/ proves, in
  Lean, that a call checked against an API's `from` and `keeps` is
  sound for any implementation whose clauses are within them, by
  position: over the machine's loans, every view such an implementation
  leaves behind stays live through whatever the caller's record allows
  (`within_live`); and a λRig program whose calls, taking read views,
  are checked against their APIs' clauses alone runs without a fault
  for any such implementations (`api_calls_run`).

- **Generic sets:** a function may take the set it fails with as a type
  parameter, `fun total[E](f: ?fun(?String) -> Int!E) -> Int!E`. A call
  binds it from its callbacks' sets (`error` for a `T!` callback), and
  fails with that set; in the body `!` passes only `E`, and `catch |e|`
  gives an `e: E` that `return e` fails with again. A callable view of a
  fallible function always takes the hidden slot, which has no bits in a
  program whose sets have none. A fallible arm of `task.select` hands its
  failure's fields to whoever catches it.

- **`std.json`'s `JsonError`:** `(!doc).load(?src)` parses as `parse`
  does and fails with `JsonError.bad(kind:, at:)`, the first error and
  its byte offset, where `parse` answers `false`. `parse`, a `Bool`,
  stays as it was.

- **One representation for `error`:** an `error` is always an error value
  that may carry fields, and every `T!` function takes the hidden slot,
  which has no bits in a program whose sets have none. A program's code
  no longer changes because another module declares a member with
  fields. Fixed with it: a value of a set without fields put where
  `error`, or a set with fields, goes; a temporary `error` that leaked;
  the slot passed to a built-in type's method or a runtime call (a
  `Chan`, `http.serve`, `io.copy`); function-value types without the
  slot; a `catch` read in place; `reduce` with a fallible function.

- **A task set of a declared set:** `Tasks[Int!L]()` and `Task[T!E]`
  parse in an expression, as in a type.

- **An array element that fails no longer leaks:** an array literal
  whose element leaves (`!`, `?`, or a `catch` that returns, breaks, or
  continues) drops the elements made before it, as a call's arguments,
  an object's fields, and the results of `return a, b` already did.

- **Clones across modules:** `+x` deep-copies an object or enum declared
  in another module, part by part, as it does one of its own, and so a
  `Map` or `Set` (built in, written in Rig) whose keys and values clone.
  A type with a `drop` body, a unique type, and a `Signal` still have no
  clone.

- **Errors that carry fields:** an error set's member may declare fields,
  `bad(pos: Int, msg: String)`, which hold no loan or handle and clone.
  A failure moves its error up through `!` to the `catch` that owns it;
  `match` names a member with its set, `E.bad(pos, msg) =>`, and a bare
  `e == E.bad` tests the member. An error prints with its fields, and
  `main` or a test that fails with one shows them. Tasks, `task.all`,
  `par`, `isolate`, `supervise`, `time.within`, and actor methods hand
  the fields to the waiter. A program whose errors carry fields is built
  outside a `rig batch`. Two errors compare whole only when their set's
  fields all compare, and two of `error`, of any set, no longer do: a
  program that wrote `a == b` of two `error` values now matches one, or
  compares it with a member (`e == E.name`).
- **Declared error sets:** a function may name the set it fails with,
  `-> T!E` or `sub f()!E`, and `T!` stays any error. `error L = A | B`
  names a union of sets. `catch |e|` gives `e` the callee's set, so a
  `match` on it names every member and needs no `_`, and `g: E =>`
  narrows an `error` or a union to a set. `!` and a failing `return`
  keep to the declared set. A task's set holds `task.Stop`, which
  `task.check` and `time.sleep` now declare. A program that ignored a
  typed binding (`catch |e| 0` on a `T!E` call) now names it `_`.
- **Member tests:** `x == K.name` tests which variant `x` holds, as
  `x == .name` does, one with a payload too, and needs no `==` on the
  payloads.

- **Renames:** `Box[T]` is `^T`, `Vec` is `List`, the owned `Text` is
  `String` and its read view is `?String`, and `Static` is the type of
  literal text.
- **`obj`:** `struct` is spelled `obj`, a contextual keyword.
  `struct` is an ordinary name, and a declaration written with it is
  rejected with a hint. `unique`, `from`, and `static` are contextual
  keywords too.
- **Syntax:** a deeper-indented line starting with `.` continues the
  statement above (not after a line that opens a block); a closure may
  omit trailing parameters; a bare `for X` loops over `X`; an iterator
  in a place is written `for x in !it`.
- **Optionals cost nothing where an object has a niche:** an object
  holding a `String`, `List`, box, handle, `Bool`, plain enum, or an
  object that does holds `none` in bytes no value of it holds, so its
  `T?` is the size of the object (`Cheese?` with a `String` is 32
  bytes, not 40) and `== none` is one compare. An optional of it,
  `(T?)?`, takes the next spare value where one is left. An object of
  numbers alone keeps its flag. It holds for an enum of thousands of
  variants and an object of thousands of fields, in an object's field
  types and defaults too.
- **An object that names its none:** `obj Node` with one integer or
  plain-enum field may declare `none id == 0`; its `Node?` then holds
  that value for `none`, the size of a `Node`, tested with one compare,
  and an object holding a `Node` has an optional its own size too. No
  `Node` holds the value: a constant is rejected, a run-time value is
  checked as the object is made, and the field is read-only everywhere
  (SPEC §12, "An object that names its none").
- **Inclusive ranges:** `a..=b` runs through `b`, beside `a..b`, which
  stops before it: a `for` source (`for b in 0..=U8.max` reaches the
  type's largest value without stepping past it), a slice
  (`xs[a..=b]`, `xs[..=b]`), and a range pattern (`1..=5 =>`,
  `200..=255 =>`).
- **Bytes are strings:** where a `U8` is expected, a string literal of
  one byte is that byte (`c: U8 = 'A'`, `c == "\n"`, `'0'..='9' =>` on a
  `U8`, `U8('>')`), and where a `[N]U8` is, its bytes
  (`HOME: [3]U8 = "\x1b[H"`). `b'…'` and `b"…"` are gone: `b'A'` is the
  name `b` and a string. Quotes decide only escapes, so a byte that
  needs one is written in double quotes (`"\n"`, `"\x1b"`).
- **`catch` binds as `??`:** the two share a level and read left to
  right, as Zig's `catch` and `orelse` do: `f() catch none ?? -1` is
  `(f() catch none) ?? -1`. A jump handler still takes the rest of the
  expression, and a block below `catch |e|` is unchanged; a handler that
  compares, joins with `and` or `or`, or chooses with `if` is
  parenthesized, `f() catch |e| (1 if e == E.bad else 2)`.
- **Weak handles:** `*w` upgrades a weak handle to a `*T?` (`*<w`
  upgrades and takes it); the method `w.upgrade()` is rejected with a
  hint, and so is `*~T`, as every holding sigil over a held value is.
- **Numbers:** `x.not()`, the integer bit methods `leading_zeros`,
  `trailing_zeros`, `count_ones`, and `swap_bytes`, and the wrapping
  left shift `<<%` and `<<%=`.
- **Text and lists:** String `reserve`, `push[T, e]`, and List
  `reserve`; a byte order on a one-byte type is rejected; clearing a
  List of plain values sets its length.
- **Closures capture field paths:** a capture's sigil takes a field
  path as it does in an expression, `|?@template, k| fill(@template, k)`,
  lending, copying, taking, or holding weakly that field alone; in the
  body the path names the capture, and the closure reaches nothing
  else of the object (SPEC §11).
- **A closure never called is rejected:** alone on a line, discarded
  with `_ =`, or bound and never used, with one message; `_ = |x| ...`
  passed the checker and failed in the Zig it emitted.
- **Frozen values:** `*Frozen(x)` puts a value that never changes again
  behind a handle counted atomically, so many tasks read it with no
  copy (Rust's `Arc`). It holds only data that never changes, reads as
  the value through its handle, and compares and hashes as the value,
  so it keys a Map (SPEC §18, "Frozen values").
- **One message for one mistake:** a closure that stores a view of one
  field of a value into another (`|!p.a, ?p.b| !p.a.push(p.b)`) is
  reported where the closure is made, not again in its body, and a
  generic that names `*Frozen[T]` and freezes a `T` reports a bad
  instance once.
- **Owned closures:** `*fun` and `*sub` take and return anything a
  function's signature may hold: write and read views for the call,
  owners, and handles (docs/CORE.md §7). A temporary callee,
  `(+h.f)(x)`, is planned.
- **Vectors:** `Simd[T, n]`, `n` lanes of a number or `Bool` (`n` a
  power of two from 2 to 64): lane-wise operators that panic on
  overflow (`+%` and friends wrap), comparisons that give a mask
  `Simd[Bool, n]` with `any()`, `all()`, and `bits()`, `v.with(i, x)`,
  and byte reads with one bounds check. A vector is plain data
  (docs/CORE.md).
- **Modules at scale:** a directory is a module whose `.rig` files
  share one namespace, as a Go package's do: `use a.b` names the
  directory `a/b/`, a `use` binds its name in its own file, private
  names are module-wide, and each module emits one Zig file. Modules
  still may not import each other in a cycle. A method may be
  declared outside its type's body in the type's module
  (`fun Point.norm(?@)`, `fun Wrap[T].map[U](...)`), which
  desugars to the member. Module constants fold in dependency order,
  and one that depends on itself is rejected. A directory's
  `_test.rig` files belong to its module only as the root of `rig test`
  (docs/internals/INTERNALS.md, "Directory modules").
- **Methods on a type parameter:** a generic body calls a method on a
  `T`, `x.m(args)`, `!x.m(args)`, or `<x.m(args)`, checked at each
  instance as the built-in operations are: the instance's type declares
  the method, taking self as the sigil says, the arguments the body
  passes, and giving the result the body takes from where the call
  stands (SPEC "Generic bodies", Stage 1 of
  [docs/design/apis.md](docs/design/apis.md)).
- **Bounds:** a type parameter may name built-in APIs in its brackets,
  `[T: Ord]`, `[K: Hash + Print]`, and its body is checked against them
  alone; each instance must provide them, checked at the call. A type's
  header names the APIs it gives a meaning of its own, `obj Version:
  Ord`, which orders an object by its fields and an enum by its
  variants, then payloads. `Bool` and `String` are ordered (`false <
  true`, a String by its bytes), and so are optionals, arrays, and
  slices of ordered values, element by element (docs/design/apis.md,
  Stage 2). A `T` bounded by `Copy` is copied out of a view of it as out
  of a name: `fun get[T: Copy](x: ?T) -> T` gives `x`.
- **Own meanings:** a type that names `Eq`, `Hash`, `Ord`, or `Print`
  on its header and writes `eq`, `hash_into`, `order`, or `print`, with
  the signature the API fixes, gives `==`, hashing, ordering, or
  printing its own meaning, at every level of nesting; a type with its
  own `==` and no `hash_into` has no hash. The built-in types `Order`,
  `Printer`, and `Hasher` serve them, and `x.order(?y)` orders any two
  values that provide `Ord`. A method merely named `hash` is an ordinary method: a
  Map keys such a type by its parts, where it rejected it.
- **Map and Set are built in:** they and the types their members give
  (`Item`, `Items`, `Keys`, `Values`, `Members`) are named with no
  import, as `List` is, and print with no module; there is no
  `std.hash`. A module's own type of one of these names hides the
  built-in one. `tools/migrate-builtin-map.py` rewrites a tree's
  programs, tests, and Markdown: it removes `use std.hash` and the
  `hash.` before these names.
- **`os.memory()`:** what the program's allocations come to: `live`
  bytes, the `peak`, and how many `allocs` it has made, for reports
  such as "Memory used". The release allocator counts on each thread's
  heap and adds to atomic totals every 64 KiB or 1,024 blocks, so its
  fast paths gain no atomic operation (Trig 0.5-0.8% slower on pup,
  within noise on the Mac). Only a program that names `os.memory`
  counts: any other compiles to the allocator without the counts.
- **`time.since_start()`:** the nanoseconds on the monotonic clock
  since the program started, an `Int`, so a plain function value reads
  a duration with no `Instant` to hold (virtual in a deterministic run).
  Only a program that names it reads the clock as it starts, so any
  other's code is what it would be without it (std.json's safe builds
  on the Mac had moved 4-7% slower with the reading, their hot
  functions 60 bytes later).
- **`text.Interner`:** the run-time string interner, which gives each
  string a dense `U32` id, is std.text's `Interner` (`use std.text`,
  then `text.Interner()`), apart from the built-in `Symbol`, a name the
  program writes. `tools/rename-interner.py` rewrites a tree's uses of
  its earlier name.
- **std takes bounds:** `Map[K: Hash, V]` and `Set[K: Hash]`;
  `sort`, `search`, `lower_bound`, and `math.min`, `max`, and `clamp`
  take `T: Ord`; `slices.contains` and `index_of` take `T: Eq`;
  `math.abs` takes `T: Signed + Ord`; and `sort.sort_by_key` sorts by a
  key that provides `Ord`.
- **Parameter names:** a type parameter starts with a capital letter and
  a compile-time value parameter with a lowercase one; `[t]` and
  `[N: Int]`, which earlier releases accepted, are rejected with the
  rename.
- **Evaluation order:** every assignment evaluates its value first,
  then its target's steps, then stores; the order is one recorded fact
  (`storage.SetOrder`, `storage.eachSetStep`) that emit and the
  ownership checker both read.
- **Errors:** `error` is a type, an error of any set (a parameter, a
  field, `List[error]`), and it is owning in every program: `<e`
  moves it and `+e` clones it (docs/CORE.md, "A failure moves its
  error").
- **Speed:** runtime fast paths for push, add, and clear; small,
  only-called functions are emitted `inline` by a size rule the
  compiler decides (`src/inlining.zig`); a function marked `inline fun`
  is inlined at every call, one marked `called fun` is always a call
  (`noinline fn`), and a block whose first line is `rarely` (a
  function's body, a branch, a `catch` handler, a loop's body) is laid
  out as the unlikely path with Zig's cold hint, and such a function is
  kept out of line (the three words are contextual; `rarely fun` is
  gone); a
  `for` index counter needs no per-iteration cast; a List index makes
  one bounds test, not two; and the proven checks cover Lists, Lists in
  fields, `for` ranges, `s[i + c]`, a bound through a bound, and flags:
  facts tested once before a statement, which omit the tests they prove
  while they hold, so a record read from consecutive slots or a loop
  whose bound may pass a List's length makes its tests once
  (docs/internals/INTERNALS.md, "Flags").
- **Lengths:** reading the length of a List, a String, or a slice
  makes no test: no List grows past `2^62 - 1` elements (growth past
  it panics, "length out of range"), and no buffer of elements of a
  byte or more can be that long (docs/internals/INTERNALS.md,
  `heldLen`).
- **The stack:** a program runs on a 64 MiB stack the runtime maps
  over a 64 GiB guard (`rig.onOwnStack`), so running out of stack, by
  deep recursion or a frame no larger than the guard, stops with
  `error: rig: stack overflow` in every build mode; each frame's reach
  (what it keeps and every value its code makes or copies) is held to
  a bound that keeps it within the guard by a measured factor, not yet
  a proven one (destination-passing, in [docs/internals/backlog.md](docs/internals/backlog.md), will make it one), and a
  large frame is never inlined; a fill a box or a local takes is built
  in place (docs/internals/INTERNALS.md, "The program's stack").
- **Release builds:** a conversion to an unsigned integer type from a
  signed one keeps its high bit (`U8(200) >= 128` is true), as do shift
  amounts and `$fromBackingInt`: they cast through the unsigned type of
  the source's width, since Zig 0.17 lowers a direct cast as LLVM
  `trunc nsw`, which made such values poison.
- **Heap profile:** a program built with `RIG_HEAP_PROFILE=1` (debug or
  release) reports at exit what owned its memory at its peak: live bytes
  by the type each block holds, largest first; `RIG_HEAP_PROFILE=sites`
  adds the calls that held the most, each as a short stack.
- **Map trace:** a program built with `RIG_MAP_TRACE=1` records every
  operation on a built-in Map or Set, 48 bytes each, in
  `$RIG_MAP_TRACE_FILE` (default `rig-map-trace.bin`), with each Map's
  key and value types beside it; `tools/map-trace.py` summarizes a
  trace. A build without the flag is unchanged.
- **Map and Set:** a key of 8 bytes or fewer keeps no stored hash, so
  such a Map takes 8 bytes an entry fewer; Trig's ts-pattern peaks at
  403 MB rather than 425.
- **The scheduler's spin lock waits by reading:** a thread waiting for
  it reads until it looks free before trying to take it, so waiters do
  not fight over its line, and the blocking pool reads the clock before
  taking its lock rather than under it. A walk of a large tree with
  loco spent 62% of a worker's time spinning there; in a copy so
  patched its user time fell from 14.9 s to 1.4 s at the same wall time.
- **Release allocator:** on Linux, the heap that does the program's
  work faults in ahead the memory it is about to fill: one that has
  taken from the system at least four times what every other heap has
  together. A thread beside it that takes little, as the blocking pool's
  reading a file, no longer turns faulting ahead off, and a program of
  several busy threads still faults lazily. Trig's ts-pattern at one
  checker on pup takes 37.8K page faults rather than 81.0K and runs 2 to
  3% faster (zod3 4 to 7%), for 4 to 6% more peak memory: ts-pattern
  peaks at 342 MB rather than 328, since memory faulted in ahead is
  resident before it is filled. At four checkers both are unchanged.
- **Release allocator:** on Linux, a heap that has taken from the
  system two segments' worth (8 MB) faults in ahead too, beside others
  as large: each of several parallel checkers does, while a server's or
  a task program's workers, each within one segment, fault lazily.
  Trig on pup at four checkers takes 51.4K page faults on ts-pattern
  rather than 91.4K (zod3 20.0K rather than 30.8K), for 5 to 6% more
  peak memory: ts-pattern peaks at 402 MB rather than 383, zod3 at 150
  rather than 142. zod3 runs 4 to 6% faster; ts-pattern's time is
  unchanged. The task, actor, net and http benches are unchanged.
- **Release allocator:** a small block of up to 1 KiB, aligned to 8 or
  less, is taken and given back with no call: 23 instructions to
  allocate and 26 to free on x86-64, where each took about 50. Trig checks ts-pattern
  at one checker with 1.8% fewer instructions (zod3 2.0%); its time
  moves within the run-to-run spread.
- **Release allocator:** a large block that grows moves into a kept
  block that fits, copying it into pages already resident, and keeps
  the block it left; one no kept block fits grows on Linux by moving
  its pages (`mremap`) from 64 KiB, where it did from 1 MiB, so it
  leaves no old block resident. Growing by `mremap` had taken fresh
  pages for every table while the heap gave back the resident ones it
  kept. On pup, bench/hash's 100,000-key inserts run 7 to 30% faster
  under the Zig table and 7 to 22% for the built-in Map, and every row
  1.7% faster (geometric mean), the 3M and 4M rows unchanged; Trig's
  peak memory is 2.8% lower on ts-pattern and 2.9% on zod3, its time
  and instructions unchanged. The Mac is unchanged.
- **Release allocator:** a freed block over 32 KiB serves any later
  request it fits, the smallest kept block that does, with the rest kept
  apart, where it served only a request of its own size; and a heap
  keeps freed blocks while what it holds in large blocks, handed out and
  kept, is no more than the most it has handed out at once and 16 MiB,
  where it kept 16 MiB. bench/hash's big-value inserts on pup run 17 to
  65% faster (1.36 times malloc's time, from 1.76), on the Mac 9 to
  46%. Trig's peak memory is 1.0 to 3.0% lower on ts-pattern and zod3,
  its instructions and time unchanged. Huge pages for blocks of 2 MiB
  or more were measured and left out: they raised ts-pattern's peak
  memory by 1.3 to 2.0%.
- **Release allocator:** on Linux, a large block of 16 MiB or more
  that a heap maps afresh, or that `mremap` grows to that size, is
  aligned to 2 MiB and asks for transparent huge pages
  (`MADV_HUGEPAGE`); smaller blocks and blocks reused from those a heap
  keeps are left as they are. On pup, bench/hash's 3M and 4M-key rows
  run 11% faster and its big-value inserts 10% faster (`big1000000`
  36%). Trig's peak memory on ts-pattern is 0.4% higher at one checker
  (296.2 MB against 295.0) and the same at four, zod3's the same; its
  time and instructions are unchanged. Other systems are unchanged.
- **Release allocator:** on Linux, a heap that faults in ahead (one
  that leads the heaps or has taken two segments) asks for transparent
  huge pages for each new segment (`MADV_HUGEPAGE`); other heaps keep
  small pages. Trig on pup runs 1.7 to 3.2% faster at one checker and
  2.9 to 4.6% at four, with 22 to 36% fewer dTLB misses and its
  instructions unchanged; its peak memory is 0.1 to 0.7% higher on
  ts-pattern and 1.5 to 2.0% on zod3. Other systems are unchanged.
- **Release runtime:** on Linux, a reserved Table past its first 2 MiB,
  a heap's new segment, and a new large block of 16 MiB or more ask for
  transparent huge pages only while `/proc/buddyinfo` shows more than
  128 free blocks of 2 MiB or more. Under the default `defrag` setting,
  a fault in a range that asked compacts memory when no free 2 MiB
  block is left: on pup with its memory fragmented, Trig ran 34 to 41%
  slower than with no huge pages, the Tables' requests the most and the
  segments' as surely. With the test, Trig on pup is 4.6% faster than
  with no huge pages on ts-pattern (main 5.4%) and 3.0% on zod3 (main
  4.0%) when memory is free, and within 0.4% of no huge pages when it
  is fragmented, where main is 54 to 57% slower. Other systems are
  unchanged.
- **Release runtime:** on Linux, the test for huge pages asks while
  more than 64 free 2 MiB blocks are left, where it asked for more than
  128. pup idles at about 90 to 140, where 128 shut the test for most
  of Trig's runs, as a run's own huge pages drain the count: there Trig
  on pup is 5.8% faster on ts-pattern and 1.9% on zod3. When memory is
  free it is within 1.4% of 128, and with memory partly fragmented (35
  to 65 free) it asks for none and runs as with no huge pages, where
  spares of 32 and 16 stalled in compaction. Peak memory is unchanged.
- **Release runtime:** on Linux, a heap's new segment and a new large
  block of 16 MiB or more ask for huge pages while free 2 MiB blocks
  number what they need and 8 more, where they waited for more than 64;
  a reserved Table keeps the spare of 64. A segment or block asks just
  before its pages fault, so the count is current, where a Table asks
  once for a reservation it grows into all run. With 12 to 17 free
  blocks on pup, Trig runs zod3 2.6% faster and its small projects 3.2
  to 5.4%, ts-pattern 0.8%, with no compaction stall and peak memory up
  to 2 MB higher; with memory free it runs as before.
- **Release allocator:** a heap keeps freed large blocks within its
  settled peak, the most it has had handed out just after a free, and
  16 MiB, where the peak was the most handed out at any moment. That
  counted a growth's new block, mostly untouched, beside the old one,
  so a table that grew left the block it grew from resident:
  bench/hash's 4M-key map takes 39.5 bytes an entry on the Mac, from
  51.0 (39.7 before the bound). Tables built and dropped again and
  again still take their pages from what the heap kept, and bench/hash
  runs at its speed (all rows within 0.3%). Trig's time, instructions
  and peak memory are unchanged.
- **Release allocator:** a heap that does not fault in ahead, as a
  server's worker's, keeps 1 MiB of the large blocks it frees resident.
  Past that, it gives the pages of each block after its first back to
  the system (`MADV_DONTNEED` on Linux, `MADV_FREE_REUSABLE` on macOS)
  and keeps the block by address for its next request. A server's
  workers free blocks that other workers made, so what each kept grew
  toward 16 MiB. On pup's 22 workers, kv with 64 KiB values peaks at
  34% less memory (34-40 MB rather than 56-61) for 1.1-1.5% fewer
  requests a second by the median of 50 interleaved pairs (3.3-4.2% by
  the geometric mean), a trade the owner accepted; mimalloc-bench's
  xmalloc-test peaks at 71% less (80 MB rather than 275) at its speed,
  and sh8bench is level. A heap that does the program's work, as each
  of Trig's checkers', is unchanged: Trig's time and peak memory, and
  the task, actor, net and http benches, are as before.

- **Map and Set growth:** a table that grows is made anew with its
  free slots written at once, where it pushed them one at a time: Trig
  checks ts-pattern and zod3 with 1.5% fewer instructions and 1.6% fewer
  cycles.
- **Inline room:** `List[T, inline: n]` keeps its first `n` elements (1
  to 1024) inside the List value itself and allocates only once it
  holds more, when they all move to the heap, so a short-lived List of
  a few elements makes no allocation. It has every member a `List[T]`
  has and is a type of its own (SPEC, "Inline room").
- **`reduce`:** `xs.reduce(start, f)` on a slice, an array, or a List
  passes the running value, `start` first, and each element in order,
  lent as `?T`, to `f`, and keeps what `f` gives; an empty one gives
  `start`. The running value moves through, so it may own what it holds
  (`people.reduce(String(), |s, p| String(s, p.name, " "))`); a closure
  that can fail makes the call fallible, ending at the first failure. It
  works in a generic body on a `[]T` through the APIs a type gives, and
  a closure written at the call is inlined in a release build, as fast
  as the loop written out (docs/STD.md, "reduce").
- **A match on an element:** `match v[0]` with an arm that reads no
  binding, such as `_ => 1`, compiles for Lists and Tables, as a value
  and as a statement; it failed in the Zig it emitted.
- **Deadlock reports under load:** a deadlock found in an actor's method
  run inline is reported as the deadlock. A caller of the actor it ends,
  panicking at that end on another worker, could be reported in its
  place. A call that waits into a cycle it is not on names that cycle;
  its report failed with an index out of bounds in the runtime.
- **A closure literal given to an actor:** a method call through an
  actor's handle, waited on or run as a task, rejects a closure literal
  argument, as a task's call does: the actor runs it on a task of its
  own while its captures live in the caller's statement. `*g` of a
  function, where a `*fun` is expected, is rejected as `*g` alone is.
- **Tables:** `Table[T, n]` holds `n` slots from the moment it is made,
  each `T()` until written, and a `Slot[n]` is a number below `n` that
  only `push`, `Slot[n].of(i)`, and a literal below `n` make, so `t[s]`
  reads or writes its slot with no bounds test, whichever table gave
  `s`. A table of plain data whose default is all zero bytes reserves its
  slots with its own `mmap`, so untouched slots take no memory and the
  table never copies as it grows; other elements are made in every slot,
  up to 64 MiB. `Table()` is no field's default: a table is made where its
  owner is. A measuring build of Trig whose store indexes were treated
  as proven, a stand-in for tables, ran ts-pattern about 3% faster
  (fastest of 10, 2.8% fewer cycles); Trig's stores move to tables in a
  change of its own (docs/STD.md, "Table and Slot"). A generic call
  infers `n` from a `Slot[n]` argument, as from a `Table[T, n]`.
- **Compile-time functions:** a `fun` with only a bracket parameter
  list, `fun cap[n: Int] -> Int`, runs in the checker, and its call
  `cap[8]` is a constant wherever one may stand: an expression, a module
  constant, an array length (`[cap[4] * 2]Int`), a type argument
  (`Ring[Int, cap[1]]`), an enum value, and from another module. Its
  parameters are integers, `Bool`, and plain enums, its result one of
  those or a fixed array of them, and its body a fixed list of forms
  (locals, arithmetic, `if`, `match`, loops, arrays, and calls of other
  compile-time functions, recursion included). Overflow, a bad index,
  a `panic`, and more than 10,000,000 steps or 256 nested calls are Rig
  diagnostics at the call. Emit writes the value as a literal and never
  the function (SPEC, "Compile-time functions").
- **A closure stored into an existing slot:** a closure literal assigned
  to a `fun` local or through a write view is rejected as escaping its
  scope; it was accepted and failed in emit.
- **Optionals:** an object's `T?` of at most 8 bytes, such as one of
  a single `U32` field, is written in one store of its full width, the
  payload and its flag byte together, so a later read of the whole value
  is forwarded from that store; on x86, writing them apart stalled such
  reads (Trig's binder binds 7% faster on an x86 core). Its type and
  layout are Zig's `?T`, as before.
- **Frame pointers:** release builds (`--release`, `--release=fast`)
  omit them, which frees a register in every function: Trig checks
  ts-pattern and zod3 on an x86 core with 2.5-2.9% fewer instructions
  and 1-2% faster. Debug builds keep them. A profiler that walks them
  (`perf record -g`, macOS's `sample`) sees no callers in a release
  build unless `RIG_FRAME_POINTERS=1` was set when it was built.
- **BOLT:** `rig build --release --bolt -- WORKLOAD` lays the
  executable out again with LLVM's BOLT, by a `perf` profile of the
  workload (Linux), and `--bolt-profile=FILE` keeps that profile or
  lays a later build out by it.
- **PGO:** `rig build --release --pgo -- WORKLOAD` optimizes the
  executable by LLVM's profile-guided optimization, trained on the
  workload: Zig's bitcode of the program is compiled by `zig cc` with
  LLVM's counters, the workload runs it, and the same bitcode is
  compiled again by the merged profile and linked by Zig (Linux, a
  program that links no C library, with `llvm-profdata` and the profile
  runtime of Zig's LLVM). `--pgo-profile=FILE` keeps the profile or
  builds by it; a profile of an older program is used for the functions
  that did not change, and the build says how many did. Trig checks
  ts-pattern 10% faster with 14% fewer instructions, trained on zod3,
  and 5-9% faster than with BOLT alone. A build without `--pgo` is
  unchanged.
- **Compiler and tools:** a synthetic span outside its source reads as
  empty; the package cache and the build store have size caps;
  `src/parser.zig` is generated at build time from `rig.grammar`
  with Nexus, which is co-developed with Rig; and `tools/migrate-0.3.py`
  migrates 0.2 programs, each rename an independent pass (box, list,
  string, `obj`, builtin, label, self, `const`), in `.rig` files, test
  files' cases, and Markdown's `rig` blocks, with `--dry-run` to print
  the diff. Of the 4,836 programs `v0.2.9` accepts, `main` accepts
  1,094 as written and 3,495 after the guide's scripts.
- **Rig's own repository:** `tools/heavy`, `test/rig.rip`,
  `test/matrix.py`, `tools/equiv.py`, and `tools/zig-next.py` find their
  git directory through `tools/gitdir`, which takes only a repository
  whose top level is Rig's. From a plain copy of Rig they stop with a
  message naming `GIT_DIR`, rather than keep a lock or a build store in
  a repository that encloses the copy.
- **`tools/emit-diff BASE`** says whether `bin/rig` emits the same Zig
  as a `rig` built at `BASE` for the examples, the benches, every std
  module, and Trig; a change whose emit is identical skips its timing
  round. **`tools/baseline SHA`** prints the path of a `rig` built at a
  commit, built once and cached in the git directory.

### `std.json` (experimental)

A one-pass, validating JSON parser in
safe Rig (`std/json.rig`) that builds a tape, with a tiered string
scan (SWAR, then `Simd[U8, 16]`). `bench/json/check/compare.py`
checks it against Python's `json` module on 10,511 inputs;
`tools/fetch-json-data.sh` fetches the third-party files those read. `bench/json/` times it
against Zig's `std.json`, serde_json, simd-json, sonic-rs and
zimdjson (docs/history/json-results.md). Its API is not settled
(docs/design/json.md, "Open items").

std.json: an escaped string checks its length once, so safe builds keep
#538's gain on x86 (pup's safe builds are back within 2% of the earlier
reference on every file). Canada runs 2.4-2.8% (pup) and up to 4% (Mac
safe) slower than before, which is layout and is noted, not fixed.

### Concurrency

The model and its plan are
[docs/design/concurrency.md](docs/design/concurrency.md), with its reviews in
[docs/design/concurrency-panel/](docs/design/concurrency-panel/README.md). The plan's
first step is on `main` (SPEC §18):

- **A call on the blocking pool no longer spins its core away.** The
  waiter of a file call (`realpath`, `stat`, `read`) spins 64 times while
  the call's thread finishes, then yields its thread. Pinned to one
  core, it spun until the kernel preempted it, about 2.4 ms of every
  Trig run: 37% of its gap to tsrs on a small project.
- **Tasks:** `f(x)&` runs a call as a task and gives a `Task[T]`,
  which keeps its arguments' loans until `>t` takes its
  result; a task is never left running past its scope.
- **Cancellation:** `<t.cancel()`, a cancel that sticks, `std.task`
  (`Stop`, `check`), and a fallible `time.sleep`.
- **A cancel passes only down:** a task that cancels the tasks it owns
  is not canceled itself. A failed `par.map` or `par.each`, and
  `http.serve` closing its connections, no longer left the calling task
  canceled, failing its next wait with `task.Stop.canceled`.
- **Interrupts:** Ctrl-C (SIGINT) or SIGTERM cancels a `main` that can
  fail: its defers and drops run, the tasks it owns are canceled, and
  the program ends with status 130 or 143, showing no error. A second
  interrupt ends it at once; a `main` that cannot fail keeps the
  signals' default; `rig run` waits for its program to end.
- **Sets and joins:** `Tasks[T]` with `>ts` and `wait_first`, and
  `task.all`; a deadline for any wait is `time.within`'s, which calls
  its closure exactly once, so it may move a task or a set in.
- **Isolating a panic:** `task.isolate(f)` stops a panic in `f`, or
  in a task under it, cancels and waits for those tasks, leaves `f`'s
  frames where they stand, and fails with `task.Stop.panicked`
  (`tasks.Isolate`, `sched.runApart`).
- **Actors:** `*Actor(x)` holds a value that many tasks change, one
  method at a time: a call through a handle is a message in the
  caller's frame, waited for, or a task with `&` that takes a mailbox
  slot; a call not yet started is withdrawn on a cancel or deadline
  (`tasks.Actor`, `typecheck.actorCall`). A call that finds the actor
  idle runs inline, as the actor, at about a lock's cost
  (`Actor.claim`; bench/actors times it against a Go mutex and a Tokio
  actor). A wait that closes a cycle of actor calls and task waits
  panics, naming the calls (`sched.block`). A panic in an actor's
  method ends the actor and panics in its caller, and later calls
  panic (`Actor.kill`, `tasks.actorsDie`). `*Actor.supervised(*|| ...)`
  makes its value again after such a panic, within `restarts:` and
  `per:` (`typecheck.actorSupervised`, `Actor.remake`).
- **Deterministic tests:** `rig test` runs tasks on one thread with
  a virtual clock and a seed (`--seed`, `--seeds`, `RIG_SEED`), so a
  concurrent test fails the same way twice and sleeps take no time;
  the suite's concurrency cases run again under 20 seeds.
- **Deadlines and parallel loops:** `time.within(ns, || ...)`, a
  deadline every fallible waiting point honors, kept by the tasks it
  starts; it calls its closure once, so `time.within(d, |<t| >t!)`
  gives a deadline to a task, or a set, started before it. `par.map`
  and `par.each` (`std.par`), typed by the checker as `task.all` is,
  with chunks taken in turn by a task per worker.
- **Workers with state:** `par.workers(!states, ?items, |s, x| ...)`
  runs one task for each state, which it holds to write, and each task
  takes the next item, in the caller's order, until none is left; the
  values come back in the order of the items, whichever task made each
  (`typecheck.parWorkers`, `tasks.parWorkers`). A caller that puts the
  heavy items first balances an uneven load, as a checker per task does.
- **Closures called once:** a parameter written `f: once ?fun() -> T`
  is called at most once, and a closure literal passed to one owns
  what it moves in, so its call may move it out
  (`resolve.recordOnce`, `Origins.once`).
- **Renamed:** the task bounds `Moves` and `Shares` are `Sends` and
  `Syncs`, Rust's words: the sigils `<` and `*` name moves and sharing
  within a task, the bounds name crossing to other tasks. The old names
  are rejected with the new ones.
- **Removed:** `within:` on a set's wait, `wait_all`, and `task.both`.
  A deadline is `time.within`'s, a set is waited for with `>ts`, and
  `task.all` takes two tasks; each removed form is rejected with the
  form to write.
- **Where tasks run:** on Rig's own scheduler (`src/sched.zig`,
  `src/tasks.zig`): fibers on a worker per core, `RIG_WORKERS` of
  them when set, with yield checks in long loops and recursion
  ([docs/internals/scheduler.md](docs/internals/scheduler.md)).
  Each worker sleeps in a poller of its own (kqueue, epoll), with its
  own heap of timers; a fiber can wait for a file descriptor to be
  ready (`sched.waitReady`). `std.net` builds TCP listeners and
  streams on it, as fast as Tokio's and Go's on loopback (bench/net);
  `std.http`'s `http.serve(<listener, |req| ...)` runs each
  connection as a task and each request isolated, a panic answering
  500 (`rig/net.zig`, `serve`). bench/http times it against hyper
  and Go: as fast as hyper on the Mac and about three and a half
  times its requests on pup, at 8.6 to 16.6 KiB per idle connection, below
  Tokio's and Go's: an idle connection holds no buffer (`net.Conn`).
  The server answers `Expect: 100-continue`, refuses a body over
  16 MiB with 413, closes a connection idle 60 s or a request head
  slower than 10 s, and pauses accepting when out of descriptors
  (docs/STD.md, std.http).
- **Waking a task wakes no other worker** when the worker that woke it
  runs it next, or the waker's next yield check hands it on
  (`sched.wake`): two tasks that answer each other over a socket stay
  on one worker, with no system call to wake another, and fork-join
  (`t = f()&; g(); >t`) spreads at `g`'s first yield check. The worker
  watching busy workers' pollers keeps the watch while they wake, so
  they kick no one as they do (`sched.sleepIn`). A worker going to
  sleep, or a check that takes the notice of waiting work, leaves that
  notice set while another worker's run-next slot holds a task
  (`sched.takeWaiting`), so a maker computing in recursion, whose checks
  read only the notice, hands the task on; one that cleared it left the
  task waiting until the maker finished.
- **A server's memory no longer grows with workers times
  connections:** a `net.Stream` read into a String without room for
  `max` more reads through the worker's block and keeps only the bytes
  that came, so a task waiting for bytes holds no buffer, and a String
  freed on another worker is a small block, not a 24 KiB one. Each
  thread's alternate signal stack is a mapping of the runtime's,
  untouched until a signal runs on it, not Zig's 256 KiB thread-local
  array, which every worker and blocking-pool thread kept resident; a
  task that blocks on another task or an actor touches one stack page,
  its deadlock walk in a frame of its own (`sched.walkFrom`); and a new
  reservation's stacks hold no page until used. A task-per-connection
  key-value server (Redis's protocol, an actor for the store) under
  load holds 6.4 to 6.8 MB at 50 connections on the Mac, was 16.5 to
  19.4, and 24 to 26 MB at 1,000, was 89 to 148; on pup, with 22
  workers, 5.0 MB at 50, was 14.5, and 10.6 MB at 1,000, was 128 to
  137. The same server in Tokio holds 5.6 to 5.7 MB and 25 MB on the
  Mac, 5.9 and 21 MB on pup.
- **Reads grow a String unfilled:** std.file's reads, std.http's
  strings, and net's reads grow a String through the runtime's raw
  growth, as every String append does, so a safe build writes no 0xAA
  over the room a read makes, and a socket read without tasks reserves
  exactly `max`, 16 KiB for a read of 16 KiB where it took 28. A read
  of 64 MiB that five bytes fill holds no pages for the rest.
- **A stream sends each write at once:** every accepted and connected
  `net.Stream` sets `TCP_NODELAY`, so a request written in pieces, or
  pipelined behind one not yet answered, no longer waits for the other
  end's delayed acknowledgment, about 40 ms on Linux. `!s.batch(true)`
  lets the system hold small writes and send them together again.
- **A stream splits in two:** `r, w = <s.split()` gives a `net.Reader`
  and a `net.Writer`, which two tasks own: one reads while the other
  writes, on one connection. `<w.close()`, or the writer's drop, ends
  this side's writing (a half-close), and the other end reads the end
  while the reader still reads; the connection closes once both halves
  are gone.
- **An end wakes only the waits it ends:** the poller marks the end of
  reading as readiness to read and the end of writing as readiness to
  write, where any end once woke every wait on the descriptor for good.
  A reader no longer spins after its own side half-closes (kqueue's
  write filter reports it), nor a writer on a full buffer after the
  other end does.
- **Each worker on cache lines of its own:** no line holds two
  workers' fields (`sched.Worker`), so a yield takes about 5 ns on the
  Mac and 22 on pup's two hyperthreads, 45% and 12% less (bench/tasks).
- **Fewer yield checks, the same bound:** a recursive check sits only
  in the functions that cut every cycle of calls, a feedback vertex set
  the compiler picks once (`inlining.Pass.cutCycles`), and a loop counts
  a turn as the next one begins, so a turn that leaves the loop counts
  nothing. A task that recurses still checks on every turn of any cycle.
  Trig's checker keeps 387 of its 2,812 recursive checks; on ts-pattern
  with one checker it runs 5% fewer instructions and 2% faster (pup).
- **A yield check costs no registers:** in an optimized build for
  x86_64 or aarch64, a loop's turn check and a recursive function's
  entry check call the scheduler through a function that saves and
  restores every register a call may change (`rig.callKeeping`), so the
  code around a check no longer keeps its values in registers a call
  preserves for the sake of a call it rarely makes. The call may still
  read and write any memory. Trig built with `--pgo` runs 0.8-0.9%
  fewer instructions on ts-pattern and zod3 (1.9% in a plain release
  build), in about the same time
  ([records](docs/history/records/2026-10/perf-stage/loop-hoist.md)).
- **Channels:** `*Chan[T](n)` sends and receives between tasks, and
  `task.select` commits exactly one of its arms (`tasks.Chan`,
  `selectArms`). `task.supervise(f, restarts:, per:)` runs a
  function isolated again after it fails or panics.
- **Function values cross:** a `fun` or `sub` value is a named
  function's address and holds nothing, so a task given or lent one,
  alone or inside an object, a List, or a channel, runs on any core. A
  callable view `?fun` and an owned closure `*fun` or `~fun` go to no
  task.
- **Local tasks:** a task given or lent what stays on one thread (a
  `*T` whose count is not atomic, a `Cell` of more than one word, a
  `Signal`) is local: it and the task making it are
  pinned to one worker, whose pinned queue no other worker steals
  from (`sema.localBlocker`, `Task.spawnLocal`, `sched.pinHere`).
- **The scheduler's cost:** `bench/tasks` times it against Tokio and Go, and
  `bench/tasks/PROGRESS.md` records each step: it starts, waits for,
  and switches tasks faster than Tokio, but a sleeping task holds
  one stack page (17 KiB on the Mac), where Tokio's holds about 300
  bytes.
