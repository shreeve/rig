Trig's binder can now hold a Map or Set as a field with an empty default, and read its size as a field:

```rig
use std.hash

obj Binder
  symbols: hash.Map[U32, U32] = hash.Map[U32, U32]()
  seen: hash.Set[U32] = hash.Set[U32]()

sub main()
  b = Binder()
  !b.symbols.put(1, 10)
  print((!b.seen).add(1), b.symbols.len, b.seen.len)
```

The owner's decisions of 2026-10-15, built as general rules, not Map special cases.

## The empty constructor `T()`

An object whose every field has a default is made empty with `T()` from any module, private fields included, since `T()` sets only values the type itself chose. It is a field default too, as `List()` is, and it works for a generic object (`hash.Map[K, V]()`, `lib.Pile[Int]()`). Construction with fields given from another module still needs every field to be `pub` (and not read-only, below).

- `construct` skips the construction visibility check for `T()` when every data field has a default (`everyFieldDefaulted`, a positive rule), and `isConstructorDefault` accepts `T()`, `lib.T()`, `T[A]()` and `lib.T[A]()` of such a type (`emptyConstructor`).
- `T()` of a foreign type with a field that has no default is rejected with the field named: `` `lib.Half()` makes a `lib.Half` from its fields' defaults, and `size` has no default; … ``.
- Not as a parameter default: those stay literals and constants.

## Read-only public fields, `pub ?name: T`

The `?` is the read sigil: any module reads the field, lends it to read, and walks it; only its own module writes it.

- **Grammar:** a member `?name: T` (or `= v`) parses as a read sigil around the field, and `pub` wraps it, so the change is two member alternatives with no new conflict. `?name: T` without `pub` is rejected ("only a `pub` field allows" it). Nexus needs a re-sync of `rig.grammar`.
- **One classifier:** "this field is read-only to this module" is decided once, in typecheck's `dataField` (`noteReadOnly`), and recorded as a fact (`Facts.read_only_fields`, keyed by the member access). `placeOf` reads it and blocks the place (`Block.read_only`), so every write path that goes through `requireAccess` rejects it with one message: assignment, compound assignment, `!` lends (a write argument, `swap`, `replace`, a `!self` method call), `<` take, a writing `for`, a writing header (`if !t.mode as m`), through a box and through a write view. A part of the field (`t.inner.n`) is blocked by the same step.
- **Construction:** a read-only field counts as one only its module sets, so `lib.Tally(count: 5)` from another module is rejected; `lib.Tally()` makes one from defaults. The owner confirmed this strict reading.
- Read-only stops at a shared handle: with `pub ?h: *Cell[Int]`, `!t.h.set(5)` changes the shared Cell, since a handle is only read (SPEC §14; `test/behavior/modules/read_only_field_handle/`).
- A visibility rule, not an ownership one: no CORE change.
- Docs: SPEC §14 (with a `tally` example and a reject example), SPEC §3 Objects (`T()` as a field default), SYNTAX (the member form and the grammar summary).

## Map and Set

- Every private field has a default; `hash.Map[K, V]()` and `hash.Set[K]()` are empty ones (`new()` stays, and returns that).
- The stored count is `pub ?len: Int`; Set keeps its own in step with its Map's.
- `m.len()` is a compile error pointing at the field. The message is general, for any object: `` `len` is a field of `hash.Map[String, Int]`, not a method: write `m.len` ``.
- Migrated: `test/behavior/std/hash_map.rig`, `test/reject/std/hash_key_no_eq.rig`, `test/reject/types/hash_float.rig`, `bench/hash/map.rig`, docs/STD.md. No example, corpus probe, or other std module called a Map's or Set's `len()`. `List.len` is unchanged.

## Tests

- `test/behavior/modules/read_only_field/`: reads, read lends, a walk, a header, writes through the module's own methods, a box, and a plain `pub` field still written.
- `test/reject/modules/read_only_field_writes/`: each write path from another module, 13 errors.
- `test/reject/types/read_only_field_without_pub.rig`.
- `test/behavior/modules/empty_constructor/`: a foreign object with private defaulted fields as a local and as a field default (fresh per value), and a generic one.
- `test/reject/modules/empty_constructor_needs_defaults/`: a field with no default; explicit fields of a type with a private one.
- `test/reject/std/hash_len_read_only.rig`; `test/behavior/std/hash_map.rig` gains a field default of each and `len` reads.

## After the review

- A field default `h: lib.Half = lib.Half()` names the field with no default (`size`), as the local case does.
- Calling a field that holds an optional function says to take the function out first (`if h.f as g`), not that it is a field.
- A header over a read-only field (`if t.boxed as b`) no longer suggests the write form, which the field rejects too.
- The review's twelve probes are kept as `test/corpus/rev227-*`, each with its `# error:` or `# expect:`.

## Gates

At 40137095d (origin/main 77d26590f merged in), before the review's nits:

- Suite (`--delta`, on burst): 3797 passed. 3 failed, none real: `vocab` and `style` need `.git` and passed on the Mac, and `cli/match_scale` is a timing test that failed under burst's load and passed rerun alone.
- Corpus (on burst): 10091 passed, 0 failed.
- Matrix (on burst): 12629 programs, 0 failed (7495 ran clean, 5134 rejected).
- On the Mac: unit, vocab, style, and the new tests pass.
- Equivalence (`test/equiv.py` against main's compiler, 13,294 programs and doc blocks): 21 differ, and none in emitted Zig. The new tests, `std/hash.rig`, and the four programs that use a Map's `len` differ only in `check` output and facts. Five existing rejection tests and corpus probes differ in their message only: the field-default message now names `T()`, and a call of a data field says it is a field. (`test/equiv.py` on main can't write a doc example's directory modules or read non-UTF-8 output; I ran markers' fixed copy without committing it.)

Trig: if Trig's tree calls a Map's or Set's `len()`, it needs `.len` after this lands.

After the nits and merging main at 68964c536 (#224's `called`/`rarely` markers; the grammar merged with no conflict): the full suite on the Mac, `--delta`, 3823 passed, 0 failed.
