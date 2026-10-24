# Reviewer: Stage 5 Core text

## Holes

1. **An owned closure hides a task (open).** `holdsTask` reads no captures, so question 14's walk misses `*|<t| 7` in an object, and out of `task.isolate` it runs (probed). *Fix:* an owned closure never captures a task (SPEC §7, §18).
2. **Question 16 over-restricts:** a `*{A + Syncs}` is "another frozen value's" handle (sentence 9). *Fix:* allow it, so `*Frozen(List[*{Plugin + Syncs}])` works.
3. **Two spellings:** reject `Owned` in `*{A + Syncs}` (question 4).

**Probed sound:** a drop on another worker, a `*{B + Syncs}` in a `^{A + Sends}`, a one-word `Cell`, `select`, actors, `par.each`, and `Sends` without `Owned`.

**`api Shape: Syncs`**: every `*{Shape}` is frozen-only. Keep it, since a holding from the braces alone splits `blockerIn`. The error names the API.

## Revised text

> **A shared API object counts a value of hidden type, and an API object crosses tasks only by a bound it names.** `*{A}` is a counted handle to a value of some type that provides `A`, and `~{A}` is its weak handle. A `*T` moves into a `*{A}`, keeping its allocation, and a frozen value's handle only into a `*{A + Syncs}`. A handle is erased only as it moves or counts, never through a view. Like every handle, it only reads: calls reach `?@` methods, `?s` lends the `?{A}` it holds, and `+s` adds a count. Both forms carry the loans of what they hold until the last count is dropped. *(planned)*
>
> - `Sends` and `Syncs`, in the braces or the API, are facts of the hidden value, checked where it is erased (a type parameter's by its bounds), as `Owned` is.
> - A box or a write view goes to another task when its value sends. A box, a read view, or a `*{A + Syncs}` is read by several tasks when its value syncs.
> - A `*{A + Syncs}` holds only a frozen value: it counts atomically and has no `~`.
> - An API object without the bound a task needs goes to no task, a local one included, at any depth.
> - No API object, and no owned closure, holds a task.

## Real programs

A job queue and a plugin registry (after fix 2) work. A GUI's `render(?root)&` over a `*{Widget}` is rejected, though a `*Widget` tree works. This is question 13's cost: record it as a limit.

## Verdict

Sound once fix 1 lands. Approve with fixes 1 to 3 and this text.
