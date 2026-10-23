# The task bounds are `Sends` and `Syncs` (2026-10-23)

The owner's decision: "let's go with Sends and Syncs -- this lines up
with Rust also".

## Why

`<x` moves and `*x` shares within one task. The built-in bounds `Moves`
and `Shares` meant something else: a type may go to another task, and a
type may be read by several tasks at once. Reusing the sigils' words
made a bound read as the sigil. `Sends` and `Syncs` are Rust's `Send`
and `Sync`, which mean exactly those two.

## The two meanings differ

| Value | `<` or `*` within a task | Crosses to another task |
|---|---|---|
| `List[*Node]` | moves with `<` | not `Sends` |
| a `!T` view | cannot be `<`-moved | `Sends` |
| `*<Node(...)` | shared by `*` | not `Syncs` |

Rust's `&T: Send` if and only if `T: Sync` matches SPEC's "`?T` crosses
when `T` syncs".

## What changed

- `rig.Api` members `Moves` and `Shares` became `Sends` and `Syncs`,
  with every reference in `src/`.
- The old names are rejected with a hint: "`Moves` is now `Sends`" and
  "`Shares` is now `Syncs`" (`resolve.renamedApi`), tested in
  `test/rig/types-apis.rig.test`.
- SPEC's Bounds table and prose, `docs/design/apis.md`, the learn guide,
  INTERNALS, and the CHANGELOG. SPEC's section "Moves", about `<`, keeps
  its name.
