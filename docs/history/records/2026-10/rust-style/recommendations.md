# Google's Rust style guide, applied to Rig: the committee's recommendations (2026-10-27)

Three members reviewed every guideline: [member-A.md](member-A.md) (organization, formatting, ownership, function signatures, types), [member-B.md](member-B.md) (traits/APIs, concurrency, macros, naming, docs), and [member-C.md](member-C.md) (unsafe/`raw`, `must_use`, `non_exhaustive`, unwrap, assertions, formatting, tests). Every claim was probed against `rig` at main `7c2365522`. The reviewing session reproduced the most serious one, float ordering, itself. No repository file was changed.

## The overall picture
About half of the guide is **dissolved by Rig's design**. Rig needs no rule because the language has no way to write the mistake:
- glob imports, and `use` of several modules: `use` binds one module, never an item;
- `&str` versus `&String`, and `Into`, since Rig's conversions are a closed list;
- tuples (no tuple values), lifetimes, macros, `async`;
- `unwrap`, since forcing a value needs `?? panic("why")`;
- `derive`, since Eq, Hash, Print, Copy and Clone come from a type's parts;
- options structs, since Rig has field and parameter defaults;
- code before `main`, since module-level bindings are constants;
- non-mathematical operator overloading.

One piece of Rust advice is **wrong for Rig**: `#[non_exhaustive]`. Rig compiles whole programs from source, rejects a missing variant, and rejects a `_` after full coverage. A forced wildcard would hide exactly the places a new variant must be decided.

The rest either applies in Rig's own form or exposed real gaps, six of them bugs.

## 1. Bugs found (compiler fixes, not style)
1. **Ordering floats is unsound, against North Star 1.** `Float` provides `Ord`, but NaN has no order.
   - Comparing two `obj V: Ord` values when a field is NaN reaches Zig's `unreachable`: a panic in debug and in safe `--release`, reproduced; undefined behavior, a segfault, under `--release=fast`.
   - `sort.sort` of floats with a NaN returns an unsorted list with no error, and `max(1.5, NaN)` depends on argument order.
   - Rig already denies `Float` a `Hash`.
2. **Look-alike API methods are silently ignored.** A `fun eq(?@, other: ?T) -> Bool`, `order`, `hash_into` or `print` with the exact signature, on a type whose header doesn't name the API, compiles. `==` then ignores it. Reject it, or point to the header.
3. **A discarded result passes silently** (an existing backlog entry). `twice(3)`, `!v.pop()` and `!s.add(1)` as statements drop an `Int`, `Int?` or `Bool`, while a bare `0` is rejected. The one rule: a statement whose value isn't `Void` needs `_ =`, as in Zig. That replaces Rust's `#[must_use]` entirely.
4. **Invisible characters in literals.** A raw zero-width joiner, or a bidi override, inside `"…"` is accepted; control characters already aren't. Require the escape (`\u{200D}`), as Rust's guide does.
5. **An unused `use` is accepted** while an unused local is an error. Make it an error, as Go does.
6. **Two wrong messages:**
   - `Twice.twice(4)` with a literal is rejected with a misleading message;
   - `async fun` gives "unexpected keyword `async`" with no fix: say tasks are `f(x)&`.

## 2. Signatures that turn callers away (Rust's `&Box<T>`, `&Vec<T>`, `&Option<T>`)
Rig already accepts the flexible forms: `?T` takes `T`, `^T` and `*T`; `[]T` takes a List, an array, a box of either, or a slice; `?String` takes a literal, a String or a slice. Three narrower forms remain:

7. **`?^T` as a parameter:** reject it, with the fix "write `?T`". The function can't use the box itself, only its value.
8. **`?List[T]` as a read parameter:** prefer `[]T`, which also takes arrays and slices. Style rule, since a read-only `?List[T]` isn't wrong, just narrower.
9. **`(?T)?` over `?T?`** in results, which std's `get` already returns. Style rule.
10. **A wasted clone:** `peek(+w)` into a read-view parameter allocates a copy that is only read. Reject it, or flag it; `g(+p, !p)` must stay allowed.

## 3. Tools and docs
11. **`rig fmt` and one `docs/STYLE.md`.** Rig has no formatter, and its style is spread across SYNTAX §8 (layout), the mantras (names) and AGENTS (vocabulary). Open choices for the owner:
    - line length: 100 columns, which 38 lines of std and examples pass today;
    - one case for hex letters, which is mixed today;
    - one `# fmt: skip` for aligned tables and generated code.
12. **Doc comments by position.** A `#` block above a declaration is its doc, and a file's first block is the module's. Show them on LSP hover, and test that every `pub` std declaration has one. Examples belong in Markdown, where they run as tests, not in comments, where they don't.
13. **`assert`, with values** (ROADMAP "Assertions"). A failing test prints `half(4) == 3 is false` but not what `half(4)` was. Print each operand's value there and in the coming `assert`. Until then the style is `panic("why", v) if not cond`.
14. **`raw` reviewed like Rust's `unsafe`:**
    - wrap it in a small safe function;
    - give each block a `# raw:` comment saying what it relies on and why safe Rig can't say it;
    - add a tool that lists every `raw` site;
    - prefer the checked `U8(x)` to Zig casts.
15. **`task.isolate` is Rig's `catch_unwind`:** keep it to boundaries such as servers and supervisors. It's sound, but the frames a panic stops are not dropped: their allocations are reported ("1 allocation left by a panic…"), not freed. Document it in STD.

## 4. Style rules for STYLE.md (Rig's form of the guide's advice)
- **Ownership:** one owner with lent views (`keeps`, `from`) first; `*T` only for real sharing, `*Frozen` for read-only data across tasks, `*Cell` for shared changes. That's Rust's "avoid `Rc`/`Arc`".
- **`Bool` parameters:** an unclear `Bool` is passed by keyword (`go(3, strict: true)`), or becomes an enum.
- **Newtypes:** a one-field `obj Day` is a newtype and catches swapped arguments; `type` is only an alias and catches nothing (probed: swapped `Day`/`Month` aliases are accepted).
- **APIs:**
  - a bound `[T: Shape]` (a direct call) over braces `?{Shape}` (a table call) unless the values really differ in type;
  - define an `api` only for a bound or an API object;
  - add to an existing type with a module's free function, not an extension API.
- **Errors:**
  - absence is `T?`, an expected failure is `T!E`, a bug is a panic;
  - prefer plain error payloads (`bad(at: Int)`) so a failure copies;
  - every `pub` function says when it panics.
- **Modules:** name a module for its domain: `geo.Point`, not `point.Point`, since the module's name shows at every use.
- **Generic parameters:** `T`, `U` unbounded; `K`, `V` for maps; `n` for a value parameter.
- **Loops:** `for` by default. When iterator chains land (docs/design/iterators.md, approved), use a chain only where it reads more clearly than the loop, as the guide says.
- **Text:** build long text into one String with `!t.add(...)`, not many `String(...)`s.
- **Comments:** timeless prose; one sentence that says what the name doesn't; no restating the name.

## Decisions for the owner (defaults first)
1. **Floats and ordering.**
   - (a) Float loses `Ord`, as it already lacks `Hash`, and gains `total_order()` and `sort_by`-friendly helpers. **Default.** It rejects programs that sort or compare floats as `Ord`; Trig gets a note and a migration.
   - (b) Float keeps `Ord`, defined as IEEE total order, with NaN after +inf. Nothing is rejected, and NaN sorts last.
2. **Warnings.** Rig has no warning tier. (a) Errors only: bugs 2–7 and 10 become rejections, and the rest go to STYLE.md and `rig fmt`. **Default.** (b) Add a lint tier (`rig lint`) for the softer rules 8 and 9.
3. **The discard rule** (`_ =` for any non-`Void` statement). **Yes**, as its own PR, with a Trig migration script.
4. **Reject invisible format characters in literals, and unused `use`.** **Yes.**
5. **`rig fmt` and STYLE.md.** **Yes, after the feature now in flight;** the owner picks the line length and the hex case.
6. **`assert` with operand values.** **Yes**, taking the ROADMAP item.
