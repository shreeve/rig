# Partial moves: review

## Holes
1. **Copying fields:** the new text drops "a field that copies takes no `<`", so `m = <p.n` would pass. *Fix:* keep that clause.
2. **Rule 6 bans by origin:** it bans the design's own unlock, `if <@slots[j] as s` then `<s.value`, against §10. *Fix:* ban only views; owned bindings (`if <o as s`, `match <x`, `for x in <v`) are names.
3. **Rule 2 is a list, and it leaks:** `<p.a; print(p)` reads the hole, as do `p == q` and `String(p)`. *Fix:* §5's word: no use touches all of `p` except `p = x`.
4. **Parameters are immutable:** a partly moved one never becomes whole (probed). *Fix:* promise re-assignment only for a local's field.

**Sound:** `match p.e` (probed: the moved value drops once); `Copy`-bounded generics; enum payloads; `<p.o.x`; loops; tasks; `errdefer`. `if !@slots[j] as s` then `<s.value` is rejected, since `s` is a view.

## Text (§5)
> **A field of an owned object moves like a name.** A local or parameter that owns an object acts as one name per field, and so on down, unless a type on the way has a `drop` body. `<p.f` moves `p.f` as `<x` moves `x`. `p.f = x` makes a local's field usable again. Where `p`'s scope ends, only the fields it still holds drop. Until every moved field is assigned again on every path, no use touches all of `p` except `p = x`. *(planned)*

Sentence 3 adds: "A partly moved name drops only the fields it still holds." A desugaring (§10): "owns" rules out views, boxes, handles and elements; closures and defers follow name rules. Rules 6–7 go.

## Workarounds removed (4-census.txt)
- **Trig: about 82** `swap(!x.f, empty)` sites on owned locals, out of 111.
- **Trig: 3** optional take-hole fields (NEEDS 26), plus `empty_file()`.
- **std: 0.** Every `swap` there goes through `!@` or an element.

Mostly setup code: easier, not faster.

## Verdict
Worth it, as Trig's NEEDS 26, without counting on the Map slot. Land it with this text and fixes 1–4, per-path oracle first, after the feature in flight.
