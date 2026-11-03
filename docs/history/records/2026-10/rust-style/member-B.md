# Member B: Traits, Concurrency, Macros, Naming, Documentation (rustguide.md lines 990–1515)

Read against `origin/main` (7c2365522). Probes ran with the baseline `rig` at main, `RIG_SANITIZE=1`, in my scratch directory; results at the end.

## Table

| Guideline | Verdict | Rig form | Rec. | Priority |
|---|---|---|---|---|
| **Traits** | | | | |
| Add impls when needed (libraries early, apps late) | Applies in Rig's form | Eq, Hash, Print, Copy, Clone, Owned, Sends, Syncs are derived from a type's parts with no declaration (SPEC "Bounds"); only `Ord` and a program's own APIs are opt-in. So the only real question is `Ord` and own APIs on `pub` std types | D: a `pub` std type with a natural order names `: Ord` | low |
| Use a std trait, not a look-alike method (`should_implement_trait`) | Applies; Rig can do better | A method `fun eq(?@, other: ?Name) -> Bool` on a type whose header does not name `Eq` is accepted as an ordinary method, and `==` silently keeps comparing by fields (probe 3: `a == b` false, `a.eq(?b)` true). The same holds for `hash_into`, `order`, `print` | **L**: reject a method that has the exact signature an API fixes (SPEC "Own meanings") on a type that does not name that API, with the fix "name `Eq` on the header, or rename it". Rig has no warning tier (`src/diag.zig`: error, note), so a lint is not available; a rejection fits "dissolve" better anyway | **high** |
| Use `#[derive]` where possible | Dissolved | No `derive`: the facts are derived; `obj V: Ord` is the one derive-like opt-in, and naming an API without writing its method keeps the derived meaning | S: write the method only to change the meaning. Two gaps: naming `Hash` on a header whose fields cannot hash is accepted until use (probe 18) → L at the header; derived `Print` prints every field, secrets too (probe 19) → S/D: a type holding a secret writes its own `print` | medium |
| Generics vs `dyn Trait` | Applies in Rig's form | `[T: Shape]` is a direct call; `?{Shape}`, `^{Shape}`, `*{Shape}` are a table call, and the braces mark the cost (apis.md "Two principles"). "dyn compatibility" is already L: a call through an object of a method with compile-time parameters or `Self` is rejected (SPEC "API objects") | S: prefer a bound; braces for a list of mixed types; an enum for a closed set of kinds; braces where instance code size matters | medium |
| Trait vs inherent impl | Applies as is | DESIGN non-goal: "traits and interfaces ahead of a program that needs them". An `api` only for a bound or an API object | S | medium |
| Extension traits (`~Ext`) | Dissolved | Rig's extension is a module's free function, `text.contains(s, pat)` (std/text.rig does this throughout). `add Int: Shape` works (probe 8d) but is coherence-checked: only in the API's module, never a member the type already has, two APIs giving one name make the call name the API (SPEC "APIs") | S: no extension APIs and no `Ext` suffix (owner's taste); `add` is for giving a type an API a bound or object needs | medium |
| Public fields: impl what subfields impl | Dissolved | Derived by fields | none | — |
| Error types `Copy` | Applies in Rig's form | Error members may carry owning payloads, `named(what: String)` (probe 9, clean) | S: prefer plain payloads (`bad(at: Int)`, a symbol) so a failure copies; own text only where the message needs it | low |
| `Copy` when it will stay `Copy` | Dissolved, with a residue | `Copy` is a fact of parts; adding a `String` field to a `pub` plain object turns every user's `b = a` into a move | D: STD.md says which `pub` std objects are plain and promises to keep them so | low |
| `Clone` unless an external resource | Applies; already L | A type with a `drop` body, a Signal, or a write view has no clone (probe 2) | none (built) | — |
| `Default` with `new()` | Dissolved | Field defaults; `T()` of an object whose every field has one (SPEC "Objects") | none | — |
| `PartialEq`/`Eq`, `PartialOrd`/`Ord` | Applies; **Rig is unsound here** | Rig has one `Eq` and one `Ord`, and `Float` provides both. NaN breaks both: `a == a` false (probe 4); `sort.sort` of floats with a NaN returns `[3.0, 5.0, nan, 0.5, 1.0, 2.0]` (probe 17); `n.order(?1.0)` and `<` on an `obj V: Ord` with a NaN field reach Zig's `unreachable` in debug and **segfault (signal 11) under `--release=fast`** (probes 20, 21) | **L**: Float provides no `Ord`, as it already provides no `Hash`, for the same reason; `<` on floats stays IEEE; a `total_order` (IEEE 754 totalOrder) method for sorting floats; `obj V: Ord` with a float field is rejected at the header. Accept-means-correct and safe-code-cannot-corrupt-memory are both broken today | **high** |
| Map keys: `Hash` + `Eq`, `Ord` if total | Dissolved | `K` of `Map` is implied `Hash`; a float key is rejected with the field named (probe 5); own `Eq` without `hash_into` has no hash (L, SPEC "Own meanings") | none (built) | — |
| Pair important `From` with constructors | Applies in Rig's form | The constructor is `Type(fields)`; built-in conversions are a type called, `Float(x)`, `U8(x)`, `String(a, b)`; a program's conversion is an associated function, `BigInt.from_int(n)` | S/D: name a conversion `Type.from_kind(x)`; keep `Type(x)` for the constructor | low |
| Options structs implement `Default` | Dissolved | Parameter defaults with keyword arguments, `go(1, verbose: true)`, and field defaults, `Opts(verbose: true)` (probe 7). No `..Default::default()` | S: parameter defaults for a few options; an object with field defaults when several functions share them | medium |
| **Concurrency** | | | | |
| Never reach inside a poisoned mutex | Applies; already L | No Mutex. A panic in an actor's method abandons its value, and every later call panics naming the method that ended it; `*Actor.supervised(make)` makes a fresh one (SPEC "Actors"). `task.isolate` takes no write capture, so nothing outside it is half-changed, except a `*Cell` it changes, which keeps its changes (SPEC "Isolating a panic") | S: after an isolate fails, do not trust a `*Cell` it changed; rebuild it | low |
| No `async`/`.await` [Chrome] | Dissolved (the reason is general in Rig) | One kind of function; `f(x)&`, `>t` (concurrency.md). `async` is held, but `async fun` gives "unexpected keyword `async`" with no fix (probe 14), while `trait` says "write `api`" (probe 15) | L (message): "Rig has no `async`; any call runs as a task with `&`" | low |
| No std threads [Chrome] | Dissolved | No thread API; `task.workers(n)`; tasks, not threads | none | — |
| `fuchsia_sync::Mutex` [Fuchsia] | Not applicable | Fuchsia only; Rig has `Cell` behind `*`, actors, channels, `*Frozen` | — | — |
| **Macros** | | | | |
| Prefer functions over macros; weigh costs | Dissolved | No macros (DESIGN non-goals). In their place: generics and bracket parameters, compile-time functions limited to integers, `Bool`, plain enums, and arrays (SPEC §16), and `$` builtins, which ask about a type and never work on a value (mantras) | D: the order of preference, in Rig's words: functions, objects, APIs; then generics with `[n: Int]`; then compile-time functions; then a generator in `tools/` writing checked-in tables (as Unicode's are); `extern zig` / `raw` last. `macro_rules!` gives a bare parse error (probe 13); optional message like `trait`'s | low |
| **Naming** | | | | |
| Method names: `as_`/`to_`/`into_` by self convention | Dissolved in part | The self sigil says it: `<@` consumes (`<s.into…` shows `<` at the call), a view result says `from @`, a kept view is written `?b.all()`. No `_mut` twin (`iter_mut`, `get_mut`): `for x in !v`, `!v.push`. The mantras' "How we name" already fix `is_`, `len`/`count`, verbs for actions | S: no `as_` (and `as` is a keyword) or `into_` prefix; `to_` for a conversion that makes a new value (`x.to_bits()`); never a `_mut` twin. A check that `to_` takes `?@` is possible but low value | medium |
| Lifetime names | Dissolved | No lifetimes: `from a`, `keeps s` name the parameter itself | none | — |
| Generic parameter names | Applies; case is L | A type parameter starts with a capital, a value parameter is lowercase with a type (probe 6) | S: `T`, `U` unbounded; `K`, `V` for maps; a letter from the bound otherwise; `n` for a count | low |
| `~Ext` suffix | Dissolved | No extension APIs (above) | none | — |
| Constructors `new`, `new_with_foo`, `try_new` | Dissolved | `Type(fields)` is the constructor; a named one says what it makes, `Point.origin()`; `try_` is redundant, since `-> T!E` and the call's `!`/`catch` show failure. A method may be named `new` (probe 10) | S: no `Type.new()` that duplicates `Type(...)`; no `try_` prefix | medium |
| Avoid abbreviations | Applies in Rig's form | Owner's taste: short plain words, three letters where they read well (`obj`, `sub`, `fun`, `api`, `add`); a word people already know (AGENTS "Naming"); std uses `len`, `cwd`, `gcd`, `stat` | S: plain words; abbreviate only to a short form readers already know, listed once in the style guide; never drop letters inside a word otherwise; avoid a word languages disagree on (mantras) | medium |
| **Documentation** | | | | |
| Document public APIs (`missing_docs`) | Applies in Rig's form | SYNTAX §1: "no block comments and no doc-comment syntax". std documents each `pub` declaration with a `#` block above it by convention (std/text.rig) | **D + S**: define the doc comment as the `#` block directly above a declaration, no blank line between, and a file's opening block as the module's; no new syntax, so `///` vs `//` cannot be confused. A CLI test that every `pub` declaration in `std/` has one | **high** |
| Examples | Applies; Rig does better | Every `rig` block in the docs is a test; a `rig` block in a `#` comment is not | S: examples live in Markdown (STD.md), where they run; none in comments until the runner tests them ("docs claim only what runs") | medium |
| Document panic cases | Applies as is | std does ("outside that it panics, as indexing does", std/text.rig `find_any`). Failures are in the signature (`T!E`) | S: each `pub` function says when it panics; a failing one says what each member of its set means | medium |
| Document invariants of unsafe code | Applies in Rig's form | `raw` blocks and `extern zig` | S: a `raw` block's comment says what it relies on and why safe Rig cannot say it | medium |
| Capitalization and punctuation | Applies as is | std writes sentences, plus "timeless prose" (AGENTS) | S | low |
| Don't explain the language; don't restate the name | Applies as is | std's "Whether `s` begins with `prefix`" is the house style for tests: one sentence that says what the name does not | S: a query's comment names its answer ("The index of …"), a test's starts "Whether …" (matches the mantras) | low |
| `///`, `//!`, Markdown, `//` for implementation | Dissolved in Rig's form | One comment syntax; position decides: above a declaration is its doc, in a body is an implementation note; backticks for code | S, and tooling: LSP hover (ROADMAP: "types on hover") shows the signature, how it takes self, `from`/`keeps`, and that block | high |
| Docs from macros | Dissolved | No macros | — | — |

## Top recommendations

1. **Float ordering is unsound today (L, high).** Float provides `Ord`, and NaN reaches Zig's `std.math.order` `unreachable`: a panic in debug, a segfault under `--release=fast`, from safe code that `rig check` accepts (probes 20, 21). `sort.sort` silently fails to sort with a NaN (probe 17). This is Rust's PartialOrd/Ord lesson, and Rig already applied it to `Hash`: "a float provides no Hash". Default: Float provides no `Ord` either; `<` on floats stays; add `x.total_order(?y)` for sorting; reject `obj V: Ord` with a float field at the header. Owner decision, since it rejects programs a release accepted (`max(1.5, 2.0)` through a generic, sorting floats): it needs release notes and a Trig note.
2. **A look-alike `eq`/`order`/`hash_into`/`print` is silently ignored (L, high).** Reject the exact fixed signature on a type that does not name its API (probe 3). Rig has no warnings, and this is a one-line rejection with a fix.
3. **Doc comments by position, no new syntax (D/S, high).** The `#` block above a declaration is its doc; the file's first block the module's. std already writes it so; make it the rule, test that every `pub` std declaration has one, and have hover show it with the signature's ownership.
4. **Options and constructors are dissolved; say so in the style guide (S, medium).** Parameter defaults and keyword arguments, field defaults, `Type(...)` as the constructor; no `new`, `try_`, `as_`, `into_`, `_mut`, or `Ext`. The sigils and `T!` carry what those prefixes carry in Rust.
5. **Bounds over braces, enums for closed sets, module functions over extension APIs (S, medium).** The cost is already visible in braces; the guide should say when to pay it.

**Where the Rust advice would be wrong for Rig:** `~Ext` naming (Rig has module functions and the owner prefers plain words), "implement `Copy` on error types" (a fact of parts, not a choice), and `///`/`//!` as separate syntax (one comment syntax with a positional rule is simpler). **Where Rig does better:** derived facts with the opt-in only for `Ord`; Clone refused for drop-bearing types; poison handled by the language (a dead actor's calls panic, naming the method); no macros; examples that are tests.

**Two by-products to file:** `Twice.twice(4)` with a literal is rejected with "`Int` does not [provide `Twice`]", though `add Int: Twice` exists and `Twice.twice(x)` with `x: Int` works (probes 8e, 8c): a wrong diagnostic, or a literal not typed before the API check. And `obj K: Hash` with a float field is accepted until a use (probe 18).

## Probes (baseline `rig` at origin/main, `RIG_SANITIZE=1`)

| # | Program | Result |
|---|---|---|
| 1 | plain `obj Point`, `Tag(name: String)`: print, `==`, `.hash()`, Map key, `+t` | `Point(x: 1, y: 2) true true 7`; `true Tag(name: "x")`: all derived |
| 2 | `obj Fd` with `drop(!@)`, `g = +f` | rejected: "a value with a `drop` body … has no clone; move it with `<x`, or lend it" |
| 3 | `fun eq(?@, other: ?Name)` without `: Eq` | accepted; `a == b` false, `a.eq(?b)` true |
| 4 | `P(v: NaN)`, `a == a`, `n == n`, `n < 1.0` | `false false false` |
| 5 | `Map[P, Int]` with a float field | rejected: "`P` cannot be hashed; its field `v` is a `Float`" |
| 6 | `fun max[t: Ord]` | rejected: "a type parameter starts with a capital letter" |
| 7 | field defaults, parameter defaults, keyword args, `Opts()`; `T()` in a generic | `3 4 3`; `T()` rejected: "it cannot be called or constructed" |
| 8 / 8d | `add Int: Twice`; `5.twice()` / `x.twice()` with `x: Int` | literal: "type `Int` has no method `twice`"; typed: `10` |
| 8b | `add Sq: Area` for a type of the same module | rejected with "name `Area` on its header" |
| 8c / 8e | `Twice.twice(x)` / `Twice.twice(4)` | `10` / rejected: "`Int` does not" provide `Twice` (wrong) |
| 9 | error member `named(what: String)` | runs clean, `1` |
| 10 | `Counter.new()`, `Counter.try_new(3)` with `-> Counter!Bad` | `0 3 -1` |
| 11 | object with `next(!@) -> Int?`, `for x in !c` | `1 2 3` |
| 12 | `max(1.5, NaN)`, `max(NaN, 1.5)` | `nan 1.5`: order-dependent |
| 13 | `macro_rules! sq` | "unexpected name `sq`" |
| 14 | `async fun f()` | "unexpected keyword `async`; expected a statement" (no fix) |
| 15 | `trait Shape` | "Rig has no `trait`; write `api`" |
| 16 | `api IntExt`, `IntExt.twice(4)` | same wrong rejection as 8e |
| 17 | `sort.sort(!xs)` of `[3.0, 5.0, NaN, 1.0, 2.0, 0.5]` | `[3.0, 5.0, nan, 0.5, 1.0, 2.0]`: not sorted, no error |
| 18 | `obj K: Hash` with a float field, unused | accepted |
| 19 | `print` of `Login(user, password)` | prints the password |
| 20 | `obj V: Ord` with a NaN field, `a < b` | debug: `panic: reached unreachable code` in `std.math.order`; `--release=fast`: killed by signal 11 |
| 21 | `NaN.order(?1.0)` | `panic: reached unreachable code` |
