# The built-in Map table (#736): soundness and correctness review

The review covers #736 at 9386b4775, against its merge base f7edd5cb5
(`tools/baseline f7edd5cb5`). Every probe runs under `RIG_SANITIZE=1
bin/rig run` (debug, leak-checked) with `RIG_OUT_DIR` in a scratch
directory; the model probes also run under `--release=fast` and print
the same.

## Verdict

The table brings no defect the review finds. It drops each live key
and value exactly once, keeps first-put order through takes, growth,
compaction, retain, clear, and clone, and agrees with a model on String,
object, enum, Bool, U8, optional, and custom-`==`/`hash_into` keys. One
deviation from a recorded decision (the entry-index bounds test) and
two holes that f7edd5cb5 has as well follow; #737 closes both.

## 1. Deviation: no entry-index bounds test (decision 10)

Panel decision 10 (panel/README.md) keeps a bounds test on the entry
index read from the index, as map-rewrite-rig.md does. In
src/ordered.zig every entry read is through `entries: [*]E`, which Zig
never bounds-tests, in any mode: `findSmall` (492, 499), `probeFrom`
(518), `findIndexed` (546), `key`/`value`/`value_mut` (687-699). The
safety of a lookup rests on the table's invariants alone (that every
full lane names an entry below `len`). zig-ordered.md §12 measures the
checked variant 2-7% slower (13% slower on big1000 hits), which is
decision 10's exit at over 2%, so leaving it out may be allowed, but
map-builtin.md's "What differs from the prototype" does not record the
choice. The owner decides: record it, or test `j < len` (an
`std.debug.assert` costs nothing in release-fast but checks nothing
there either).

No probe reaches an invalid index: the private field `t` and the
names `OrderedMap`/`OrderedSet` are unreachable from programs (see §5),
and every index the prelude passes comes from `find`, `ensure`,
`insert_new`, `nth` (guarded by `at`'s `i < @len`), or
`live_from`/`gone_from` (clamped to `written`).

## 2. On f7edd5cb5 too: `Map.update` lets a value view its own key

```rig
sub main()
  s = String("x")
  m = Map[String, ?String]()
  !m.put(String("a-long-key-on-the-heap-0123456789"), ?s)
  !m.update(|k, v| v = k)
  if (!m).take("a-long-key-on-the-heap-0123456789") as v
    junk = String("ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ")
    print(v, junk.len)
```

f7edd5cb5 and #736 both accept it, and it reads freed memory.
The lambda's inferred `v: !?String` takes `k`, a view of the Map's
key; `take` drops the key and hands back the value viewing it. The
same body as a named function is rejected (`!?String` cannot be
written), so the hole is in how a lambda's inferred parameters are
checked, not in the table. #736 states the closure type
(`resolve.registerOrdered`, `update_f`) as it was, so it neither adds
nor closes the hole. `retain`'s `?fun(?K, !V) -> Bool` has the same
shape. #737 rejects a closure parameter given `!?String`; a value of
`(?String)?` or `List[?String]` keeps the hole (two `known: true` cases,
docs/internals/backlog.md).

## 3. On f7edd5cb5 too: `ensure_by` can put a key twice

```rig
sub main()
  m = Map[String, Int]()
  !m.put(String("b"), 1)
  (!m).ensure_by("a", |w| String("b"), 0) += 5
  print(m, m.len)
```

Both print `{"b": 1, "b": 5} 2`: `key(k)` makes a key other than `k`,
and `insert_new` (ordered.zig) takes it to be absent. It is no memory
error (#736 then takes and finds sanely; f7edd5cb5's misplaced hash
makes `get("b")` miss after a take), but it breaks accept-means-correct:
the Map holds two equal keys. #737 makes such a key panic.

## 4. Plausible, not run: `reserve` builds the index before the limit test

`reserve` (ordered.zig 940-951) rebuilds the index for `live + n`
before `resizeEntries` tests the 32-bit limit, so `Map.new(5_000_000_000)`
allocates and zeroes a 2^30-group (80 GiB) index before it could panic
"a Map holds at most 4294967295 entries". The probe is not run, since it would
swap the Mac. It is no corruption: `groups` is u32, but any `n` that would overflow it
fails the allocation first. The fix is to test the limit first in `reserve`.

## 5. Checked and sound

- **Naming.** `OrderedMap[...]()` and `OrderedSet[...]` in a program:
  "use of unbound name/type"; `m.t`: "field `t` of `Map` is private to
  ... `std.prelude`"; `use std.prelude` is rejected. Diagnostics for `==`
  on a Map and a Map as a key name `t` and `OrderedMap[Int, Int]`, as
  the design says.
- **Origins.** `signatureOrigins` gives each member its signature's
  origins with lent parameters never stored; the closures are lent, so
  not kept. Results viewing the table are `from @`. Probes matching
  f7edd5cb5: a view from `get`/`at`/`items` blocks a put; walking `keys()`
  and taking is rejected; a view-holding `V` from `take`/`replace` keeps
  its loan (`<s` rejected); `edit` cannot store a shorter-lived view.
- **Drops.** Objects with `drop` bodies as keys and values through put
  over a key, put_new and ensure on a present key, take, replace,
  retain, clear, and the Map's drop, small and indexed: 246 keys and
  171 values, each dropped exactly once; String keys and values leak
  nothing and touch no freed memory. A Set's take hands its key back
  undropped.
- **Clone.** `+m` of a Map with holes, then writes to each: independent;
  nested `Map[Int, Map[String, String]]` cloned then edited: independent.
- **Growth, compaction, small mode.** A model of 6000 random
  put/take/retain/clear/reserve/clone ops over 8 to 3000 String keys,
  checked every 101 ops (len, walk order, every `get`, every `at`):
  equal, debug and release-fast. Small mode after `clear` of a
  1000-entry table (cap > 32): 300 turns of put-and-take, holes in the
  middle, regrowth to an index, `reserve` from a table with holes: right.
- **Keys.** 8-byte objects (no stored hash: insert hashes a view,
  rebuild and small reindex hash the value), custom `==`/`hash_into`
  keys looked up by an equal-but-different value after takes and a
  retain, enum, Bool, U8 (256 keys), `Int?` with `none`, `Static`.
- **Map?, List of Maps, tasks.** `Map?` none and some; a `Map` moved
  into a task; a Map holding a view crossing to a task; `Cell` values
  rejected as on f7edd5cb5.
- **runsDropBody.** Its answer, true for the tables, makes `holderLive`,
  `holdsPastDrop`, `envDropReads`, statement results, and
  `checkDropOrder` keep loans longer or check more: conservative. It
  changes nothing a program sees, since a `Map` is an imported type and
  `typeHasDropGlue` answers true on f7edd5cb5 as well (probes d1-d3 give
  the same errors on both).
- **Facts.** The tables join every `isHeapBuiltin`/`isBuiltinGeneric`
  site; the remaining `list_sym_id` sites are List-specific (literals,
  `inline:`, slicing, `.elems` lending), and `holdsIn` treats the tables
  as it treats List (no data fields, so `held` is empty for both).
- **Trace.** `RIG_MAP_TRACE=1` builds and runs.
