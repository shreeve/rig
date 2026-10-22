# Rig spelling for Trig

Trig writes the spelling of Rig's main branch (now v0.3.0's) and moves to each new Rig
release with Rig's migration script. Code in a spelling the compiler doesn't
support yet can't be checked, so Trig never writes ahead of main.

## On Rig main now (enforced by a current `bin/rig`)

- A statement `<x` drops `x` now; `-x` only negates.
- An operator has the same spacing on both sides (`a < b`, never `a <b`),
  and there is no space before a call's `(` or an index's `[`.
- A write call whose value is used is parenthesized: `(!v).pop()`.
  `_ = !v.pop()` stays short.
- `not` before a comparison needs parentheses: `not (a > 3)`.
- A lend kept past its statement is written: `r = head(?v)`,
  `!xs.push(head(?v))`.
- A `Cell` lives only behind `*` (`*Cell(0)`) and changes only by a marked
  call (`!c.set(5)`).
- A write view is never stored inside a value: no `!T` fields or elements.
- `Static` is literal text that carries no loan.

## Rig v0.3.0 spellings (adopted)

Trig moved to these with Rig's `tools/migrate-0.3.py` (recorded in
`.rig-migrated-0.3`):

| Before | Now |
|---|---|
| `Box[T]`, `Box(x)` | `^T`, `^Node(…)`, `^<x` |
| `Vec[T]`, `Vec()` | `List[T]`, `List()` |
| `Text` (owned) | `String` |
| `String` (read view) | `?String` |
| `Static` | `Static` |

The full table is in the body of shreeve/rig#109.

## Objects and bits (Rig main b124d543)

- A record type is declared `obj Name` (was `struct Name`, now rejected).
  Trig moved with a one-line substitution, since the migration tool's
  `obj` mode is being fixed (Rig's `migfix2`).
- A deeper-indented line that starts with `.` continues the statement
  above, when that statement opens no block.
- `x.not()` is the bitwise complement; `~` stays the weak sigil.

## Loops (Rig main cbed98f8)

- `for x in !it` advances an iterator that is a place; the bare form is
  `for !it`. A made iterator stays bare: `for w in s.words()`.
- A bare `for` binds nothing: `for 0..2` runs its body twice. There is
  no implicit `it`.

Every Trig file is 0.3: `migrate-0.3.py apply` (Rig 5b148806 or later)
reports each as already migrated or `CURRENT` and changes nothing.
