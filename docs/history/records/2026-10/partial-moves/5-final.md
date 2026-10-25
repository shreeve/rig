# Partial moves: the final CORE text for the owner

The panel was a designer, an adversary and a reviewer, and accepted it with the reviewer's four fixes.

## CORE §5

> **A field of an owned object moves like a name.** A local or
> parameter that owns an object acts as one name per field, and so on
> down, unless a type on the way has a `drop` body. `<p.f` moves `p.f`
> as `<x` moves `x`, and a field that copies takes no `<`. `p.f = x`
> makes a local's field usable again. Where `p`'s scope ends, only the
> fields it still holds drop. Until every moved field is assigned again
> on every path, no use touches all of `p` except `p = x`. *(planned)*

**Sentence 3 adds:** "A partly moved name drops only the fields it still holds."

## What it means, as a desugaring (§10)
- **"Owns" rules out** views, boxes, handles and elements. Owned bindings (`if <o as s`, `match <x`, `for x in <v`) are names too.
- **Closures and defers** follow the rules for names.
- **Optional fields keep today's take,** which leaves `none`.
- **Parameters can't be assigned,** so a partly moved parameter stays partly moved: its other fields can still be used and returned.

## Examples
- **Pending:** `v = <e.value`, `print(e.key, v)`, `e.value = String("w")`, `print(value_of(<e))`, printing `k v` then `w`.
- **Rejects:**
  - `v = <e.value; f = <e`: "`e` is partly moved: `e.value` was moved out; assign it first";
  - `print(e)` after `<e.value`;
  - `<f.name` of a `File` with `drop(!@)`: "`File` has a `drop` body, which expects every field".

## Build
- About 500 lines: ownership (per-path moved state), storage (a drop flag per moved path, a recorded fact), emit (reads it), and the oracle (`flow.zig` per path, first, with a sanitizer case for each of the adversary's 13 holes).
- 9 test expectations flip. The Lean model has no fields; recorded as a gap.

## Value
- **Removes Trig workarounds:** about 82 of Trig's 111 `swap(!x.f, empty)` sites on owned locals, and 3 optional fields that exist only to be taken (Trig's NEEDS 26).
- **std has none.**
- **Mostly setup code:** clearer, not faster.
- **The 24-byte Map slot isn't counted on:** that layout measured slower before.

Reports: 1-design.md, 2-adversary.md, 3-draft.md, 4-review.md, 4-census.txt.
