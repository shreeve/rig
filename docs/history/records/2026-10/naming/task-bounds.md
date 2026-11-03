# Naming: the two task bounds `Moves` and `Shares` (for the owner)

**Status:** the owner renamed the bounds to `Sends` and `Syncs`, not this
note's first choice; his decision and why are in
[apis-stage3/naming-sends-syncs.md](../apis-stage3/naming-sends-syncs.md),
and `tools/rename-task-bounds.py` migrates programs.

**The concern (raised by another AI, relayed by the owner).** In Rig, "moves"
already means something to the ownership checker: a value that moves rather
than copies (SPEC §7 has a section called "Moves"). The bound `Moves` means
something else, "may go to another task". So `[T: Moves]` reads like "T is a
type that moves", which every owner already is. `Shares` has the same problem
to a lesser degree: Rig also has `*Shared` handles.

**Cost of a rename today: none.** Both are built (Stage 2, SPEC "Bounds"), but
nothing uses them: no std module, no example, and none of Trig's code. The
only references are the compiler's own list (`src/rig.zig`, `resolve.zig`,
`sema.zig`), SPEC (6 lines), and docs (63 lines, mostly docs/design/apis.md
and its panels). Stage 5 (`^{Job + Moves}`) is the first form to put them in
programs, so renaming now is free and renaming later is not.

## Candidates

### A. `Sends` and `Shares` (recommended)

```text
fun spawn_all[J: Job + Sends](jobs: List[J])
queue: List[^{Job + Sends}] = List()
```
Error: `` `Conn` cannot be sent to another task: its field `buf` is a view (`?String`) ``
Sentence: "A `T: Sends` may be sent to another task; a `T: Shares` may be read by several at once."

- "Send" is the plain word for handing a value to another task: channels already `send`, and Rust's `Send` means exactly this.
- It never clashes with `<`, a move.
- apis.md once set `Sends` aside, on the grounds that every owner moves, so the bounds should say where to. That argument was against `Move`, not against `Sends`.

### B. `Crosses` and `Shares`

```text
fun spawn_all[J: Job + Crosses](jobs: List[J])
```
Error: `` `Conn` cannot cross to another task: its field `buf` is a view ``
Sentence: "A `T: Crosses` may cross to another task."

- SPEC and the compiler already say "cross to another task" (`crossingTypeOf`), so this matches the error wording.
- The word is less familiar to newcomers.

### C. `Send` and `Sync` (Rust's words)

```text
fun spawn_all[J: Job + Send](jobs: List[J])
```
Error: `` `Conn` is not `Send`: its field `buf` is a view ``
Sentence: "A `T: Send` may go to another task; a `T: Sync` may be read by several."

- These are known to Rust programmers.
- `Sync` is opaque to everyone else, and the other built-in bounds are third-person verbs (`Moves`, `Shares`) or adjectives (`Owned`), so these break the pattern.

### D. Keep `Moves` and `Shares`

- No change.
- The clash with the "Moves" section of SPEC §7 stays, and `[T: Moves]` keeps reading as "T moves".

## Default

**A: rename `Moves` to `Sends` and keep `Shares`.** `Shares` reads as "may be
shared (read) by several tasks", and `*Shared` is a handle, not a bound, so
the clash is mild.

This is a one-PR rename: the compiler's list and messages, SPEC, the docs and
panels, and a CHANGELOG line. No program needs migrating, and Trig gets a
one-line note.

If approved, it lands before Stage 5, ideally beside Stage 3, so that every
API document uses the final name.
