# HashMap and HashSet as compiler built-ins: the design (2026-10-27)

The owner confirmed the names on 2026-10-27: `HashMap[K, V]` and
`HashSet[K]`, the unordered pair, beside `Map` and `Set`, which stay
ordered and stay the default. They are built as #736 built `Map` and
`Set` ([map-builtin-design.md](map-builtin-design.md)): declarations in
Rig in std/prelude.rig over a compiler built-in table, whose runtime is a
Zig port of the hash race's unordered winner, `bench/hash/hash.zig`
(`zig-hash`, [zig-hash.md](zig-hash.md)), with its defaults.

## Is a second table justified?

Measured first, on the Mac (tools/low, fastest of 5, interleaved; load
3 to 4 from other agents), `zig-hash` against the ordered Map as it is
on main (`rig-fast`), on the rows where an unordered table should win:

| row | rig-fast (Map) | zig-hash | zig-hash / Map |
|---|---|---|---|
| rnd4000000 remove | 14.97 | 10.26 | 0.69 |
| int4000000 remove | 14.00 | 9.54 | 0.68 |
| churn1000 turnover | 4.21 | 1.75 | 0.42 |
| churn100000 turnover | 4.29 | 2.67 | 0.62 |
| churn4000000 turnover | 16.49 | 9.86 | 0.60 |
| rnd4000000 insert | 16.90 | 11.78 | 0.70 |
| int4000000 insert | 16.77 | 11.22 | 0.67 |
| rnd100000 miss | 1.51 | 0.84 | 0.56 |
| rnd3000000 miss | 3.25 | 1.30 | 0.40 |
| rnd4000000 miss | 4.40 | 2.00 | 0.45 |
| rnd3000000 hit | 8.35 | 5.31 | 0.64 |
| rnd4000000 hit | 11.38 | 7.43 | 0.65 |
| lat4000000 chain | 181.91 | 103.40 | 0.57 |

So yes: 30-60% faster on large removes, turnovers, large inserts,
misses, and out-of-cache hits, which an ordered table cannot reach
(panel §2: it waits on memory twice). The Map keeps its rows: in-order
walks (0.1-0.2 ns against 0.6-2.3), 16-key inserts, and the text and
64-byte-value removes.

## The shape

As #736's: a Rig face over a built-in table.

| Built-in | Zig | What it is |
|---|---|---|
| `UnorderedMap[K, V]` | `rig.UnorderedMap(K, V)` | `zig-hash`'s table, ported into `src/unordered.zig` |
| `UnorderedSet[K]` | `rig.UnorderedSet(K)` | the same with no value (`V = void`) |

`resolve.registerTables` registers the four tables in every module, only
std.prelude's scope names them, and each member's origins are its
signature's (`sema.signatureOrigins`), as for the ordered ones. Sema
holds the unordered tables as it holds the ordered ones (`isHashTable`:
heap built-ins, glue and not plain, deep clone where every parameter
clones, a drop that counts as running a body), at 48 bytes.

```
pub obj HashMap[K: Hash, V]
  pub ?len: Int = 0
  t: UnorderedMap[K, V] = UnorderedMap()
```

## Members

`HashMap` has every member of `Map` but `at`, each declared exactly as
`Map`'s is, its `from` and `keeps` included, so the ownership checker
and the oracle (`rigBuiltin`: by signatures, never bodies) treat them
the same: `new`, `reserve`, `has`, `get`, `edit`, `put`, `replace`,
`put_new`, `ensure`, `ensure_added`, `ensure_with`, `ensure_by` (with
#737's check that `key(k)` equals `k`), `retain`, `take`, `clear`,
`items`, `keys`, `values`, `update`, and the field `len`. `HashSet` has
every member of `Set`: `new`, `reserve`, `has`, `add`, `take`, `retain`,
`clear`, `items`, `len`.

**Left out: `Map.at(i)`**, the entry at index `i` in first-put order. It
is defined by the order a HashMap does not keep; an `at` over the slot
order would be an O(n) walk whose answer changes with every growth, and
nothing in std or Trig uses `at` but through the ordered Map.

The table's members differ from the ordered table's only in the walk:
`next_full(?@, j: Int) -> Int?`, the first full slot from `j` on, in
place of `written`, `holes`, `live_from`, `gone_from`, and `nth`. An index
the table hands out is a slot index; `key`, `value`, and `value_mut`
take one.

The iterators are new prelude objects, `HashItems[K, V]`,
`HashKeys[K, V]`, `HashValues[K, V]`, and `HashMembers[K]`, each holding
`?HashMap[K, V]` (or `?HashSet[K]`) and the next slot, so a walk is
`from @map` as a Map's is. `Item[K, V]` is shared.

## Order

Unspecified, in SPEC and STD. It is the slot order: a function of the
hashes, the target's group width (7 slots on arm64, 15 on x86-64), and
the table's history, so it differs between the Mac and pup. Printing a
HashMap prints `{k: v}` in that order. The tests sort or print one key.

## Hashing and equality

The table's own, as `zig-hash` hashes (decisions 7 and 8, inside the
table; `.hash()` unchanged): an integer key of up to 64 bits by one
multiply, a `String` or `?String` key by folded multiplies up to 32
bytes (Wyhash above) compared by words; every other key by `rig.hash`
and `rig.eql`, so a type's own `hash_into` and `==` are honored. A
lookup hashes the view `?K` it is given, and a put hashes a view of the
key it takes, so `String`, `?String`, and `Static` find each other.

## Drops

The table owns its keys and values, as the ordered one does: a take drops
the key (a HashSet's hands it back), a put over a key drops the old
value and the new key, `put_new` and `ensure` drop both when the key is
there, `retain` drops what it rejects then, `clear` and the drop drop
every entry, value before key. `+m` clones each entry into a table
sized for them.

## Safety

As #736 (decision 10's exit, recorded in map-builtin.md): no bounds test
on a slot index in a release build, where the index comes from the table
itself; a debug build (`rig run`, the suite) tests in `slotAt` that a
slot index is below the slot count and names a full slot, and panics if
not. `reserve` tests the 2^32 - 1 entry limit before it allocates; growth
tests it too.

## What is not changed

No ownership rule, no CORE paragraph, no diagnostic of `Map` or `Set`.
`RIG_MAP_TRACE` instruments `Map` and `Set` only (src/map_trace.zig);
a HashMap runs untraced.

## Naming question

The four iterator names (`HashItems`, `HashKeys`, `HashValues`,
`HashMembers`) are public, as `Items` and the rest are, so a program
may write them; they are the owner's to confirm.
