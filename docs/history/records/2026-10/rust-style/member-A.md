# Member A: Background through Types (rustguide.md lines 227–989)

Read from `origin/main` (7c2365522). Every claim about what Rig does was tested with the `rig` that `tools/baseline origin/main` built; the probes are at the end.

## Table

| Guideline | Verdict | Rig form | Rec. | Priority |
|---|---|---|---|---|
| Scope | Not applicable | Google's codebases | — | — |
| Goal: readability over writeability | Applies as is | mantras.md, "Shorter and plainer than idiomatic Rust" | D | low |
| Goal: favor automation (LSCs) | Applies in Rig's form | `tools/migrate-*.py` today; ROADMAP "Machine-readable diagnostics" (`rig check --json` with fixes) and "A formatter" | D | medium |
| Goal: consistent with the ecosystem | Applies in Rig's form | consistent with Rig first; take a Rust idiom only when it clears "shorter and plainer" | S | low |
| Goal: rules pull their weight / avoid minor disputes | Applies as is | a formatter settles most of them | S | low |
| Follow public style rules | Applies in Rig's form | no single Rig style guide: layout in SYNTAX §8, names in mantras "How we name", words in AGENTS "One vocabulary" | D: one `docs/STYLE.md` that gathers them and that `rig fmt` enforces | high |
| API rules: library vs application | Applies in Rig's form | library = std and `pub` declarations; application = the rest | S | medium |
| Prefer small crates [chrome] | Not applicable | Chromium build-graph rule; a Rig module is a file or directory with no build-target cost | — | — |
| Flat layout per crate [chrome] | Not applicable / dissolved | a subdirectory is its own module by rule (SPEC §14 "Directory modules") | L (done) | — |
| Name files after the primary item | Applies in Rig's form, changed | the module name shows at every use, so `point.rig` with `obj Point` reads `point.Point`. Name a module for its domain (`geo.Point`, `text.split`). Inside a directory module, name each file after its main item (file names never show at a use) | S | medium |
| No APIs in non-leaf modules | Dissolved | no `mod` declarations and no re-exports (`pub use` is a parse error); a directory's files *are* the module | — | — |
| No glob imports; no preludes | Dissolved (L) | `use` binds only a module, never an item (`use mid.*` and `use std.math.gcd` are rejected). The one prelude belongs to the compiler (`std/prelude.rig`) | L (done); keep user preludes impossible | low |
| One module per `use` | Dissolved (L) | one path, one module name | L (done) | — |
| Locally scoped trait imports | Applies in Rig's form | `x.area()` through an `add Int: Shape` needs `use shape` in that file (probe); `use` is module-level only. The local form is the qualified call `shape.Shape.area(x)` | S: use the qualified call when an API's method appears once in a file | low |
| *(Rig extra)* unused imports | Gap | an unused local is an error, but an unused `use` is accepted (probe) | L: reject an unused `use`, as Go does | medium |
| Qualify calls to top-level functions | Dissolved (L) | always `math.gcd(…)`; `use x as y` for collisions (enforced) | L (done) | — |
| Use type names unqualified | Rig differs, for the better | `geo.Point` always: one spelling (the Go model), and the reader knows the source without cross-references | S: no `type Point = geo.Point` alias that only drops the prefix; shorten with `use geo as g` | low |
| Import mechanism [chrome] | Not applicable | — | — | — |
| Use the formatting tool | Applies; **missing** | no `rig fmt` (`rig --help`); ROADMAP lists it. std already indents by 2 spaces (every indent in std is even). 442 of 7,442 lines in std and examples pass 80 columns and 38 pass 100. Hex literals are mixed: 1,441 use lowercase letters and 869 uppercase | L/tool: build `rig fmt` and gate the suite on it; 100 columns; pick one hex case | high |
| Escapes for invisible characters | Applies; **gap** | a raw U+200D inside `"…"` is accepted and equals `"\u{200D}"` (probe). Control characters are already rejected (SYNTAX, string literals) | L: reject Unicode format characters (Cf: zero-width, bidi overrides, BOM) in literals and comments, giving the escape as the fix (the Trojan Source class) | high |
| Opting out of formatting | Applies in Rig's form | alignment matters in lookup tables (`HEX = Block([...])`, SIMD tables) | S: one comment marker (`# fmt: skip`) for alignment and generated code only | low |
| Avoid `Rc`/`Arc` | Applies in Rig's form | `*T` (counted, single-thread; `rig check --tasks` names what it pins), `*Frozen` (read-only, any task), `*Cell` (shared and changed) | S: one owner with views (`keeps`, `from`) first; `Table`/`Slot` or indices for graphs; `*T` when sharing is the model. D: one STD paragraph choosing among `^`, `*`, `*Frozen`, `Table` | medium |
| Prefer lends over deep copies | Applies; Rig already better | a bare owner argument is rejected and a clone is always written `+x` (L) | W/L: flag `+x` lent straight to a read-view parameter (a wasted allocation: `peek(+w)` is accepted), except where the same call lends the original to write (`g(+p, !p)` is legitimate); W: `+x` at the last use of `x` → `<x`. D: the diagnostic for `keep(v)` should suggest `[]Int`, as p1's already does, not `?List[Int]` | high |
| Accept flexible references | Mostly dissolved; three traps | `?T` takes `T`, `^T`, `*T`; `?String` takes a literal or a `String`; `[]T` takes a List, an array, a `^List`, or a slice. Left over: `?List[T]` (rejects an array), `?^T` (rejects a plain `P`), `?T?` (rejects `?q` and `none`, where `(?T)?` takes all three) | L: reject `?^T` parameters (a read view of a box can do nothing `?T` can't); W: `?List[T]` → `[]T` when only slice members are used; S: `(?T)?` over `?T?` for parameters | high |
| Return iterators vs owned collections | Applies in Rig's form, narrower | a chain is not a value (iterators.md, approved), so a lazy result is a named iterator object, `next(!@) -> T?`, as `text.split` returns | S: application code returns `List[T]`; std returns an iterator object where callers stop early or stream | low |
| Accept iterators vs slices | Applies in Rig's form | `[]T` covers every contiguous source; `[I: Iter](it: !I)` takes a stream (std.iter) | S: `[]T` by default; `[I: Iter]` only for a stream | low |
| Accepting `Into` | Dissolved | a closed list of implicit conversions (`T`→`T?`, owner→view, List→`[]T`, literal→`?String`) and no user-defined ones; an `Into` would hide a conversion or an allocation (North Star 3) | keep it so | low |
| `enum` over `bool` | Applies in Rig's form | keyword arguments (`go(3, strict: true)`) and enums with inferred variants (`push[U32, .big]`) | S: an unclear `Bool` is passed by keyword or becomes an enum. Owner option: let a parameter require its keyword (L) | medium |
| Reporting errors | Applies in Rig's form | `T?` absence, `T!E` failure, `panic` for bugs, `task.isolate` as `catch_unwind`; SPEC §13 already splits error from bug | D: add the three-way test to SPEC §13 / STD; S: `pub` APIs name their set (`T!E`) over a bare `T!` | medium |
| Newtypes vs aliases | Applies in Rig's form | `type` is transparent: swapped `Day`/`Month` aliases are accepted (prints 403). A one-field `obj Day` is the newtype: built `Day(3)`, `$size` 8, swapped arguments rejected | S: `type` for spelling only, `obj` for meaning; D: say so in SPEC "Type aliases" | medium |
| Named fields over tuples | Dissolved (L) | no tuples: several results never form a value, and `(Int, Int)` as a value's type is rejected. An object with more than one field is built by name (`Pt(1, 2)` is rejected), and one with a single field positionally: exactly the guide's newtype exception | L (done) | — |

## Top recommendations

1. **Build `rig fmt` and a `docs/STYLE.md` it enforces** (high). Rig's style is spread over SYNTAX §8, the mantras, and AGENTS. Rust can lean on rustfmt; Rig has nothing to lean on. The cheap rules are already true of std (2-space indents, one blank line between declarations). The open ones are a column limit (100: only 38 lines in std and examples pass it) and the case of hex letters (mixed today). Do this before style debates pile up.

2. **Reject the three Rust-shaped parameter types, or flag them** (high). Rig already dissolved `&Box<T>`, `&String`, and `&Vec<T>` for `?T`, `?String`, and `[]T`. It still lets a writer spell three of them: `?^T` (L, never more useful than `?T`), `?List[T]` (W; p1's error already teaches `[]Int`), and `?T?` (S; `(?T)?` also takes a plain value and `none`). The c2 diagnostic should suggest `[]Int` too. That is one classifier per fact: one diagnostic family for "a view of a container where a view of its contents would do".

3. **Catch wasted clones** (high). `peek(+w)` into a `[]Int` parameter clones a List and drops it at the end of the statement, and Rig accepts it silently. Flag a clone that is only lent, but exempt a clone that keeps one call's view apart from its write (`g(+p, !p)`). Also suggest `<x` for a `+x` at its last use (clippy's `redundant_clone`). Rig has no warning tier, and its culture is rejection (an unused local is an error). This and item 4 need an owner decision: put the wasteful cases in a `rig check --lint` and LSP channel, or make the unambiguous ones errors.

4. **Reject invisible format characters in literals and comments** (high, safety). Today a zero-width joiner is accepted raw. Control characters are already rejected; extending that to Unicode format characters (Cf) closes the Trojan Source class with an escape as the fix.

5. **Reject an unused `use`** (medium). It fits the existing unused-local error and Go's rule. Count a `use` that only enables an API's method shorthand as used.

**Where the guide is wrong for Rig.** It says to import types and use them unqualified. Rig always qualifies (`geo.Point`), and that is better: one spelling, nothing to xref, no glob or item-import debates, all enforced. Its file naming ("name the file after the item") makes names stutter in Rig, because the module name appears at every use. Its iterator advice assumes iterators are values; in Rig a chain is a loop, so the advice shrinks to "return a List unless callers stream." `Into` should stay absent: it is hidden conversion.

## Probes (scratch: `/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-practical-hypatia-3af8bd/dbe54b0f-c953-450b-9882-0ae1b99f5bc5/scratchpad/a`)

| Probe | Result |
|---|---|
| p1: `size(xs: ?List[Int])` given `[1,2,3]` | rejected: "a `?List[Int]` views a List alone: declare `[]Int`" |
| p2: `total(xs: []Int)` given a List, an array, a `^List`, and `v[1..]` | `2 3 1 1` |
| p3: `get(p: ?P)` given a `^P` and a `*P` | `3 4` |
| p4: `a(?P?)` given `o`; `b((?P)?)` given `?o`, `?q`, and `none` | `5 5 6 0` |
| o1: `a(?P?)` given `?q` / `none`; `bx(?^P)` given a plain `P` | each rejected (`?P?` is "a view of an optional, not an optional view"; `expected ?^P, got P`) |
| p5: `use std.math.gcd`; `use mid.*`; `pub use shape` | each rejected |
| fnuse: `use` inside `main` | rejected: "declarations are only allowed at module level" |
| main / main2: `x.area()` with the API's module not imported / imported | "type `Int` has no method `area`" / `9 9` |
| unused2: `use std.math`, never used | accepted, prints `1` (an unused local is rejected) |
| p6: `go(3, strict: true)` and `go(4, true)` | both accepted: `3 4` |
| p7: `0xAB == 0xab` | `true`; both cases lex |
| p8: `?String` given a literal, `t`, `?t` | `3 3 3` |
| c1: `keep(+v)` to an owner; `peek(+w)` to a `[]Int` | both accepted silently |
| c2: `keep(v)` | rejected; the fix offered is `?List[Int]`, not `[]Int` |
| s2 / s3: `g(+p, !p)` / `g(p, !p)` | `2` / rejected: a read loan is live |
| alias: `type Day = Int`, `type Month = Int`, arguments swapped | accepted, `403` |
| newt: one-field `obj Day` / `Month`, swapped | rejected both ways; `$size(Day)` is 8 |
| s1 / s4: `Day(3)`; `Pt(1, 2)` with two fields | accepted / rejected: "sets them by name" |
| z: raw U+200D in `"…"` vs `"\u{200D}"` | accepted; `5 5 true` |
| e2: bare call of a `T!` function | rejected: "must be wrapped with `!` … or `catch`" |
