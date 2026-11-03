# Expert: users and launch

| Candidate | Verdict | Default | Reason |
|---|---|---|---|
| Weak handles `~T`, `~x`, `\|~x\|`, `*w` | **keep** | keep | The only one-character fix for the one leak Rig admits (a cycle of `*T`). Learn 01 and 02 teach it as a core idea; the launch post's sigil table lists `~x`; `examples/memo_canary.rig` and `examples/static_status.rig` use `\|~x\|`, so the census's 0 for examples is wrong. A `Signal` that tells a subscriber reading the signal needs it. |
| `^{A}` | **keep** | keep | The heterogeneous list (`List[^{Shape}]`) is the API demo in README, Learn 08, and Learn 04 (`^{Job + Sends}` to tasks). Plugins, handlers, and widgets need it; Go programmers live on interfaces, Rust on `Box<dyn>`. |
| `*{A}` | **keep but freeze** | freeze | `*{Shape + Syncs}` with `*Frozen` is taught (Learn 08, the Learn 04 summary table); a shared registry of handlers in a server uses it. It is rare, but follows from the grid. |
| `~{A}` | **keep but freeze** | freeze | Swift's `weak var delegate: P?` is this exact form. Rig's closures with `\|~x\|` cover most delegates, but rejecting the case where `~` meets `{A}` would break the sigil grid, which an AI or a new user expects to compose. |
| `*Frozen[T]` | **keep** | keep | `Arc<Config>` is the commonest `Arc` in Rust servers. A scoped task can take a `?` loan, but an owned closure (`http.serve`'s handler, an actor) cannot, so config shared across requests needs a handle that `Syncs`. Learn 04 teaches it; servers are the second audience. |
| `once ?fun` | **keep but freeze** | freeze | Library authors use it (`within`, retry, guards that let a closure move what it captured); users call such functions without writing the form. It is not in Learn and hard to misuse. |
| Boxes `^T` | **keep** | keep | Recursive data (trees, ASTs, linked lists) is what Python and TS programmers write first. Learn 01 (`^Note?`), Learn 11, and `examples/tree.rig` (on nine lines) rely on it. Without it they need `Table`/`Slot` and indices for a first tree. |
| `api` / `add T: A` | **keep** (freeze new stages) | keep | `^{A}` needs them; Learn 08 is a whole chapter. Hold the planned stages (`^{Source[Item: Int]}`) until a program needs them, as Learn 08 already says. |

## Who needs each beyond Trig

Trig is a compiler written arena-style: tables, slots, indices, no back pointers. That is the one kind of program that needs none of these. The census measures Trig's style, not what Rig's users need.

- **GUIs, reactive state, observers.** A child points at its parent, and a callback refers back to its owner. Swift code is full of `[weak self]` and `weak var delegate`. Rig's `Signal` plus `|~x|` is that idiom, and the leak checker turns a missing `~` into an error at exit. Python and TS programmers never think about cycles, because their GC handles them. They will write the cycle, see the leak, and need a fix that costs one character. Cut `~`, and the fix becomes a rewrite into `Table`/`Slot`.
- **Plugins and heterogeneous collections:** `^{A}`. Zig makes you build the vtable by hand (`std.mem.Allocator`), which is exactly what Rig's audience wants hidden.
- **Servers and actors:** `*Frozen` for config, `^{Job + Sends}` for work queues.
- **Recursive data:** `^T`, from the first lesson.
- **Caches:** weak values (Python's `WeakValueDictionary`) are rare. They are not a reason to keep `~` on their own.

## Launch exposure

The launch post's first table names `^x`, `~x`, and `*w`. That table is repeated in README, QUICK, and Learn 01. Cutting weak or box rewrites the launch's opening table and two Learn chapters. `rooms.rig` uses only `*Cell` and `*Actor`, and the FAQ relies on none of the candidates.

## Misuse against missing

- An AI that sprinkles `~` on a field gets a `*T?` upgrade it must match. A wrong `~` makes code that can be absent, not code that corrupts memory.
- `^{A}` can be overused where a generic `[T: A]` would be faster. Learn 08 already contrasts the two, and that is enough.
- `once ?fun` and `~{A}` are rarely reached for and hard to misuse.

Each would be missed more than it would be misused. None is a cut. Freeze the three rare forms, `*{A}`, `~{A}` and `once ?fun`: no new syntax or rules around them until a real program asks for it.

**Fix for the census:** count `|~x|` captures and `^Name` types. It missed the weak captures in two examples, and undercounted `^T` in `tree.rig`.
