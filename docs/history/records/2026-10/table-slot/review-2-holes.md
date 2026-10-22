# Table/Slot: second review, against 6fde90632 (table-slot)

- **Probes:** `review-table/p2/`.
- **Result:** all nine holes from HOLES.md are closed. No new hole lets
  safe code corrupt memory. Four smaller findings follow, ranked.

## N1 (low). A `Slot[0]` value through a generic table element

`p2/h4b.rig`:

```rig
fun z[n: Int]() -> Int
  t = Table[Slot[n], 4]()
  s: Slot[4] = 2
  Int(t[s])
sub main()
  print(z[0]())       # prints 0: a Slot[0] holding 0
```

- **Inconsistency:** written directly, `Table[Slot[0], 4]` is rejected
  ("`n` is at least 1"), but a generic instance that puts `Slot[0]` in a
  table element is not.
- **Why it is harmless today:** no `Table[_, 0]` can exist, and a Slot
  indexes nothing else. Arrays and Lists reject a Slot index.
- **Why it still matters:** the invariant "every `Slot[n]` is below `n`"
  is false for this instance.
- **Fix:** apply the `1 <= n` rule to every `Slot` instance that a
  generic instantiation reaches, not only to the ones written.

## N2 (low, pre-existing; North Star 1). `match` on a List or Table element emits Zig that fails

`p2/f6.rig` (List, on main as well) and `p2/f7.rig` (Table):

```rig
m = match v[0]
  _ => 1
```

Zig reports `unused local constant` for `__rig_subject_N`. Not caused by
this change.

## N3 (usability). `n` is not inferred from a `Slot[n]` argument

`p2/x5.rig`: given `fun id[n: Int](s: Slot[n]) -> Int`, the call
`id(s)` fails with "cannot infer `n`". Inference does work from a
`Table[T, n]` argument.

## N4 (weak spot, North Star 4). Emit chooses `constSlot` or `slot` itself

- **Where:** `emit.zig`, the table index. The choice comes from
  `read_place`, `as_place`, and `throughReadView`, not from a recorded
  fact.
- **Why it matters:** in the committed (fallback) lowering this choice
  is what keeps a read from growing the table. A read emitted as
  `slot()` while tasks share `?t` would reallocate under them.
- **Read forms tried:** method calls, `?t[s]`, `match` on a field, `for`
  over a field, and reads through `?Store`. All emit `at` or
  `constSlot`.
- **The one read that emits `slot()`:** the subject of a non-scalar
  `match` (`p2/f7.rig`: `&t.slot(s).*`).
  - It only occurs on made tables, since a committed table's elements
    cannot be such subjects, so it is unreachable today.
  - **Fix:** record the access kind as a fact.
