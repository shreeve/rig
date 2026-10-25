# Partial moves: the combined draft (Rig (OG), from 1-design.md and 2-adversary.md)

## CORE §5, replacing "and any other place is rejected, a part of a value made there too"

> …and any other field of an object that a local or a parameter owns
> moves out, leaving it partly moved: neither that field nor the whole
> value is used until the field is assigned again, on every path, and
> its other fields are. Where its scope ends, and where the field or the
> whole value is assigned, only the fields still held drop. No field
> moves out of a type with a `drop` body, or through a view, a box, a
> handle, an element, or an optional's value, anywhere along its path,
> and no `defer` moves or assigns one; any other place, a part of a
> value made there too, is rejected. *(planned)*

**Sentence 3 adds:** "A value partly moved drops the fields it still holds."

## The rules (the adversary's holes, numbered)
1. **A flag per moved path** in the owner's scope, cleared at the move. A scope exit (and `!`, `break`, `return`), `p.f = x`, and `p = x` drop only the parts still held (holes 1–3).
2. **Whole uses are rejected until every moved path is assigned whole on every path:** `?p`, `!p`, `?@`/`!@` methods, passing, `+p`, `<p`, `return p`, a last value, `match p`, `swap`, captures, and `defer` uses (hole 4).
3. **Nested `<p.a.b`:** `p.a.c` stays usable and `p.a` doesn't; `p.a = x` drops what `p.a` still holds; a write below the hole is rejected (hole 5).
4. **No `drop` body on the path,** from the root down to the moved field's parent (hole 6).
5. **`<p` then `p.a = x` is rejected:** no live value with holes (hole 7).
6. **Never through** views, `!@`/`drop` self, handles, `*Frozen`, `if as` subjects, `match` payloads, elements, `Table`, `error`, or boxes `^T` (box fields wait for a later version) (holes 8–9).
7. **Closures:** only an exactly-once closure may move a captured field; `defer`/`errdefer` never move or re-assign a part (hole 10).
8. **Optional fields keep today's take,** which leaves `none` (hole 11).
9. **Generics and tasks:** safe; the flag is a no-op for a copy (hole 12).

## The oracle and Lean (hole 13)
Before this lands, `test/oracle/flow.zig` tracks moves per path, not per var, and gets a sanitizer case per hole. λRig's gap is recorded: it has no fields, so a lemma waits for field modelling. That's non-gating, but stated.

## Examples (from 1-design.md)
- **Pending:** `v = <e.value`, `print(e.key, v)`, `e.value = String("w")`, `print(value_of(<e))`, printing `k v` then `w`.
- **Rejects:**
  - `v = <e.value; f = <e` gives "`e` is partly moved: `e.value` was moved out; assign it first";
  - `<f.name` of a `File` with `drop(!@)` gives "`File` has a `drop` body, which expects every field".

## Build
About 500 lines: ownership (per-path moved state), storage (a per-path drop flag, a recorded fact), emit (reads it), the oracle (flow per path), and 9 test expectations that flip.

## The honest payoff
- **Ergonomics:** you can take one field without restructuring the object.
- **The 24-byte Map slot** needs this plus the write-view fix. But the backlog measured that layout 12% slower on Trig's ts-pattern, with 41% more memory, so its speed payoff needs measuring again and isn't assumed.
