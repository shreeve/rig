# Member C: other Rust features, implementation concerns, test framework

Sections: `rustguide.md` lines 1516 to the end. Rig read at `origin/main`
(7c2365522); probes run with the `rig` that `tools/baseline origin/main`
built. Recommendation codes: (L) rejection, (W) warning or lint, (S) style
rule, (D) std or docs convention.

## Table

| Guideline | Verdict | Rig form | Rec. | Priority |
|---|---|---|---|---|
| `#[must_use]` on functions and types | Applies in Rig's form, better as one rule | Today a bare `0` (p03) and an owning result (p19) are rejected, but `twice(3)`, `!v.pop()`, `(!v).pop()`, and `!s.add(1)` drop an `Int`, `Int?`, or `Bool` silently (p01, p18, p21, p24; backlog "A discarded result passes silently"). Make every statement whose value is not `Void` need `_ =`, as Zig itself requires; no attribute, no per-type list | L | high |
| `non_exhaustive` on enums | Rust advice is wrong for Rig | Rig compiles whole programs from source; a missing variant is rejected (p05) and a `_` after full coverage is rejected as unreachable (p04, p20). A forced wildcard would hide the very places a new variant must be decided. Do not add it | S: name every variant of an enum the program owns; `_` only for text, symbols, numbers, or a deliberate "the rest" | high |
| Omit no patterns on `non_exhaustive` matches | Not applicable (no such enums); the "only some variants" half applies in Rig's form | `if s as .circle(r)` is the one-arm form (SPEC §12, "`as` with a pattern"); `_ => pass` for a deliberate no-op | S | medium |
| Pattern matching over check-then-unwrap | Dissolved by Rig's design | No `unwrap` (p08), no flow typing after `!= none` (p09): the only ways in are `if o as x`, `while o as x`, `o ?? d`, `o?`, `match`, and `catch`. Already L | none needed; D: SPEC §12 could say in one line that there is no unwrap and why | done |
| `expect` over `unwrap` | Dissolved; already L | Forcing is `o ?? panic("why", v)` (p10) or `f() catch panic("why")` (p15), and `panic` needs a message (p16, SPEC §17). Rig has no message-less force at all | none | done |
| Context strings on assertions | Applies in Rig's form | No `assert` (p07; ROADMAP "Assertions"). Today: `panic("n must be even, got", n) if n % 2 != 0` (p06). A failing test prints its source, `half(4) == 3 is false` (p27), but not `half(4)`'s value | L/tool: the planned assert, and a test's last-line `Bool`, print each operand's value (`half(4) is 2`); reason text optional. S until then: `panic(why, value) if not cond` | high |
| Unsafe code | Applies in Rig's form | `raw` (SPEC §15): only Zig builtins and `extern` calls; ownership still checked; no raw pointers yet; `extern zig` only in std (L). No `raw` appears in std, examples, or bench | S: wrap `raw` in a safe `fun` (SPEC teaches it); a `# raw:` comment saying why it is sound and why no safe form serves; prefer checked `U8(x)` over `$intCast`. W/tool: `rig check --facts=raw` lists every raw site. D: std's Zig shims and the runtime carry a soundness comment at each cast (`src/runtime.zig` has 78 pointer casts) | medium |
| `catch_unwind` | Applies in Rig's form | `task.isolate(f)` / `task.supervise` (SPEC §18): sound by design, since `f` may not write anything outside itself, but `f`'s frames are not dropped (p22: "1 allocation left by a panic") | S/D: isolate only at a supervision boundary (a request, an actor, a plugin), never as control flow; errors are values. STD states the leak cost | medium |
| Getters and setters | Mostly dissolved | `pub ?len: Int` is read by all, written by its module (no getter); `pub f` needs no setter; `fun digits(!@) -> ?String from @text` lends one field; `<a.f` takes a field leaving `none` (`take_foo`). Std names: `get`/`edit`/`put`/`replace`/`take` (STD Map) | D: prefer a `pub ?f` field to a getter method; no `get_`/`set_` prefixes ("Queries name their answer"); `edit` for a write view, `take` and `replace` as Map has them | medium |
| Closure accessors (`with_foo`) | Dissolved | A result `from @f` keeps one field lent and is checked; `Cell` changes only by marked calls | none | low |
| `non_exhaustive` on structs | Applies in Rig's form, already L | A private field means only the declaring module constructs (SPEC §14); a field with a default may be omitted, so adding one breaks no caller; `T()` with all defaults works from any module | S: a field added to a `pub obj` comes with a default | low |
| Implement API sets together | Applies; partly L | `Eq` without `hash_into` has no hash (p23, SPEC "Own meanings"). `is_empty()` exists on String, List, array, slice, Cell[List] only; a user type with `len` gets none (p13) | L (dissolve): give `is_empty()` to any type whose `len` is an `Int` field or `fun len(?@) -> Int` | low |
| Overloading for non-math purposes | Dissolved | No user operators: `+` on an object is rejected (p11), `Num` is the built-in numbers' alone (p25); `==`, `<`, hash, print come only from `Eq`/`Ord`/`Hash`/`Print` with fixed signatures; no `+` on text. (`add` is the API-addition keyword, unrelated) | keep so; if decimal/bigint operators come, one API with fixed signatures, arithmetic types only | low |
| `doc(hidden)` items | Dissolved | Privacy is checked (L); there is no hidden-but-public tier; `__rig` names are unbound to user code (p26) | none | low |
| `const` functions | Dissolved | A compile-time function is called with brackets only (`cap[8]`), so changing it breaks every call visibly; its body is limited (SPEC §16) | S: a `pub` compile-time function is a promise | low |
| No unstable features | Not applicable as stated | No feature flags; unbuilt rules are `rig pending` and rejected (North Star 1, 6); Zig pinned at 0.17 | none | low |
| No code before `main` | Dissolved; already L | Module-level `x = v` is a compile-time constant (p12 rejects `X = make()`); no mutable module bindings (`=!` rejected); `rig run` ignores tests | none | done |
| Don't overuse type inference | Mostly dissolved | No `.into()`/turbofish: conversions name their type (`U8(x)`), parsers name theirs (`text.parse_int`), and `List()` with no element type is rejected (p14) | S: annotate a binding whose type comes from a generic call several lines away | low |
| Combinator chains vs `for` | Applies as is | std has no lazy adapter chains (std.iter: `count`, `sum`); `for` with `?? continue` and `match` is the idiom | S: prefer `for`; D: if std grows `any`/`all`/`find`, they short-circuit and allocate nothing (no `collect`) | low |
| `format!` over `+` concatenation | Dissolved | No `+` on text, no interpolation: `String(a, b, c)` builds, `!t.add(...)` appends (SPEC §10 String), `!t.reserve(n)` sizes | S: build long text into one String with `!t.add`, not nested `String(String(...))` | low |
| Per-codebase test framework | Applies in Rig's form | User code: `test "name"` blocks, `rig test`, deterministic seeds (SPEC "Tests"). The compiler: `test`/`bomb`/`fail`/`code` cases in `test/rig/*.rig.test`; doc blocks are tests (docs/internals/tests.md) | S: concurrency tests under `--seeds`; D: show how a user test expects a panic (`task.isolate(...) catch |e| return e == task.Stop.panicked`), Rig's `bomb` for users | medium |

## Top recommendations

1. **One discard rule (L).** Rig already rejects a bare `0` and an unused
   owning value; it lets `twice(3)` and `!s.add(k)` drop an `Int` or a
   `Bool`. Rust needs `#[must_use]` per function because Rust's default is
   permissive; Rig can dissolve the attribute by flipping the default:
   a statement whose value is not `Void` needs `_ =`. Zig, which Rig
   writes, has exactly this rule, and Swift warns on it by default.
   Uses in the tree are few (`bench/bigint/bench.rig:51` `!z.pop()`),
   so the cost is small; Trig gets the one-line note and a migration
   script. SPEC §17 already writes `_ = !s.add(1)`, which the rule makes
   necessary rather than decorative.
2. **No `non_exhaustive`, and `_` kept honest (S).** Google's rule
   protects separately compiled crates from a new variant. Rig compiles
   from source and rejects a missing variant, so the break is the
   feature: it lists every place to decide. Rig should do better than
   Rust here: a style rule to name every variant of an enum the program
   owns, and `if s as .x` for the one-variant case.
3. **Failures that show values (L/tool).** Rust's context strings exist
   because `assert!` shows only source. Rig's test report shows only
   source too (`half(4) == 3 is false`). Printing each operand's value,
   in the test report and the planned `assert`, removes most of the need
   for a message; keep a reason optional. Until then, the idiom is
   `panic("why", value) if not cond`.
4. **`raw` reviewed like `unsafe` (S, W).** Rig's `raw` is already
   narrower than Rust's. Add: wrap it in a safe function, a `# raw:`
   comment with the reason and why no safe form serves, a listing tool,
   and soundness comments at the casts in the runtime and std's Zig.
   Prefer the checked `U8(x)` to `$intCast`; SPEC §15's example could
   show an `extern` call alone, so it does not teach an unneeded `raw`.
5. **`task.isolate` only at boundaries (S, D).** It is Rig's
   `catch_unwind`, sounder than Rust's, but a panic's frames leak (p22).
   Say so in STD and keep it to supervisors.

Already done by design, worth stating in a Rig style guide as wins over
Rust: no unwrap, a panic needs a message, no code before `main`, no user
operators, privacy checked rather than hidden.

## Probes

All in `/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-practical-hypatia-3af8bd/dbe54b0f-c953-450b-9882-0ae1b99f5bc5/scratchpad/mc/`, `RIG_OUT_DIR` set there.

| Probe | What | Result |
|---|---|---|
| p01 | `twice(3)` as a statement | accepted, prints `1` |
| p02 | `f(3)!` as a statement, `Int!` | accepted |
| p03 | bare `0` as a statement | rejected: "this expression does nothing as a statement; ... `_ = ...`" |
| p04 | `_` after every enum variant | rejected: "this arm never runs" |
| p05 | match missing `.blue` | rejected: "`match` is not exhaustive: it misses `.blue`" |
| p06 | `panic("...", n) if n % 2 != 0` | panics `p06_panic_guard.rig:3:3: panic: n must be even, got 3`, exit 134 |
| p07 | `assert(1 == 1)` | rejected: unbound name `assert` |
| p08 | `o.unwrap()` | rejected: "cannot call `unwrap` on optional ... `x ?? fallback`" |
| p09 | `if o != none` then `o + 1` | rejected: `+` on `Int?` |
| p10 | `o ?? panic("why")` | panics with the message |
| p11 | `a + b` on objects | rejected: requires numeric operands |
| p12 | module `X = make()` | rejected: needs a compile-time value |
| p13 | `is_empty()` on an obj with `fun len` | rejected: no method `is_empty` |
| p14 | `xs = List()` | rejected: needs its element type |
| p15 | `parse_int(...) catch panic("why")` | panics with the message |
| p16 | `panic()` | rejected: "`panic` needs a message" |
| p17 | `catch |e|` match, `E.a` and `_` | accepted |
| p18 | `(!v).pop()` as a statement | accepted, `Int?` dropped |
| p19 | `make()` returning `String`, discarded | rejected: owns what it must release; `_ = ...` |
| p20 | `_` after every error member | rejected: "this arm never runs" |
| p21 | `!v.pop()` as a statement | accepted |
| p22 | panic inside `task.isolate` holding a String | `-1`, then "1 allocation (16 bytes) left by a panic that `task.isolate` ... stopped", exit 0 |
| p23 | `Map[Name, Int]` with own `Eq`, no `hash_into` | rejected: cannot be hashed by its fields |
| p24 | `!s.add(1)` as a statement (`Bool`) | accepted |
| p25 | `obj V: Num` | rejected: "`Num` is provided by the built-in numbers alone" |
| p26 | `print(__rig_prelude)` | rejected: unbound name |
| p27 | `rig test`, last line `half(4) == 3` | `FAIL ... half(4) == 3 is false`; no operand value |
