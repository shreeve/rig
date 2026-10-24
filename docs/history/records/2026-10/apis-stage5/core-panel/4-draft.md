# Shared and crossing API objects: the combined Core draft (Rig (OG), from PR #615's core-draft.md, the adversary (3-adversary.md), and the compiler implementer (2-compiler.md))

## §1: one row widened
| **handle** | `*T` (counted; `*{A}` too), `~T` (weak; `~{A}` too), owned closures (`*fun`) | moves; `+h` adds a count | built; `*{A}`, `~{A}` planned |

## §4: one row widened
| `*T`, `*{A}` | the read views of `T`; of a `*{A}`, the `?{A}` it holds | nothing of the value (`!h` lends the handle itself) | built; `*{A}` planned |

## Sentence 8, after "…(`^*T`, `**T`, `*~T`) is rejected"
> ; an API object is held the same three ways, `^{A}`, `*{A}`, and `~{A}` (§4).

## Sentence 9, after "its handles are counted atomically and go to any task"
> , and erased they are a `*{A + Syncs}` (§4)

## Stage 4's list, last line
"`*{A}` and `~{A}` are Stage 5's." becomes "`*{A}` and `~{A}` count, and an API object crosses, as below."

## The paragraph, after Stage 4's

> **A shared API object counts a value of hidden type, and an API
> object crosses tasks only by a bound in its braces.** `*{A}` is a
> counted handle to a value of some type that provides `A`. A `*T`
> moves into a `*{A}` and keeps its allocation, and a frozen value's
> handle moves only into a `*{A + Syncs}`; neither form becomes the
> other, and erasing only moves or counts a handle, never the type of a
> place it is lent from. Like every handle it only reads: a call
> through it reaches `?@` methods, `?s` lends the `?{A}` it holds, and
> `+s` adds a count, atomic exactly when it syncs. `~{A}`, the weak
> handle of a `*{A}` that does not sync, carries the same loans. Either
> carries the loans of what it holds until its last count is dropped.
> `Sends` and `Syncs` in the braces, or in the API they name, are facts
> of the hidden value, checked where its type is erased, and a type
> parameter's by its bounds, as `Owned` is. Each form then crosses as
> its kind does: a box or a write view goes to another task when its
> value sends, and a box, a read view, or a `*{A + Syncs}` is read by
> several tasks when its value syncs. An API object whose braces and
> API name no such bound goes to no task, a local one included, at any
> depth of what the task is given, and no API object hides a task.
> *(planned)*

## How each hole is closed

| Hole | Rule |
|---|---|
| **A1:** a weak handle of a frozen value races | a frozen handle erases only to `*{A + Syncs}`; `~{A}` exists only for a `*{A}` that does not sync |
| **A2:** `Syncs` in a generic with a plain `*T` | the holding follows from the braces: `*{A}` is plain, `*{A + Syncs}` frozen; neither becomes the other |
| **A3:** made local, not rejected | "goes to no task, a local one included, at any depth"; SPEC §18's local-task list gains it (the compiler's `blockerIn` already rejects; the SPEC wording is fixed in the generic-`T` PR) |
| **A4:** a weak handle with no loan | `~{A}` carries the same loans |
| **A5:** variance through `!*{Shape}` | erasing only moves or counts a handle, never the type of a place |
| **A6:** `Sends` is not `Owned` | unchanged: without `Owned`, an API object may hold anything |
| **A7:** `*fun` as an object | phase 4 changes only lowering; the crossing row stays "never" |
| **Stage 4:** a `T` hiding a `Task` | a per-instance `no_task` (in the generic-`T` PR) |

## Examples (from #615's core-draft)
1. A `*{Shape}`, its weak handle, and the last drop: prints `4.0` then `gone`.
2. A frozen value as `*{Shape + Syncs}`, read by two tasks: prints `8.0`.
3. A `^{Job + Sends}` given to a task: prints `6`.
4. Rejected: `*Square` into `*{Shape + Syncs}`, "…its count is not atomic: freeze the value, `*Frozen(...)`".
5. Rejected: `^{Job}` given to a task, "…without naming `Sends`: write `^{Job + Sends}`".

## SPEC §18 rows
| Type | sends | syncs |
|---|---|---|
| `?{A}` | when `Syncs` | when `Syncs` |
| `!{A}` | when `Sends` | never |
| `^{A}` | when `Sends` | when `Syncs` |
| `*{A}` | never | never |
| `*{A + Syncs}` | yes | yes |
| `~{A}` | never | never |

## Build (compiler)
- `sema.objectBounds` is the one classifier for an API object's bounds.
- `eraseShared` sits beside `eraseBox`.
- The table gains drop, clone and weak entries per holding, at 3 words per table; a `*{A}` is 16 bytes.
- Phase 1 is about 1,000 lines and phase 2 about 1,400.
- Phase 4 (`*fun` as an object) is its own performance PR.
