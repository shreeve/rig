# Partial moves: design (designer)

## The rule
`<p.f` of a non-optional field of an object a local owns (a local, an owned parameter, or `<@`) leaves `p` **partly moved**. Uses of `p.f` are rejected until it is assigned again. Other fields stay usable. Whole uses (`p`, `<p`, `?p`, `!p`, `+p`) wait until every moved field is back. `p = x` drops the unmoved fields. At the scope's end only the unmoved fields drop, last first.

Exceptions:
- **A `drop` body on the path:** rejected, as Rust's E0509, because the body expects every field.
- **Views:** never moved through. `!p` allows `swap` and take only.
- **Boxes:** rejected; write `<b.unbox()`.
- **`<p.a.b`:** allowed when every step is held by value, and it leaves `p.a` and `p` partly moved.
- **Elements, handles, captures, made values:** still rejected. An optional field still takes, leaving `none`, and `p` stays whole.
- **Generics:** a `T` field moves. A generic object has no `drop` body, so the check is decided once.

## CORE (§5, replacing "and any other place is rejected, a part of a value made there too")
> …and any other field of an object a local owns is moved out, leaving the local partly moved: neither that field nor the whole local is used until the field is assigned again; its other fields are, and where its scope ends only they drop. No field leaves a type with a `drop` body, or goes through a view, a box, a handle, or an element; any other place, a part of a value made there too, is rejected. *(pending)*

Sentence 3 adds: "one partly moved drops the fields it still holds."

```rig pending
obj Entry
  key: String
  value: String

fun value_of(e: Entry) -> String
  <e.value

sub main()
  e = Entry(key: String("k"), value: String("v"))
  v = <e.value
  print(e.key, v)
  e.value = String("w")
  print(value_of(<e))
```
```output
k v
w
```
Two rejects:
- `v = <e.value; f = <e`: "`e` is partly moved: `e.value` was moved out; assign it first".
- `<f.name` of a `File` with `drop(!@)`: "`File` has a `drop` body, which expects every field".

## Compiler (~500 lines)
- **ownership:** `Flow.parts` (path, at), joined by union and compared at the fixpoint. `movePart`'s last branch becomes `moveField`. `checkLive` becomes path-aware (`Paths.overlap`). Assigning a path clears the parts within it.
- **storage:** `field_moves: sym → [path]`, recorded once, under `consumed`'s contract.
- **emit:** a flag per recorded path. `<p.f` is `rig.take(&flag, p.f)`, and an assignment drops behind the flag. The scope's defer drops fields in reverse order, the recorded ones behind flags. Emit decides nothing.
- **oracle:** C3's "only a whole binding moves" becomes a path move, and C1 checks overlap.
- **cases:** 9 expectations flip. New cases cover branch, loop, nested paths, `<@`, generics and drop order, plus 5 rejects.

## Unlocks
A Map slot `{key, value, order: U32}`, as a niche-sized `Slot?`, with `take` as `if <@slots[j] as s` then `return <s.value`. That makes 24 bytes, once `edit`'s write-view fix also lands. Measure again: the backlog found it slower on Trig. Also `(<@)` methods that return one field, and `match <p.e`.

Unchanged: elements, `Entry.value: V?`, views' swaps, kinds, and code with no field moves.
