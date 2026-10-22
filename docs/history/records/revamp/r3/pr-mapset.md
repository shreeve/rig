Trig can now key a table on any value `==` compares, and walk it in insertion order:

```rig
use std.hash

obj Sym
  name: String
  flags: Int

sub main()
  table = hash.Map[String, Sym].new()
  !table.put(String("x"), Sym(name: String("x"), flags: 1))
  if (!table).edit("x") as s
    s.flags |= 4
  for e in ?table.items()
    print(e.key, e.value.flags)
  seen = hash.Set[?String].new()
  print((!seen).add("x"), (!seen).add("x"))
```

```output
x 5
true false
```

Round R1 of `.git/revamp/r3/proposal-traits-map.md` (Trig NEEDS 2), with the owner's decision that hashing is the method `x.hash()`. It builds on #206 (B2, `for e in ?m.items()`), now merged.

## R0: B1 to B3

- **B1** (generic `==` beside an optional) was fixed by #159 (`rig.eql` peels optionals). Its concrete half was still open: `String? == ?String` and `String? == "a"` were rejected. Now text beside an optional of text compares by its bytes, whatever its type (`test/behavior/types/optional_text_eq.rig`).
- **B2** is #206.
- **B3** (a loop view passed to a view parameter) was fixed by #159.

## R1a: `x.hash() -> U64`

- A built-in method (`ElemOp.hash`) on exactly the types `==` compares, less a `Float` and what holds one (`sema.notHashable`, the equatable walk with floats refused). A type that declares its own `hash` keeps it, and a data field `hash` holding a function is still called.
- Values `==` calls equal hash equal: text hashes its bytes (Wyhash, seed 0, as Zig's `StringHashMap`) whatever its type; an optional holding a value hashes as that value; an integer as its value, whatever its width or signedness (one 64x64 multiply, folded, for any value from the least `I64` to the greatest `U64`); objects, payload enums, arrays, and slices by their parts. Fixed seed.
- In a generic body `k.hash()` records `hashable`, checked per instance like `equatable`; an instance whose type declares its own `hash` is rejected, since the body calls the built-in one.
- It reads its receiver where it is, as `==` does: no ownership change.
- `rig.hash(x)` / `rig.hashAs(T, x)` in `src/runtime.zig`; SPEC §5 (beside `==`).

## R1b: `std/hash.rig`

`hash.Map[K, V]` and `hash.Set[K]`, insertion-ordered, with exactly §5's API and ownership table (docs/STD.md, "std.hash"). The entries live in one List in order (key and value side by side, `none` once taken); the table is open-addressed and linearly probed, at most 80% full, with a one-byte tag (seven bits of the hash) and a `U32` entry index per slot, so a miss reads only tags. Taking shifts the following slots back (no tombstones); growing drops taken entries. Set is a `Map[K, Bool]`. No field is read while another is written; `update` takes each value out of its entry while `f` has it.

## After the review

- **Probe loops** (`find`, `free_slot` for `place`): each pass takes a local view of the tags, `ts = ?self.tags[..]`, and loops `while 0 <= i and i < ts.len`, from the slot the hash names to the end and then from the start. `rig check --facts=proofs` lists `ts[i]` (lower and upper) and `i += 1` (no overflow) as proven in both, so a step reads a tag with no other test. `unslot`, which writes the tags as it scans and runs only on `take`, keeps its checks.
- **Integers:** `hashInt` hashes any value from the least `I64` to the greatest `U64` as one word in every width, so `I128(a).hash() == a.hash()` for `a: U64 = 2^64 - 1` (`test/behavior/types/hash_int_widths.rig`, the review's h01).
- **Handles** (owner decision B): a handle `*T` or `~T` has no `==` and no `.hash()`. `isText` no longer sees through `*T`, so `String? == *String` and `(*String).hash()` are rejected again; and the slip on `main`, `*String == *String` (and `*String == String`), is rejected too. Content is compared through views: `?a == ?b`, where `?h` of a name holding a `*T` lends a `?T` (CORE §4's row), and `rig.eql` reads a view held by address as its value. SPEC gains that sentence. Migrated: `test/behavior/types/box_members_compose.rig` and `test/corpus/r3-s36-reads-l15_handle_text_member.rig`, each `h == "abc"` to `?h == "abc"`; no other test, example, corpus probe, or std module compared a handle (emit equivalence over 13,187 programs: only those two and the new tests differ). Tests: `test/reject/types/eq_shared_handle.rig` (`*String == *String`, `*String == String`), `test/reject/types/hash_shared_text.rig` (the review's h03 and h13), `test/behavior/types/eq_shared_through_view.rig` (`?a == ?b` over `*String` and `*P`). `?h` of a field path holding a handle, `?o.h == ?o.g`, is still rejected as a handle comparison: a follow-up if wanted.
- **STD.md:** a view an iterator gives lasts one step of the loop (`keep = e.value` in the loop is rejected, the review's r15); keep a value with `+e.value` or `get`.
- Left as a general follow-up, as decided: a literal that does not coerce to a small-integer view (`f(-1)` for `x: ?I8`).

## Tests

- `test/behavior/types/hash_follows_eq.rig`: equal values hash equal across String, `?String`, `Static`, boxed String, optionals, integer widths, objects, enums, errors, arrays, slices, and generic bodies; the fixed values.
- `test/matrix.py`: a `cmp.*.hash.*` group, 720 cells: for every pairing of view, optional, owner, and element forms at each instance type, `not (a == b) or a.hash() == b.hash()`, or a rejection. Also fixed: the grid spelled a nested optional `Int??`, which Rig rejects, so the `nopt`/`nnopt` cells of `cmp.` were all rejected and never ran; they run now.
- `test/behavior/std/hash_map.rig`: every member over String, Int, `?String`, object, and enum keys, growth to 1,000 keys, taking and putting back, `update`, `clear`, and Set; sanitizer-clean.
- §9's tests: `test/reject/std/hash_get_keeps_lent.rig`, `hash_items_then_put.rig`, `hash_key_no_eq.rig`, `test/reject/types/hash_float.rig`; the STD.md and SPEC examples (the proposal's pending blocks, now ordinary).

## Benchmark

`bench/hash/bench-hash`: a million keys, insert / hit / miss / iterate, Rig `--release` against Zig `-OReleaseSafe` `AutoHashMapUnmanaged` and `StringHashMapUnmanaged`, both on `smp_allocator`. Zig's String keys are built as Rig builds `String("key", i)`, and each Rig loop walks its keys as `map.zig` walks its slices.

This PR's build (no inlining markers), Mac, best of 7, interleaved, load 3.5 (1-minute); ns per operation:

| Keys | Op | Rig | Zig | Rig vs Zig |
|---|---|---|---|---|
| Int | insert | 20.95 | 29.16 | 39.2% faster |
| Int | hit | 6.14 | 10.35 | 68.5% faster |
| Int | miss | 8.75 | 9.71 | 11.0% faster |
| Int | iterate | 0.98 | 4.43 | 352.6% faster |
| String | insert | 65.41 | 98.00 | 49.8% faster |
| String | hit | 30.42 | 44.31 | 45.7% faster |
| String | miss (cold, one pass after the hits) | 17.45 | 15.35 | 12.0% slower |
| String | iterate | 0.97 | 4.43 | 355.6% faster |

String miss, cold and warm side by side (the same map, its miss pass timed once and then again; measured on the build with the inlining follow-up below, load 3.2 to 3.5):

| String miss | Rig | Zig | Rig vs Zig |
|---|---|---|---|
| cold | 18.52 | 16.22 | 12.4% slower |
| warm | 15.57 | 15.42 | 1.0% slower |

Why: Rig's miss path retires fewer instructions than Zig's (83.9 against 85.3 per lookup, from `/usr/bin/time -l` over 40 passes of a million misses). Its probe step is the same 7 instructions as Zig's, the hash is the same Wyhash call on the same bytes, and the `Int?` stays in registers. The cold gap is the entry layout: Rig keeps each key beside its value (about 56 bytes an entry), so the hit pass before it streams about 56 MB against Zig's 24 MB and leaves less of the 2 MB tag table in cache. The same layout is what makes String hit 46% to 60% faster and String insert 50% to 67% faster than Zig. The owner decided to keep it.

**Inlining follow-up** (after the `markers` PR merges): `inline fun find` for the lookups, with a `called fun find_to_add` wrapper for the paths that add a key (inlining `find` there made String insert about 35% slower). On the fair loops it makes Int hit 87.7% and String hit 50.4% faster than Zig, and String miss 8.1% slower cold.

The benchmark found that a short `String("key", i)` has 134 bytes of capacity, which makes reading a million of them about 4 times slower than exactly sized ones: docs/RIG-NOTES.md entry 27, not fixed here.

## Gates

At the head (main merged in at ec659ed03, plus the fair bench loops):

- Suite (`--delta`, on burst): 3730 passed, 0 failed but `style` and `vocab`, which need `.git` and passed on the Mac.
- Corpus (on burst): 10069 passed, 0 failed.
- Matrix (on burst): 12101 programs, 0 failed (7096 ran clean, 5005 rejected), with the 720 `cmp.*.hash.*` cells and the nested-optional cells that now run.
- Unit, vocab, style, and `cli/results_cache` (which had timed out under load on pup) on the Mac: 4/4.
- Oracle sets (in the suite): 5/5.

Emit equivalence: against #206's branch, 0 differ; for the handle change, only the two migrated programs and the new tests differ.

## Owner approvals

- The CORE paragraph below (end of §5, *(built)*).
- Handle rule B: a handle `*T` or `~T` has no `==` and no `.hash()`; content is compared through views, `?a == ?b`.
- Keeping the entry layout, key beside value, with the cold String miss gap above.

The CORE paragraph, at the end of §5, in its own commit:

> **A container written in Rig follows its signatures.** `hash.Map[K, V]` and `hash.Set[K]` are std code with no rule of their own: `!m.put(k, v)` takes `k` and `v` as any owning parameter does; `m.get(k)` returns a `(?V)?` view `from self`, which keeps `m` lent and not `k` (sentence 7); `(!m).edit(k)` returns a `(!V)?` that keeps `m` lent to write; and `(!m).take(k)` hands the value back owned and drops the key. *(built)*
