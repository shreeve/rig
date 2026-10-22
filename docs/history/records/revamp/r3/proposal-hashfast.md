# Proposal: hashfast, faster std.hash Map and Set, and a string interner

For the owner. Status: proposal; no code written. It names the new API (items 1, 2, 6), says which changes are invisible, and asks two questions the code cannot settle alone. The internal changes are measured one at a time against bench/hash and std.json's guard (nothing more than 2% slower anywhere, more than 2% faster somewhere), and land as separate commits so any one can be dropped.

## The API to decide

| # | Recommended | Signature | Alternatives considered |
|---|---|---|---|
| 1 | `(!m).edit_or_put(k, v)` | `fun edit_or_put(!self, k: ?K, v: V) -> !V from self` | `get_or_put` (Zig), `entry(k).or_insert(v)` (Rust), `setdefault` (Python) |
| 1 | `(!m).add(k, v)` | `fun add(!self, k: K, v: V) -> Bool` | `put_new`, `insert` |
| 2 | `hash.Map[K, V].new(capacity: n)`, `hash.Set[K].new(capacity: n)` | `fun new(capacity: Int = 0) -> Map[K, V]` | `Map[K, V](capacity: n)`, `with_capacity(n)` |
| 2 | `!m.reserve(n)`, `!s.reserve(n)` | `sub reserve(!self, n: Int)` | `grow(n)` |
| 6 | `hash.Interner()` | an object, made empty by `T()` | `std.intern`'s `Table` |
| 6 | `(!names).intern(s)` | `fun intern(!self, s: ?String) -> U32` | `get_or_intern`, `add` |
| 6 | `names.id(s)` | `fun id(?self, s: ?String) -> U32?` | `find`, `lookup` |
| 6 | `names.text(id)` | `fun text(?self, id: U32) -> ?String from self` | `get(id)`, `name(id)` |
| 6 | `names.len` | `pub ?len: Int` | |

Example (all of it runs once built):

```rig
use std.hash

sub main()
  counts = hash.Map[?String, Int].new(capacity: 64)
  for w in ["to", "be", "or", "not", "to", "be"]
    c = (!counts).edit_or_put(w, 0)
    c += 1
  print(counts.get("to"), counts.len)

  names = hash.Interner()
  a = (!names).intern("width")
  b = (!names).intern("height")
  print(a, b, (!names).intern("width"), names.id("depth"), names.text(b))
```

```output
2 4
0 1 0 none height
```

**Why these names** (docs/RIG-MANTRAS.md, "How we name", and the names std already has):

- `edit_or_put` joins two verbs the Map already has. `edit(k)` gives the value lent to write, as a `(!V)?`; `put(k, v)` adds an entry. This call edits, putting `v` first if `k` is not there, so it never fails and returns a plain `!V`. It reads as what it does, as `edit` and `put` do.
  - Rust's `entry().or_insert()` cannot be built: an entry object would hold the Map lent to write, and a write view is never stored inside a value (CORE §5). That rule is why this is one call.
  - `get_or_put` would break `get`'s meaning here, which is a read view.
  - `setdefault` is a word other languages disagree on.
- The key is a view, `k: ?K`, as `has`, `get`, `edit` and `take` take it. A hit costs no copy, which matters for `String` keys. On a miss the Map stores its own copy (`+k`); for `Int` and `?String` keys that copy is free. If a generic body cannot clone a `K` at every instance, the fallback is `k: K`, owned, as `put` takes it; that would cost a hit a String it then drops. This is the one spelling the code may still change, and I would report it.
- `v` is evaluated before the call, as every argument is. For the usual values (`0`, `List()`, `Item()`) that costs nothing on a hit. A form taking a function that makes the value on a miss can come later if needed.
- `add(k, v) -> Bool` is Set's `add` given a value: it puts `v` under `k` only when `k` is new, and says whether it did; otherwise `k` and `v` are dropped. It is already in the code, private, and Set uses it today.
- `new(capacity: n)` gives `new` the keyword List's constructor has, `List(capacity: n)`, as a defaulted parameter.
  - `hash.Map[K, V](capacity: n)` would read as setting a field named `capacity`. `T(...)` with arguments sets fields, and a Map's are private.
  - `reserve(n)` is List's and String's word for room for `n` more, with the same meaning.
- `intern` is the verb every language that has this uses (Python's `sys.intern`, Java's `String.intern`, Rust's string interners). `id(s)` and `text(id)` name their answers. `len` is a read-only field, as on Map and Set.

**Interner, what it is.**
- The text of every distinct string lives in one byte arena, a `String`. Ids are dense `U32`s from 0, in the order strings were first interned.
- `intern(s)` hashes `s` once. It returns the existing id, or copies the bytes into the arena and gives a new id.
- `id(s)` looks a string up and never copies. `text(id)` is a `?String` view into the arena, valid while the Interner is lent to read, like any view `from self`.
- The ids are plain `U32`s. A typed id (an `obj Name` holding the `U32`) is the caller's to wrap if wanted.

## The invisible changes (no API)

- **3. Stored hashes.** Each slot keeps its key's hash, so growing the table never hashes a key again. Taking an entry no longer hashes the keys it shifts.
- **5. Small-map mode, automatic** (preferred over opt-in):
  - A Map or Set of up to 8 entries has no table. A lookup compares the stored hashes of its entries in order, then the key on a match.
  - The table is built when the 9th entry arrives, and never dropped again. That avoids flapping at the boundary.
  - Nothing to choose, and the common symbol table pays nothing for the table it does not need.
  - 8 is a starting point; the bench decides it.
- **4c. Group probing.** The tag bytes are probed 16 at a time with `Simd[U8, 16]`: one compare against the tag, and one against free. It is kept only if it wins on bench/hash (large maps) and loses nothing on small ones.

## Two questions for the owner

**Q1. Taking an entry, and the leaner entry layout (item 4b).**
- Today a taken entry stays where it was as `none` (key and value are optionals). So `take` keeps the rest in insertion order, as the docs promise; growth drops the holes. The optionals are what make a `U32 → U32` entry 16 bytes: the key is 8 and the value 8.
- In safe Rig, an entry's key and value can be handed out only through an optional (`<x` needs one), or by `swap`-and-`pop`. So the options are:
  - **A. Keep the order** (today's rule).
    - The value stays optional and the key does not: a taken entry's key stays in place, dropped when the table next grows or compacts.
    - Tags mark the dead entry. `U32 → U32` becomes 12 bytes, not 8.
    - Set keeps its key optional, since `take` hands the key back.
  - **B. `take` moves the last entry into the hole** (Rust IndexMap's `swap_remove`).
    - Entries are plain `Entry[K, V]`: `U32 → U32` is 8 bytes, and `take` leaves no hole.
    - The insertion order holds until the first `take`. After it, the last entry stands where the taken one was.
    - Changes a documented behavior.
  - **C. `raw` in std/hash.rig** for an uninitialized entry array: 8 bytes and the order kept.
    - It would be the first `raw` in std, outside what the ownership checker checks.
    - It needs its own adversarial review.
- **I recommend A.** The order is what Trig and output-stable programs rely on (TypeScript emits declarations in order). A costs 4 bytes an entry more than B and keeps every guarantee. B could later be an extra method, `swap_take`, for callers who don't need the order.

**Q2. One allocation (item 4a).**
- One allocation for the entries and the table needs `raw` (Q1's option C). Safe Rig holds them as separate Lists.
- I propose two allocations instead of three:
  - the entries;
  - one table List, where each slot is a `U64` packing its tag, the stored hash, and the entry index. The index takes 32 bits, so up to 4G entries.
- With group probing, the tags are better a separate `List[U8]`, so that `Simd[U8, 16]` reads them directly. Then it stays three Lists, with the stored hash beside the index.
- I would measure both and keep the faster. Say if you want the raw single allocation considered.

## Item 7, exact String sizing

This belongs to the runtime, not std:
- A `String` built by `String(...)` gets its capacity from Zig's `Writer.Allocating` growth: 134 bytes for a 10-byte string (docs/RIG-NOTES.md entries 15 and 27).
- The fix is in `rig.String.of`/`add` (shrink to fit once formatting is done, or format into an exact buffer). That is `src/runtime.zig`, which this round does not touch.

I'll note it for the List/runtime round, with the bench/hash numbers (hashing a million such keys is about 4 times slower than exactly sized ones).

## Order of work

1. `reserve` and `new(capacity:)`; stored hashes; small-map mode. Each its own commit, each timed.
2. `edit_or_put` and the public `add`.
3. `hash.Interner`, with a bench row against a `Map[String, U32]` and against Zig.
4. The layout chosen in Q1/Q2, then group probing.

Each step:
- runs bench/hash's eight rows plus new rows (small maps of 4 and 8 entries; get-or-insert; interning a million words), interleaved, best of 7, in a window you give me;
- runs std.json's guard through you;
- lands only if it meets the speed rule.

Branch `hashfast` from origin/main, worktree `/Users/shreeve/Data/Code/rig-hashfast`, a draft PR first, and `--note "#<PR> hashfast"` on every cpuq job. No change to `src/runtime.zig` or emit.
