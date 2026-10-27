# Map and Set as compiler built-ins: the design (2026-10-27)

The owner, 2026-10-27: "Make Map and Set compiler built-ins like List,
backed by the Zig tables, after the Rig rewrite lands." The Rig rewrite
(#735, [map-rewrite-rig.md](map-rewrite-rig.md)) is the baseline to
beat; `bench/hash/ordered.zig` (`zig-ordered`,
[zig-ordered.md](zig-ordered.md)) is the bar. Nothing a program sees
changes: no member, signature, ownership, order, printing, or
diagnostic a test names.

## The shape: a Rig face over a built-in table

Two compiler built-ins, registered as `List` is (`resolve.registerBuiltins`)
and held by the runtime as `List` is (`rig.List(T)`):

| Built-in | Zig | What it is |
|---|---|---|
| `OrderedMap[K, V]` | `rig.OrderedMap(K, V)` | `zig-ordered`'s table, ported into `src/ordered.zig` |
| `OrderedSet[K]` | `rig.OrderedSet(K)` | the same table with no value (`V = void`) |

Their names are in scope in `std.prelude` alone: every module registers
the symbols (so their ids agree across modules, as `List`'s do), and
only the prelude's scope names them. A program cannot write either.

`Map` and `Set` stay objects of std/prelude.rig, each holding its table:

```
pub obj Map[K: Hash, V]
  pub ?len: Int = 0
  t: OrderedMap[K, V] = OrderedMap()
```

Each public member keeps its declaration as it is today, its doc
comment, `from`, and `keeps` included, and its body becomes a few
lines over the table: `get` is `@t.find(k)` then `@t.value(j)`.
`Item`, `Items`, `Keys`, `Values`, and `Members` stay prelude objects,
as programs name them; an iterator holds `?Map[K, V]` as now and steps
with the table's `live_from` and `gone_from`. The private `Entry`,
`Held`, `HeldKey`, `Table`, and their constants leave the prelude.

Why a Rig face rather than registering `Map` itself as `List` is:

- **Every checker sees what it sees today.** Typecheck, the ownership
  checker, and the oracle (`test/oracle/lower.zig`, `rigBuiltin`: "by
  what their methods' signatures say, never by their bodies") read
  `Map`'s declarations, which do not change. Registering `Map` in
  resolve would restate twenty members' origins (`from @, k, v`,
  `keeps make`, `from @map` through a view) in Zig, where the record of
  a mismatch is a soundness hole, not a test failure.
- **What a program can write about `Map` stays.** A program's own
  `obj Map` hides the prelude's (`builtin_type_names`); `len` is a
  read-only field ("field `len` of `Map` is read-only outside the
  methods of `Map`"); `K: Hash` is the bound; `Map.new(capacity)`;
  LSP hover and STD.md read the doc comments. A resolve built-in would
  need each of these again.
- **The facts of a `Map` derive from its fields**, as now: plain,
  glue, drop, clone, what crosses to a task, size, niche. The table's
  own facts are `List`'s, over two parameters (below).

The cost is one call level, `Map.get` to `OrderedMap.find`, which Zig
inlines (`inline fun` and runtime `inline fn`), so the machine code is
the table's.

## How each built-in member is declared (List's way)

`registerBuiltins` gives each member its receiver mode, parameter and
result types, and its `Origins` written out, not the default (which
lets a call store any argument): a reader's result views only the
table, a writer stores only the keys and values it takes, and nothing
keeps a closure. So the wrapper bodies pass the ownership checker's
`checkOrigins` against the declarations they serve.

| Member | Signature | Origins |
|---|---|---|
| `find` | `(?@, k: ?K) -> Int?` | views nothing |
| `key`, `value` | `(?@, j: Int) -> ?K` / `?V` | from `@` |
| `value_mut` | `(!@, j: Int) -> !V` | from `@` |
| `put` | `(!@, k: K, v: V) -> Bool` | stores `k`, `v` in `@`; true when `k` was new |
| `replace` | `(!@, k: K, v: V) -> V?` | stores `k`, `v`; result from `@`, `v` |
| `put_new` | `(!@, k: K, v: V) -> Bool` | stores `k`, `v` |
| `ensure` | `(!@, k: K, v: V) -> Int` | stores `k`, `v`; the entry's index |
| `insert_new` | `(!@, k: K, v: V) -> Int` | stores `k`, `v`; `k` known absent |
| `take` | `(!@, k: ?K) -> V?` (`K?` in a Set) | result from `@` |
| `count`, `written`, `holes` | `(?@) -> Int` / `Bool` | views nothing |
| `live_from`, `gone_from`, `nth` | `(?@, j: Int) -> Int` | views nothing |
| `update` | `(!@, f: ?sub(?K, !V))` | keeps nothing |
| `retain` | `(!@, f: ?fun(?K, !V) -> Bool)` (`?fun(?K) -> Bool` in a Set) | keeps nothing |
| `clear`, `reserve` | `(!@)`, `(!@, n: Int)` | keeps nothing |

Set's table has `find`, `key`, `add` (as `put_new`), `take`,
`retain`, and the walk members.

## Closures

`ensure_with` and `ensure_by` call their closure in Rig, as now:
`@t.find(?k)`, and when it misses, the value or key is made in the
wrapper and `insert_new` adds it, out of line in Zig. `update` and
`retain` hand the closure to the table, which calls it per entry as
`f.call(.{ rig.lend(&e.key), &e.value })`: a closure view is
`rig.FnRef`, and the runtime calls one as any Zig code would. The
table is lent to write for the call, so the closure cannot reach it.

## Hashing and equality

The table hashes with `rig.hash` and compares with `rig.eql`, the
functions `.hash()` and `==` emit, so a key hashes and compares exactly
as now, a type's own `hash_into` and `==` included, and a `?String`
or `Static` finds a `String` key (`rig.ReadView(String)` is its bytes).
Decision 7 (one multiply for an integer key) is decided at compile
time in the table: `rig.hash` of an integer is already one multiply
(`hashInt`), so the table calls it unchanged.

## Drops

The table owns its keys and values. A take drops the key at once
(decision 4) and hands the value back; `put` drops the value it
replaces and a key already there; `clear` and the table's own drop
(`__rig_drop`, which `rig.dropElement` runs) drop every live entry,
then free the entries' block and the index. Each drop is
`rig.dropElement`, which is a no-op decided at compile time for plain
data. `+m` clones through `__rig_clone`, each live entry cloned in
order, as the deep clone of today's fields does.

## `at`

`m.at(i)`: `j = @t.nth(i)` (one step while no entry is gone, else the
count over the gone words, as now), then `@t.key(j)` and
`@t.value(j)`.

## The table's facts (sema), List's way

`OrderedMap[K, V]` and `OrderedSet[K]` join `List` wherever `List`
is decided by its symbol, over each parameter where `List` reads its
one: glue and not plain (`symbolContents`), heap-held parts
(`isHeapBuiltin`, so `sizedParts` and the depth see none), its byte
size (`minBytesOf`, the Zig struct's), deep clone when every parameter
clones, no table fill, built-in generic (`isBuiltinGeneric`). Equality,
hashing, ordering, and printing of the table itself are not given: a
`Map`'s `==` stays rejected, its message naming the field `t` where it
named `ps`.

## What the oracle needs

Nothing. It checks `Map` and `Set` calls by their declarations, which
do not change, and never their bodies; the prelude's bodies are std
code it does not decide. The suite's oracle runs must stay silent and
`test/oracle/rejections` unchanged.

## The Map trace

`RIG_MAP_TRACE=1` keeps working on the emitted prelude: the wrapper
methods it renames keep their names; `rebuild`, now the table's, is
recorded by the table itself through `rig.mapTraceOp` when the trace
is on.

## Risks

- **A built-in's origins wrong** is a soundness hole the oracle cannot
  see (it reads the wrapper's declarations). Each is a small table
  above, reviewed against the wrapper body that uses it; the
  ownership checker checks each wrapper body against its declaration,
  so an origin too narrow for the body is rejected in the suite.
- **Facts drift**: a place that decides by `list_sym_id` and misses
  the tables. Each is found by grep; the suite's Map cases cover
  clone, drop, tasks, and printing.
- **Diagnostics naming internals** (`==` on a Map, a Map as a key)
  name the field `t` and `OrderedMap[...]` where they named `ps` and
  `List[Entry[...]]`; no test or doc names either.
- **Speed in Rig's own bodies**: the wrapper's `@len = @t.count()`
  after each write is one store; everything else inlines.

No part changes an ownership rule or needs a CORE change.
