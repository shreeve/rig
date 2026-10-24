# Shared and crossing API objects: the final CORE text for the owner (panel accepted with the reviewer's three fixes)

## §1: the handle row widened
| **handle** | `*T` (counted; `*{A}` too), `~T` (weak; `~{A}` too), owned closures (`*fun`) | moves; `+h` adds a count | built; `*{A}`, `~{A}` planned |

## §4: the `*T` row widened
| `*T`, `*{A}` | the read views of `T`; of a `*{A}`, the `?{A}` it holds | nothing of the value (`!h` lends the handle itself) | built; `*{A}` planned |

## Sentence 8 and sentence 9, a clause each
- **Sentence 8:** "; an API object is held the same three ways, `^{A}`, `*{A}`, and `~{A}` (§4)."
- **Sentence 9:** ", and erased they are a `*{A + Syncs}` (§4)".

## Stage 4's list, last line
"`*{A}` and `~{A}` are Stage 5's." becomes "`*{A}` and `~{A}` count, and an API object crosses, as below."

## The paragraph and list, after Stage 4's

> **A shared API object counts a value of hidden type, and an API
> object crosses tasks only by a bound it names.** `*{A}` is a counted
> handle to a value of some type that provides `A`, and `~{A}` is its
> weak handle. A `*T` moves into a `*{A}`, keeping its allocation, and
> a frozen value's handle only into a `*{A + Syncs}`. A handle is erased
> only as it moves or counts, never through a view. Like every handle,
> it only reads: calls reach `?@` methods, `?s` lends the `?{A}` it
> holds, and `+s` adds a count. Both forms carry the loans of what they
> hold until the last count is dropped. *(planned)*
>
> - `Sends` and `Syncs`, in the braces or the API, are facts of the
>   hidden value, checked where it is erased (a type parameter's by its
>   bounds), as `Owned` is.
> - A box or a write view goes to another task when its value sends. A
>   box, a read view, or a `*{A + Syncs}` is read by several tasks when
>   its value syncs.
> - A `*{A + Syncs}` holds only a frozen value: it counts atomically,
>   has no `~`, and names no `Owned`.
> - An API object without the bound a task needs goes to no task, a
>   local one included, at any depth.
> - No API object, and no owned closure, holds a task.

## The reviewer's fixes, folded in
1. **No owned closure holds a task.** `*|<t| 7` hid a task from `task.isolate` (probed); a closure's captures are now walked.
2. **A frozen value may hold `*{A + Syncs}` handles,** which sentence 9 already allows. So `*Frozen(List[*{Plugin + Syncs}])`, a shared plugin registry, works. This replaces open question 16.
3. **`Owned` is rejected inside `*{A + Syncs}`,** so there's one spelling.

## Real programs
- **A job queue** (`^{Job + Sends}`) works.
- **A shared plugin registry** works.
- **A GUI's render task** over a `*{Widget}` tree is rejected, the cost of question 13. A `*Widget` tree, or a frozen `*{Widget + Syncs}` tree, works. This is recorded as a limit.

## Examples
These are the five from #615's core-draft:
1. weak handle and last drop;
2. two tasks reading a frozen value;
3. a sending job;
4. a non-atomic `*T` rejected as `Syncs`;
5. an unbounded `^{Job}` rejected for a task.

Panel reports: 2-compiler.md, 3-adversary.md, 4-draft.md, 5-review.md (this folder).
