# Audit: tests, build and CI; diagnostics and the newcomer experience

Base: `revamp` @ 5f2bdbc. No tracked files were modified. Probes are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/audit-tests/`:
`probes/*.rig` (about 170 newcomer mistakes), `probe_out.txt`, `run_timed`
(a copy of test/run that times each test), `timings1` (cold) and `timings2` (warm).

Caveat on timings: other agents were loading the machine heavily
(load average 215 at one point), so absolute wall times run high: cold
was 313 s and warm 160 s at -j10, against the ~170 s and ~55 s the
brief quotes. The per-kind split and the mechanisms below do not depend
on load, and the cache-thrash result is deterministic.

## Findings (most severe first)

| ID | file:line / test | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| T1 | src/ownership.zig (borrow of a temporary); no test | soundness gap (found while probing; outside my lens) | CRITICAL | A read borrow of a *temporary* struct can be stored in a struct field and returned. `fun mk(n) -> H` with `H(s: ?S(n: rt(n), m: rt(n+1)))` passes `rig check` and emits `return H{ .s = &S{...} }`, a pointer into the callee's dead frame. The same form in `main` (`h = H(s: ?S(...))`), and `r = pick(?S(n: rt(7)))` where `pick(s: ?S) -> ?S`, keep a borrow of a temporary past its statement. They print the right values today only because Zig happens not to reuse the slot, and Zig does not specify the lifetime of a `&T{...}` temporary. The borrow of a *local* is rejected correctly (`returned borrow of s does not originate from a borrowed parameter`). | `probes/y07_dangling_return.rig` prints `4299979536 0` in Debug and `0 0` with --release=fast, where the source says `7 8`. Also `y06`, `y09`, `y10`, `rg36`, `rg106`. | Extend the rule `array_as_slice` already applies ("a temporary array is lent ... only to a call that keeps no borrow of it; bind it to a name") to every `?e` / `!e` whose operand is a temporary: allow it only as an argument to a call whose result carries no loan. Reject it in constructor fields, in bindings, and in calls whose result borrows it. Add reject tests for the ctor, return, binding, and call-result forms. | +30..60 | med: may reject `x = ?Lit(...)` idioms in docs and tests; grep for `= ?[A-Z]` first |
| T2 | test/cli/{release_checks,build,extern_libc,test_blocks,leaks,stack_guard,modules}.sh | harness speed / caching bug | HIGH | Each CLI script builds several different programs into the same `$RIG_OUT_DIR`. Zig keeps one cache entry per root path and flags, so each build evicts the previous one, and **every CLI build is cold on every run**. Warm, the CLI tests take 292 s of the 537 s worker total. `cli/release_checks` alone takes 101 s warm (7 ReleaseFast builds), which makes it the warm suite's long pole. | a/b/a experiment in one out dir: 6.46 s, 2.37 s, **2.48 s** (a third build of `a` that should hit the cache), then 0.14 s. timings2: release_checks 101 s, build 44 s, run 27 s, zig_cache 25 s, test_blocks 25 s. | Give each program its own directory: `RIG_OUT_DIR=$RIG_OUT_DIR/<prog> "$RIG" build ...`, or a `rigb() { RIG_OUT_DIR=$RIG_OUT_DIR/$1 ...; }` helper in `_lib.sh`. `zig_cache.sh` and `run.sh` must stay cold by design. | +15 | low |
| T3 | test/run:378-390 (discovery order) | harness scheduling | HIGH (wall clock) | Tests reach xargs in discovery order: behavior, reject, examples, ir, torture, **cli**, doc. The slowest tests (CLI, 6..101 s each) start about 80% of the way through, so the run ends on a single long test while the other cores sit idle. | Warm: 160 s total wall, of which release_checks is 101 s. Cold: release_checks 93 s, and the per-test average for behavior is 3.1 s. | Put `cli/` (and `ir`, `torture`) first in the LIST. Better, sort by the last run's durations kept in `$OUTROOT/.durations`. | +3 (static) / +12 (by duration) | none |
| T4 | test/run:47, test/README.md | harness fragility | MEDIUM | The default `RIG_TEST_TIMEOUT` of 120 s is close to the cold time of `cli/release_checks` (93 s at -j10 on an M-series Mac). On a slower machine, or at -j4 cold, it times out spuriously. CI already sets 300. | timings1 | Allow a per-test override (`# timeout: 600` in a CLI script header), or split release_checks into two scripts. T2 does not help a cold run. | +6 | none |
| T5 | test/run:49-52; .github/workflows/test.yml:39-41 | harness portability | MEDIUM | The suite needs GNU `timeout`, which macOS lacks, so a newcomer's first `./test/run` exits 2, and CI spends a `brew install coreutils` step on it. | README line 16 | Fall back to perl, which ships with macOS: `perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" cmd...`, and map exit 142 (SIGALRM) to "timed out" beside 124. Then drop the brew step. | +8 / -4 | low: the process-group kill semantics differ; add `setpgrp` in the perl one-liner |
| T6 | test/run:126-155 (`check_reject`) | reject tests too loose | MEDIUM | A reject test checks only that each `# error:` text is present. It cannot say "and nothing else", so a regression that adds a cascade (a second or third error) never fails. Cascades are the most common diagnostic defect found here (D-cascade rows below). Matching includes notes too, so an `# error:` text can be satisfied by a note. | Probes rs12 (3 errors for one `?`), py16 (3), rg15 (3), py04/rs25/rg61 (a spurious "used before it has a value") | Add `# errors: N`, the exact number of `error:` lines. Or: "when every `# error:` is pinned, no other error may appear". Adopt it for the syntax/ and types/ tests that expect one error. | +10 harness; tests +1 line each | low; a few tests will need their real counts |
| T7 | 29 reject tests listed below | reject expectations too loose | LOW-MED | These 29 tests have only short, unpinned texts (`use of \`rc\` after move`, `cannot move out of`, `would alias the handle`, `does not fit in \`Int\``, `division by zero`, `expected \`String\``, `nested shared type`, `unexpected indentation`, ...). A diagnostic that moves to the wrong line or node still passes. | e.g. reject/ownership/{alias_*,defer_reads_moved,for_loop_move,loop_*,move_field_from_*,use_after_move_in_*}.rig, reject/types/{const_*,int_literal_too_large,field_assign_type_mismatch,shared_of_shared_type}.rig, reject/syntax/{first_line_indented,unterminated_string}.rig, reject/modules/missing_module | Pin `L:C:` on each, run `./test/run reject` | 0 | none |
| T8 | test/run worker (outdir by id) | disk growth | LOW-MED | `.zig-cache/rig-test` grows without bound: about 6 MB per test, **5.2 GB** for one run. Doc test ids are fence *line numbers* (`doc/SPEC/L1234`), so each doc edit that shifts lines orphans the old dirs and rebuilds the moved examples cold. Renamed or deleted tests also leave their dirs behind. | `du`: behavior 3.9 GB, doc 1.1 GB, cli 246 MB | After a full run with no filter, delete `$OUTROOT/*/**` dirs whose id is not in LIST. Optionally key doc outdirs by a content hash instead of the line number. | +8 | low |
| T9 | .github/workflows/test.yml | CI | LOW-MED | (a) `on: push` + `pull_request` runs every PR commit twice, and there is no `concurrency:` group to cancel superseded runs. (b) No `timeout-minutes`: a hung job runs up to the 6 h default (per-test timeouts bound most cases). (c) Nexus v1.0.0 is rebuilt on every run and never cached. (d) CI never caches the per-test Zig caches, so every CI run is fully cold (T10). (e) `zig fmt --check` is not enforced: src/runtime.zig, src/rig.zig and src/resolve.zig are not fmt-clean. | workflow file; `zig fmt --check src build.zig` | `on: push: branches: [main]` + `pull_request`; `concurrency: {group: ${{github.ref}}, cancel-in-progress: true}`; `timeout-minutes: 45`; `actions/cache` for `nexus/zig-out` keyed on the ref; optionally a fmt step that excludes parser.zig. | +10 | none |
| T10 | src/main.zig:304-318; test/run check_behavior | suite speed (structural) | MEDIUM | Cold, about 810 separate Zig Debug compiles dominate: behavior 624 × ~3.1 s (1927 s CPU), doc run-examples 272 × 1.7 s (461 s), examples 36 s. Reject and torture tests total 39 s. Each compile re-analyzes std plus the runtime, then links. `-fno-llvm` is **not** an option on arm64 macOS: 163 s user for one program, and the binary fails with "exec format error". | timings1; single-compile probe | Batch mode: `rig emit` N behavior programs as modules of one driver executable that dispatches on argv; run each test as its own process of that binary, so exit codes, panics and `rig.finish()` stay per test. Fall back to single builds when a batch fails to compile. That amortizes std analysis and linking. Measure first, on 50 tests. | +150..250 | med: module-name collisions and per-test globals; keep single mode as the reference |
| T11 | test/README.md:5 | doc drift | LOW | `./test/run -v known`, the README's own example, exits 2 ("no test matches known") because test/known is empty. | ran it | Say that an empty `known/` selects nothing, or treat a bare kind with zero tests as 0 tests with exit 0. | +1 | none |
| T12 | test/run:140 | harness robustness | LOW | The `msgs` sed assumes the path has no space (`^[^ ]*\.rig:`). A `$TMPDIR` with a space breaks every doc reject test. | code reading | Match `\.rig:([0-9]+:[0-9]+): (error\|  note): ` without anchoring on `[^ ]*`. | 0 | none |
| T13 | coverage | missing tests | MEDIUM | (a) No reject test for a borrow of a temporary held past its statement (T1). (b) Release modes: only 7 programs in cli/release_checks run under --release; no behavior or example test is checked for accept-means-correct in ReleaseSafe. (c) `errdefer`: 1 behavior + 1 reject test; `errdefer` in a function that cannot fail is silently accepted (`probes/y02`). (d) Match guards: 2 behavior tests. (e) Wrapping ops `+% -% *%`: 3 behavior, 1 reject. (f) Newcomer-habit diagnostics: reject tests exist for `&&`, `\|\|`, `**`, `;`, print without parens, `try`, and Rust array syntax. **None** exist for def/fn/func/let/var/class/elif/switch/loop, `//` comments, `&x`, `x as T`, `True`/`None`/`null`, `?` vs `!`, or the lowercase `i32`/`u8`/`bool`/`string`. | grep counts (cov.sh) | (a) with T1. (b) Run `examples/*.rig` once more under `--release=safe` in the suite (a kind `examples-release`, ~9 builds). (f) Add one reject test per habit as the D-fixes land. | tests only (+ ~5 harness for b) | none |
| T14 | test/reject/types/owned_closure_literal_to_borrowed_param.rig:2 | stale comment (AGENTS rule 7) | LOW | "(the checker used to crash)" is history in a test header. No other test header was stale: I grepped for paren-free, `<-`, `pre`, `type X[`, `drop self` and history phrases, and sampled 16 headers. | grep | Delete the parenthetical. | 0 | none |
| T15 | src/diag.zig ordering | diagnostics | LOW | Errors within one pass print in emission order, not source order. `fun f(n: int) -> int` reports col 18 before col 10, and `use of unbound totl` (line 3) prints before `total is assigned but never read` (line 2). The pass order is documented. | rg102, py27 | Stable-sort each pass's errors by position before printing. | +5 | low: pinned tests match by content, not order |
| D1 | src/rig.zig reservedHint/bracketHint | foreign keywords | HIGH (newcomer) | `def`, `fn`, `func`, `function`, `let`, `var`, `class`, `switch`, `elif`, `elsif`, `unless`, `until`, `import` all give `unexpected name \`<next word>\``, pointing at the word **after** the real culprit. `loop`, `do`, `begin`, `forever` give `unexpected indentation` on the **next** line. `impl` gives `unexpected keyword \`impl\``, and `const` gives "expected a statement". None names the fix. | py01, py02, py10, rs01, rs02, rs03, rs04, c01, c02, c03, c08, rs24, x03, z_* | When the parser fails on a token that follows an identifier which starts the statement or declaration, look the identifier up in a table: def/fn/func/function → "declare a function with `fun` (returns a value) or `sub`"; let/var/`let mut` → "Rig has no `let`: write `x = 5` (`x =! 5` for a fixed binding)"; const → "... module constant `X = 5`, fixed local `x =! 5`"; class → `struct`; impl → "methods go inside the `struct` body"; switch → `match`; elif/elsif → `else if`; unless → `if not`; until → `while not`; import → `use`; loop/forever → `while true`; do/begin/then/end → "blocks are indented; drop `do`". For `unexpected indentation`, report at the previous line when that line is a lone name. | +50 | low |
| D2 | src/rig.zig lexer | `//` and `/* */` comments | HIGH (newcomer) | `// hello` gives `unexpected \`/\`; expected a statement`, with no mention that comments start with `#`. This is the single most common habit from C, JS, Rust and Zig. | z_comment_slash, z_comment_block | When the error token is `/` and the next character is `/` or `*`: "comments start with `#`". | +4 | none |
| D3 | src/typecheck.zig:2681-2683 | wrong hint: Rust `?` | HIGH | `f(1)?` inside a `-> Int!` function prints **3 errors**. The first says to make `g` return an optional, which is the wrong direction: the fix is `f(1)!`. In `sub main`, `f()?` says to make `main` return an optional, which `main` cannot do. `f()?.x` gets 2 errors. | rs12, rg34, rg71, x09 | If the enclosing function is fallible, or the operand is a fallible call: "`?` propagates `none`; to propagate a failure write `f(1)!`". In `main` or a sub: "handle the missing value: `f() ?? fallback` or `if f() as x`". Emit only that one error, and skip the "must be wrapped" and "`?` needs an optional" follow-ons for the same node. | +15 | low |
| D4 | src/resolve.zig:1492,1685,1945; src/typecheck.zig:2085, 3141-3155, 5537-5540, 5892 | no did-you-mean | HIGH (newcomer) | Misspelled locals, functions, fields, methods, types, keyword arguments, and keywords (`retrun 1` gives "unexpected `1`") get no suggestion. Neither do foreign names: True/False, None/null/nil, len(), range(), str(), println, this, pass, Some, `i32`/`u8`/`bool`/`string`/`str`/`int`/`f64`/`void`, List/Result/Option, `.length`, `v.len()`, `s.clone()`, `P.new`, `vec!`. | py04-06, py11, py13, py26-31, rs13-17, rs19-21, rg24, rg43, rg99-103, rg110, c06, c15, x10-11, x16 | (1) A fixed table of foreign spellings (True→`true`, None/null→`none`, len(x)→`x.len`, range(n)→`0..n`, i32→`I32`, u8→`U8`, bool→`Bool`, string/str→`String`, int→`Int`, f64→`F64`/`Float`, void→"declare a `sub`", this→`self`, Some(x)→`x`, Result[T,E]→`T!`, Option[T]→`T?`, `.clone()`→`+x`, `.length`/`.len()`→`.len`, `P.new(...)`→`P(...)`). (2) Edit distance ≤ 2 (or case-insensitive) among the visible names, fields, methods, types and enum variants: "did you mean `total`?". A bare `red` where a `C` is expected → "`.red`". | +70 | low |
| D5 | src/typecheck.zig:2085 (inside a method) | `age` for `self.age` | HIGH (newcomer) | `age + 1` and `age += 1` in a method give `use of unbound name \`age\``. Calling `double()` for `self.double()` gives the same. | py09, x15, rg63 | When the enclosing function has a `self` receiver and `name` is a field or method of `Self`: "... ; did you mean `self.age`?" | +12 | none |
| D6 | typecheck call-argument mismatch | missing `?x` / `!x` at a call site | HIGH (newcomer) | `f(s)` where `?S` is expected gives `type mismatch: expected \`?S\`, got \`S\``, and `bump(x)` for `!Int` gives `expected \`!Int\`, got \`Int\``. Neither names the sigil to add. This is the core Rig mistake. | rg01, rg02 | When the expected type is `?T`/`!T` and the argument is a place of type `T`: "pass a read borrow: `f(?s)`" / "pass a write borrow: `bump(!x)`". | +12 | none |
| D7 | src/rig.zig detachedPrefix:1304-1317 | wrong hint: `i++` | MEDIUM | `i++` gives "a prefix `+` touches its operand: write `+x`", which suggests a clone. | c04 | When the character before the sigil is the same sigil (`++`, `--`): "Rig has no `++`; write `i += 1`". | +5 | none |
| D8 | typecheck `as` outside a condition | `x as U8` | MEDIUM | `y = x as U8` gives "`as` binds only in the condition of an `if` or `while` block ...", which does not mention conversion. | rs07 | When the right side of `as` names a numeric type: "to convert, write `U8(x)`". | +5 | none |
| D9 | parser | `&x`, `&T`, `&mut`, `*n += 1` | MEDIUM | Each gives `unexpected \`&\`` (or `unexpected \`+=\``) with no mapping to Rig's sigils. | rs05, rs06, c12, z_ref_mut, x07, x08 | For `&`: "Rig borrows with `?x` (read) or `!x` (write); types `?T` / `!T`". For `*n += 1` on a write borrow: "assign through a write borrow directly: `n += 1`". | +8 | none |
| D10 | parser | `=` vs `==` / `:` | MEDIUM | `if x = 1` gives `unexpected \`=\``; `P(x = 1)` gives `unexpected \`=\``; `x === 1` gives "unexpected `=`". | py36, rg33, c09 | In a condition: "compare with `==`". In call parentheses after a name: "a keyword argument is written `x: 1`". For `===`: "use `==`". | +8 | none |
| D11 | parser | wrong return/arrow spellings | MEDIUM | `sub f -> Int` gives `unexpected \`->\``; `fun f(n: Int): Int` gives `unexpected \`:\``; `fun add(a: Int) Int` gives `unexpected name \`Int\``; `fun add(Int a)` gives `unexpected name \`a\``; `pub fn f` gives "expected `:`, `=!` or `=`". | rg14, rg111, x06, rs28, rg74, rg73, rs23 | `->` after a sub's signature: "a `sub` returns nothing; declare `fun f(...) -> Int`". `:` after `)`: "the return type follows `->`". A type name after `)`: "write `-> Int`". `Int a`: "parameters are `name: Type`". | +12 | none |
| D12 | parser | `{`, `? :`, `(x) =>`, `lambda`, f-strings, `is` | MEDIUM | `{` gives "invalid character"; `a ? b : c` gives "unexpected `1`"; `(x) => x + 1` gives "unexpected `=>`"; `lambda x:` gives "unexpected name `x`"; `f"..."` gives "unexpected string"; `x is none` gives "unexpected name `is`". | py20, rs09, rg112, z_struct_brace, py40, rg92, py23, py12, py22, rg57 | `{`: "blocks are indented; Rig has no braces". `? :`: "a conditional is `a if cond else b`". `=>`/lambda: "a closure is `\|x\| x + 1`". `f"`: "no interpolation: `print(\"hi\", name)`". `is`: "compare with `==` (`x == none`)". | +15 | none |
| D13 | parser | `while cond:` | MEDIUM | `while n < 3:` reads `:` as the start of a while *step*, so the error lands on the body's line: "unexpected indentation; expected an assignment or a call". (`for ...:`, `if ...:`, `match ...:` say "unexpected `:`; expected an indented block", which is accurate but names no fix.) | z_while_colon, py03, z_for_colon, z_match_colon | When a `:` ends the line after a condition: "drop the `:`; the indented block starts the body". Do the same for the while step when nothing follows `:`. | +8 | low |
| D14 | parser openRange:1195 | wrong hint: `0..=3` | MEDIUM | "a range needs an end; only a slice leaves a side open" — but the user wrote an inclusive range. | rg54 | When `..` is followed by `=`: "ranges exclude their end; write `0..4`". | +4 | none |
| D15 | typecheck self handling | wrong hint + cascade: `sub bump(self)`, `fun get -> Int` using `self` | MEDIUM | `sub bump(self)` gives 3 errors, and the third says "method `bump` has no `self` receiver; call as `Counter.bump(...)`", which is wrong because it does have one. A method with no receiver that uses `self` gives "unbound name `self`" plus the same wrong call hint. | py16, rg41 | Treat a sigil-less `self` as `?self` for the rest of checking (report once). For an unbound `self` inside a struct member: "add a receiver: `fun get(?self) -> Int`". Suppress the call-site hint when the declaration already errored. | +12 | low |
| D16 | typecheck | missing-return message | MEDIUM | A `fun` whose last statement is an `if` without `else` gives "`if` used as a value requires an `else` branch", pointed at `return 1`. The real problem is a path with no return value. | py37 | "`f` must return an `Int` on every path; this `if` has no `else`". Point at the `if`. | +8 | low |
| D17 | typecheck | cascades | MEDIUM | (a) A local whose initializer failed to resolve gets "`x` is used before it has a value" at each use. (b) `fun f` with no `-> T` adds "does nothing as a statement" and "`print` needs a value". (c) `n = 5` on a `?Int` param also reports a type mismatch. (d) A misspelled use makes the real local "assigned but never read". (e) `Vec[S]` of an owning `S` also rejects `xs[0]`. | py04, rs25, rg61, rg15, rg114, py27, rg86 | Poison a symbol whose declaration or initializer errored: skip "used before value" and "never read" for it, and skip checks on expressions of the error type. | +12 | low |
| D18 | typecheck method/field on builtins | `v.len()`, `s.len()` | MEDIUM | "no method `len` on type `Vec`" / "type `String` has no method `len`". | py07, x10, x12 | When a method is missing but a field of that name exists: "`len` is a field: `v.len`". | +6 | none |
| D19 | typecheck `?` / optional operands | optional used as a value | LOW-MED | `x + 1` with `x: Int?` gives "operator `+` requires numeric operands; got `Int?`", and `v.get(0) + 1` the same. | rg13, w_optional_if_as, w_vec_get_plus | Append: "take the value out: `x ?? 0`, or `if x as v`". | +5 | none |
| D20 | typecheck shared/weak | wrong or absent hints | LOW-MED | Assigning a `Cell` field through `*S` says "Use an interior-mutable `Cell[T]`", but the field already is one; the fix is `s.n.set(2)`. `w.n` / `w.get()` on `~S` gives "has no field/method", with no hint to `upgrade`. `!c.bump()` where `bump(?self)` says "for negation use `not`". | w_shared_field_write_cell, rg22, x04, rs18 | Cell field: "call `s.n.set(...)`". Weak: "upgrade it first: `if w.upgrade() as s`". Non-writing receiver: "`bump` takes `?self`: drop the `!`, or declare `bump(!self)`". | +10 | none |
| D21 | parser | one parse error per file | LOW | The parser stops at the first parse error (x01 has two independent errors and shows one), so a newcomer who brings many habits sees them one per run. | x01 | Long term: resynchronize at the next line with the same or lower indentation and keep collecting parse errors (drop errors that follow on the same line). | +60..120 | med |
| D22 | typecheck numeric | Int to Float | LOW | `x: Float = a / b` (Int variables) gives a bare "type mismatch: expected `Float`, got `Int`". `a + b` (Int, Float) gives "different types". Neither names `Float(a)`. | w_int_var_div_float, rg28 | Append "convert with `Float(a)`". | +5 | none |

## Suite timing (where the time goes)

| kind | n | cold CPU·s (avg) | warm CPU·s (avg) |
|---|---|---|---|
| behavior | 624 | 1927 (3.09) | 243 (0.39) |
| doc | 272 | 461 (1.70) | 33 (0.12) |
| cli | 16 | 383 (23.96) | **292 (18.2)**: cold every run because of T2 |
| reject | 721 | 38 (0.05) | 56 (0.08) |
| examples | 9 | 36 | 2 |
| torture / ir | 27 | 1 | 1 |

Cold, the time is almost all Zig Debug compiles, about 1.3 s of user CPU
per program; T10 is the structural lever. Warm, the time is almost all
CLI tests (T2, T3). With T2 and T3, a warm run should come down to
roughly the behavior/reject floor, about 30-40 s at -j10 on an idle machine.
A single warm `rig run` is 0.07 s. The unit tests (`zig build test`) run
in parallel and are not on the critical path.

Harness checks that passed: the lock and stale-lock takeover,
worker-died detection, id de-duplication, CRLF handling in `# expect:`,
the rule that a panic test still diffs stdout when an expect block
exists, doc-fence validation (unknown words, unterminated blocks), and
per-test output dirs that keep `.zig-cache`. No misfiled directives:
no behavior test has an `# error:` and no reject test has an
`# expect:`. No duplicate test bodies (only shared helper modules).
Every doc program with `sub main` has an `output` block except two
(docs/INTERNALS.md:289, test/README.md:45), so nearly all are run.
test/known is empty, which is fine (see T11).

## Diagnostics scorecard

Grades: **A**, right place, names the fix. **B**, right place and clear, but
no fix. **C**, vague or generic. **D**, misleading position or a cascade.
**F**, the hint is wrong. None of the wrong hints leads to a program that
compiles and does the wrong thing: each wrong hint (F) leads to another
error. The one silent-wrong acceptance is under LANGUAGE QUESTIONS (`for i, x`).

| # | mistake | message (abridged) | grade | proposed wording |
|---|---|---|---|---|
| py01 | `def add(...)` | unexpected name `add` (1:5) | D | `def` is not Rig: declare `fun add(...) -> T`, or `sub` for no value |
| py02 | `elif x > 1` | unexpected name `x` | D | Rig writes `elif` as `else if` |
| py03 | `if x > 1:` | unexpected `:`; expected an indented block | B | ... drop the `:` |
| py04 | `True` | unbound name `True` + "`ok` is used before it has a value" | D | unbound `True`; did you mean `true`? (no cascade) |
| py05 | `None` | unbound name `None` | C | did you mean `none`? |
| py06 | `len(xs)` | unbound name `len` | C | a length is a field: `xs.len` |
| py07 | `v.len()` | no method `len` on type `Vec` | C | `len` is a field: `v.len` |
| py08 | `!v.append(1)` | no method `append` on `Vec` | C | did you mean `push`? |
| py09 | `age + 1` in a method | unbound name `age` | C | did you mean `self.age`? |
| py10 | `class Person` | unexpected name `Person` | D | declare a type with `struct Person` |
| py11 | `range(5)` | unbound name `range` | C | a range is `0..5` |
| py12 | `f"hi {name}"` | unexpected `"hi {name}"` | C | no string interpolation: `print("hi", name)` |
| py13 | `pass` | unbound name `pass` | C | Rig has no `pass` (+ how to write an empty body) |
| py14 | `a && b` | `&&` is not a Rig operator; use `and` | A | — |
| py15 | `if !a` | `!` is a write borrow; use `not` for negation | A | — |
| py16 | `sub bump(self)` | receiver type required + 2 cascades, one wrong ("call as `Counter.bump`") | F | one error: write `!self` (or `?self`) |
| py17 | `"x" + "y"` | `+` requires numeric operands; got String | B | + "print takes several values: `print(a, b)`" |
| py18 | tuple return `(Int, Int)` | unexpected `,` | C | Rig has no tuples; return a struct |
| py19 | `List[Int]` | unbound type `List` | C | did you mean `Vec[Int]`? |
| py20 | `{"a": 1}` | invalid character | C | Rig has no braces or dict literals |
| py21 | `while True` | unbound name `True` | C | did you mean `true`? |
| py22 | `x is none` | unexpected name `is` | C | compare with `x == none`, or bind with `if x as v` |
| py23 | `lambda x: x+1` | unexpected name `x` | D | a closure is `\|x: Int\| x + 1` |
| py24 | `s.upper()` | String has no method `upper` | B | — |
| py25 | `print "hi"` | unexpected "hi"; `print` is called with parentheses | A | — |
| py26 | `str(n)` | unbound name `str` | C | print takes numbers directly: `print(n)` |
| py27 | typo `totl` | unbound `totl` + "`total` assigned but never read" | D | did you mean `total`? (no cascade) |
| py28 | typo `compte(3)` | unbound name `compte` | C | did you mean `compute`? |
| py29 | `p.z` | no field `z` on `Point` + note | B | + did you mean `x`/`y`? (list the fields) |
| py30 | `p.dubble()` | no method `dubble` + note | B | did you mean `double`? |
| py31 | `x: Integer` | unbound type `Integer` | C | did you mean `Int`? |
| py32 | `Point(x: 1, yy: 2)` | no field `yy` + "missing field `y`" | B | did you mean `y`? (merge the two) |
| py33 | `Point(1, 2)` | a type with more than one field sets them by name: `Point(x: ...)` | A | — |
| py34 | tab indent | tab in indentation; indent with spaces | A | — |
| py35 | 3-space indent | unexpected indentation | B | + "indent by the block's width (2 here)" |
| py36 | `if x = 1` | unexpected `=` | C | compare with `==` |
| py37 | missing return in `if` | "`if` used as a value requires `else`" at `return 1` | D | `f` must return `Int` on every path |
| py38 | `x: Float = 7 / 2` | `7 / 2` divides whole numbers (3); for 3.5 write `7.0 / 2` | A | — |
| py39 | `2 ** 3` | `**` is not a Rig operator | B | + how to write a power |
| py40 | `x > 1 ? 1 : 2` | unexpected `1` | C | a conditional is `1 if x > 1 else 2` |
| rs01 | `fn add` | unexpected name `add` | D | declare functions with `fun` |
| rs02 | `let x = 5` | unexpected name `x` | D | Rig has no `let`: `x = 5` |
| rs03 | `let mut x` | unexpected name `mut` | D | no `let`/`mut`: `x = 5` is reassignable |
| rs04 | `impl P` | unexpected keyword `impl` | C | methods go inside the `struct` body |
| rs05 | `x: &Int` | unexpected `&`; expected a type | C | a read borrow is `?Int`, a write borrow `!Int` |
| rs06 | `f(&s)` | unexpected `&` | C | pass a read borrow: `f(?s)` |
| rs07 | `x as U8` | `as` binds only in the condition of `if`/`while` | C | to convert, write `U8(x)` |
| rs08 | `x = 1;` | Rig ends a statement at the end of its line; drop the `;` | A | — |
| rs09 | `sub main {` | invalid character | C | blocks are indented; Rig has no braces |
| rs10 | `=> print("r"),` | unexpected `,` | B | drop the `,` after an arm |
| rs11 | `_ =>` | accepted | ok | — |
| rs12 | `f(1)?` in `-> Int!` | 3 errors; the first says to make `g` optional | F | `?` propagates `none`; propagate a failure with `f(1)!` |
| rs13 | `Result[Int, String]` | unbound type `Result` | C | a fallible result is `Int!` |
| rs14 | `Option[Int]` | unbound type `Option` | C | an optional is `Int?` |
| rs15 | `Some(n)` | unbound name `Some` | C | a value is its own `Some`: return `n` |
| rs16 | `.unwrap()` | cannot call `unwrap` on `Int?`; use `x ?? fallback` | A | — |
| rs17 | `println!("hi")` | unbound name `println` | C | did you mean `print`? |
| rs18 | `!c.bump()` with `bump(?self)` | 2 errors; "for negation use `not`" | D | `bump` takes `?self`: declare `bump(!self)` |
| rs19 | `i32` | unbound type `i32` | C | did you mean `I32`? |
| rs20 | `u8` | unbound type `u8` | C | did you mean `U8`? |
| rs21 | `s.clone()` | no method `clone` on `S` | C | clone with `+s` (handles and plain values) |
| rs22 | `trait Show` | unexpected keyword `trait` | B | + "`trait` is reserved; traits are not supported yet" |
| rs23 | `pub fn f` | unexpected name `f`; expected `:`, `=!` or `=` | D | declare functions with `fun` |
| rs24 | `loop` | unexpected indentation (next line) | D | Rig has no `loop`; write `while true` |
| rs25 | `vec![1,2,3]` | unbound `vec` + "used before value" cascade | D | a Vec starts empty: `v: Vec[Int] = Vec()` then `!v.push(...)` |
| rs26 | `struct Box<T>` | unexpected `<`; expected an indented block or `[` | B | type parameters go in brackets: `struct Box[T]` |
| rs27 | `Vec<Int>` | unexpected `<` | C | type arguments go in brackets: `Vec[Int]` |
| rs28 | `fun f(n: Int): Int` | unexpected `:` | C | the return type follows `->` |
| c01 | `var x = 5` | unexpected name `x` | D | Rig has no `var`: `x = 5` |
| c02 | `const x = 5` | unexpected keyword `const` | C | a fixed local is `x =! 5` |
| c03 | `switch n` | unexpected name `n` | D | Rig's `switch` is `match` |
| c04 | `i++` | a prefix `+` touches its operand: write `+x` | F | Rig has no `++`; write `i += 1` |
| c05 | C `for (;;)` | unexpected `(`; expected a name | C | `for i in 0..3` |
| c06 | `null` | unbound name `null` | C | did you mean `none`? |
| c07 | `c: U8 = 'a'` | expected `U8`, got `String` | B | `'a'` is a String in Rig |
| c08 | `function f(x)` | unexpected name `f` | D | declare functions with `fun` |
| c09 | `x === 1` | unexpected `=`; expected an operand | C | use `==` |
| c10 | `try f()` | `try` blocks are reserved: propagate with `e!` ... | A | — |
| c11 | `f() orelse 0` | unexpected name `orelse` | C | Rig's `orelse` is `??` |
| c12 | `*Int` param, `&x` | unexpected `&` | C | see rs06 |
| c13 | `5u8` | malformed number ... | B | a typed literal: `x: U8 = 5` |
| c14 | `007` | a decimal number has no leading zero | A | (+ `0o7` for octal) |
| c15 | `-> void` | unbound type `void` | C | declare a `sub` for no value |
| c16 | `return 1` in a sub | a `sub` returns no value; remove the value or declare a `fun` | A | — |
| c17 | `int xs[3]` | unexpected name `xs` | C | `xs: [3]Int = [1, 2, 3]` |
| c18 | `f() \|\| 0` | `\|\|` is not a Rig operator; use `or` | F-ish | for an optional on the left: "a fallback is `??`" |
| c19 | `else if` | accepted | ok | — |
| rg01 | `f(s)` for a `?S` param | type mismatch: expected `?S`, got `S` | C | pass a read borrow: `f(?s)` |
| rg02 | `bump(x)` for a `!Int` param | expected `!Int`, got `Int` | C | pass a write borrow: `bump(!x)` |
| rg03 | use after `<s` | use of `s` after move + note | A | — |
| rg04 | `take(s)` of an owning value | would alias an owning value ... Use `<s` | A (long) | shorten: "`take` owns its argument: move it with `<s`" |
| rg05 | `v.push(1)` | requires a write-borrowed receiver; use `!receiver.push(...)` | A | name it: `!v.push(1)` |
| rg06 | `for x in v` | write `for x in ?v` | A | — |
| rg07 | `while !done` | `!` is a write borrow; use `not` | A | — |
| rg08 | unused local | assigned but never read; ... `_ = ...` | A | — |
| rg09 | loop var shadows | shadows the local `x`; use a different name + note | A | (+ "or `new`") |
| rg10 | reassign `=!` | cannot reassign fixed binding + note | A | — |
| rg11 | bare fallible call | must be wrapped with `!` or `catch` + note | A | — |
| rg12 | `f()!` on an infallible call | `!` needs a fallible operand | A | — |
| rg13 | `x + 1`, `x: Int?` | `+` requires numeric operands; got `Int?` | B | + `x ?? 0` / `if x as v` |
| rg14 | `sub f -> Int` | unexpected `->` | C | a `sub` returns nothing: `fun f -> Int` |
| rg15 | `fun f` with no `-> T` | 3 errors (2 cascades) | D | one error |
| rg16 | `<s` of a `?S` param | expected `S`, got `?S`; only a number ... is copied | B | — |
| rg17 | return `?local` | returned borrow does not originate from a borrowed parameter + note | A | — |
| rg18 | `take(< s)` | a prefix `<` touches its operand: write `<s` | A | — |
| rg21 | assign through `*S` | cannot assign through shared handle ... Cell | A | — |
| rg22 | `w.n` on `~S` | `~S` has no field `n` | C | upgrade it first: `if w.upgrade() as s` |
| rg23 | non-exhaustive statement match | accepted (documented) | — | LANGUAGE QUESTION 3 |
| rg24 | `c: C = red` | unbound name `red` | C | did you mean `.red`? |
| rg25 | write through `?self` | cannot assign through a read borrow; take `!T` | A | name it: declare `!self` |
| rg26 | `c.bump()` for `!self` | requires a write-borrowed receiver; use `!receiver.bump(...)` | A | — |
| rg27 | `s[0] = 65` | cannot assign to a byte of a String; read-only | A | — |
| rg28 | `Int + Float` | operands have different types | B | convert: `Float(a) + b` |
| rg29 | wrong arity | `add` expects 2 arguments, got 1 | B | + show the signature |
| rg30 | wrong arg type | type mismatch expected `Int`, got `String` | A | — |
| rg32 | `fun main` | `main` must be `sub main` ... | A | — |
| rg33 | `P(x = 1)` | unexpected `=` | C | a keyword argument is `x: 1` |
| rg34 | `f()?` in main | requires `main` to return an optional | F | handle it: `f() ?? fallback` / `if f() as x` |
| rg35 | `if x as y`, x: Int | `as` binds the value inside an optional; this has type `Int` | A | — |
| rg37 | `max<Int>(1, 2)` | unexpected `>` | C | type arguments go in brackets: `max[Int](1, 2)` |
| rg38 | `v: Vec[Int] = [1,2,3]` | expected `Vec[Int]`, got `[3]Int` | B | — |
| rg39 | push on an array | `![3]Int` has no method `push` | B | an array has a fixed length; use `Vec` |
| rg40 | `xs[-1]` | index `-1` is out of bounds ... | A | — |
| rg41 | `self` in a method with no receiver | unbound `self` + wrong "call as `P.get`" | F | add a receiver: `fun get(?self)` |
| rg42 | `new P(x: 1)` | unexpected name `P` | C | construct with `P(x: 1)`; `new` rebinds a name |
| rg43 | `P.new(x: 1)` | no method `new` on `P` | C | construct with `P(x: 1)` |
| rg44 | `"ab" * 3` | `*` requires numeric operands | B | — |
| rg45 | `two(!x, !x)` | second write borrow + note | A | — |
| rg46 | move in a loop | use after move, in a previous iteration | A | — |
| rg47 | `x: Int` with no value | unexpected end of line; expected `=!` or `=` | B | every binding needs a value: `x: Int = 0` |
| rg49 | `catch \|e\| 0`, e unused | `e` bound but never read; name it `_` | A | — |
| rg50 | `sub main(args)` | `main` must be `sub main` ... no parameters | A | — |
| rg51 | `f().x` on `P?` | cannot access `x` on optional; `x ?? fallback` | A- | + `if f() as p` |
| rg53 | `for i, x in xs` | accepted, **i is the element** | — | LANGUAGE QUESTION 1 |
| rg54 | `0..=3` | a range needs an end; only a slice leaves a side open | F | ranges exclude the end; write `0..4` |
| rg55 | `x: Int = 1 + 2` default | a default field value must be a literal ... | A | — |
| rg56 | `if n` (Int) | expected `Bool`, got `Int` | B | + `n != 0` |
| rg57 | `a is "x"` | unexpected name `is` | C | compare with `==` |
| rg60 | unclosed `(` | unexpected name `y` + note: `(` opened here is not closed | A | — |
| rg61 | two unbound names | 2 errors + 2 "used before value" cascades | D | poison (D17) |
| rg62 | `else` without `if` | unexpected keyword `else` | B | — |
| rg63 | `double()` in a method | unbound name `double` | C | did you mean `self.double()`? |
| rg64 | `n % 2` as Bool | expected `Bool`, got `Int` | B | + `n % 2 == 0`? |
| rg67 | assign to a param | parameters are immutable (bind a copy with `new n = n`, or take `n: !T`) | A | — |
| rg68 | `use mathx` | cannot read module `mathx` (mathx.rig): no such file | A | — |
| rg69 | `import math` | unexpected name `math` | D | Rig imports with `use math` |
| rg70 | `f()!` on an optional | `!` needs a fallible operand; `Int?` cannot fail | B | + "propagate `none` with `?`" |
| rg71 | `f()?` on a fallible call | 2 errors | D | one error: "propagate a failure with `!`" |
| rg72 | `catch` on an optional | `catch` needs a fallible expression | B | + "an optional's fallback is `??`" |
| rg73 | `fun add(Int a)` | unexpected name `a` | C | parameters are `name: Type`: `a: Int` |
| rg74 | missing `->` | unexpected name `Int` | C | write `-> Int` |
| rg75 | `struct P:` | unexpected `:`; expected an indented block or `[` | B | — |
| rg76 | `x: Int,` | unexpected `,`; expected the end of the line | A- | — |
| rg77 | `while ... do` | unexpected name `do` | C | drop `do` |
| rg78 | `if ... then` | unexpected name `then` | C | drop `then` |
| rg79 | `end` | unbound name `end` | C | blocks end at the dedent; drop `end` |
| rg80 | duplicate field | duplicate member + note | A | — |
| rg81 | missing ctor field | missing field `y` + note | A | — |
| rg82 | `x.abs()` | `Int` has no method `abs` | B | — |
| rg83 | `1.` | unexpected end of line; expected a name | C | write `1.0` |
| rg84 | nested `fun` | declarations are only allowed at module level | B | + "a closure `f = \|n: Int\| ...` works here" |
| rg85 | `Int("12")` | `Int(x)` converts a number; `x` has type `String` | A | — |
| rg86 | `Vec[S]` of an owning S | long requirement text + cascade on `xs[0]` | B/D | — |
| rg87 | `<t.s` | cannot move out of `t.s` ... `replace(!t.s, v)` | A | — |
| rg88 | `a = 1; b = 2` | ... put each statement on its own line | A | — |
| rg89 | `-> !Int` for a fallible return | type mismatch expected `!Int`, got `Int` | C | "`!Int` is a write borrow; a fallible result is `Int!`" |
| rg90 | `return "bad"` in `Int!` | expected `Int!`, got `String` | C | + "fail with an error set: `error E` + `return E.bad`" |
| rg92 | `(x) => x + 1` | unexpected `=>` | C | a closure is `\|x: Int\| x + 1` |
| rg93 | closure param without a type | needs a type: annotate or give the type ... | A | — |
| rg94 | `bump(!5)` | cannot write-borrow a temporary ... bind it to a name first | A | — |
| rg95 | unused `for i` | bound but never read; name it `_` | A | — |
| rg96 | `x: U8 = 256` | `256` does not fit in `U8` (0..255) | A | — |
| rg97 | `s[0] == "a"` | cannot compare `U8` with `String` | B | (no byte literal exists; see syntax-review) |
| rg98 | `x Int = 5` | unexpected name `Int` | C | an annotation is `x: Int = 5` |
| rg99 | `bool` | unbound type `bool` | C | did you mean `Bool`? |
| rg100 | `string` | unbound type `string` | C | did you mean `String`? |
| rg101 | `str` | unbound type `str` | C | did you mean `String`? |
| rg102 | `int` twice | 2 errors, out of source order | C/D | did you mean `Int`? |
| rg103 | `f64` | unbound type `f64` | C | did you mean `F64` / `Float`? |
| rg104 | `return 1, 2` | unexpected `,` | C | Rig has no tuples |
| rg105 | use after move | use after move + note | A | — |
| rg107 | `x = f() catch` | unexpected end of line | B | a `catch` needs a fallback value |
| rg108 | `elsif` | unexpected name `x` | D | `else if` |
| rg109 | `c.v.push(1)` | requires a write-borrowed receiver | A | — |
| rg110 | `this.x` | unbound name `this` | C | did you mean `self`? |
| rg111 | `sub f -> ()` | unexpected `->` | C | a `sub` returns nothing; drop `-> ()` |
| rg112 | `if (x == 1) {` | invalid character | C | blocks are indented; no braces |
| rg113 | `x: U8 = -1` | `-1` does not fit in `U8` (0..255) | A | — |
| rg114 | assign a `?Int` param | immutable ... + type-mismatch cascade | D | one error |
| rg115 | `name == "x"` as a statement | 3 errors | D | unbound `name` once |
| x01 | two parse errors | only the first is shown | B | D21 |
| x03 | `loop` | unexpected indentation (next line) | D | `while true` |
| x04 | `w.get()` on `~S` | `~S` has no method `get` | C | `w.upgrade()` |
| x05 | empty `sub nothing` | unexpected end of line | C | "a body needs at least one statement" |
| x06 | `sub f(n) -> Int` | unexpected `->`; expected an indented block or `!` | C | `fun f(n: Int) -> Int` |
| x07 | field `&String` | unexpected `&`; expected a type | C | `?String` |
| x08 | `*n += 1` on `!Int` | unexpected `+=` | C | assign through a write borrow directly: `n += 1` |
| x09 | `f()?.x` in main | 2 errors, a wrong optional-return hint | F | `(f() ?? fb).x` / `if f() as p` |
| x10 | `s.len()` | String has no method `len` | C | `len` is a field: `s.len` |
| x11 | `a.length` | `[2]Int` has no field `length` | C | did you mean `len`? |
| x14 | `"n = " + n` | `+` requires numeric operands | B | `print("n =", n)` |
| x15 | `age += 1` in a method | unbound name `age` | C | `self.age` |
| x16 | `retrun 1` | unexpected `1` | D | did you mean `return`? |
| x17 | param `n: Int!` | fallible type only as a return type + cascade | B/D | "a write borrow is `!Int`" |
| x18 | `S?` vs `?S` | 2 accurate errors | B | + "`?S` borrows; `S?` is optional" |
| x20 | `+s` of a struct | `+x` cannot clone a `S`; only handles and plain values | A | — |
| z_comment_slash | `// hi` | unexpected `/`; expected a statement | C | comments start with `#` |
| z_comment_block | `/* hi */` | same | C | same |
| z_while_colon | `while n < 3:` | unexpected indentation; expected an assignment or a call (next line) | D | drop the `:` |
| z_for/match/enum colon | `for ...:` etc. | unexpected `:`; expected an indented block | B | + "drop the `:`" |
| z_do/begin/forever | `do` / `begin` | unexpected indentation (next line) | D | see D1 |
| z_case_arm | `case 1 =>` | unexpected `1` | C | arms have no `case`: `1 => ...` |
| z_decorator | `@inline` | the pin sigil `@x` is reserved ... | B | — |
| z_mut_param | `mut n: Int` | unexpected `n` | C | parameters are immutable; take `n: !Int` to write |
| z_ref_mut | `&mut Int` | unexpected `&` | C | `!Int` |
| z_struct_brace | `struct P {` | invalid character | C | blocks are indented |
| z_try_except | `try:` | `try` blocks are reserved ... | A | — |
| z_string_concat | `s += "b"` | `+=` requires a numeric target | B | — |
| z_func / z_unless / z_until / z_with | `func`, `unless`, `until`, `with` | unexpected name `<next>` | D | see D1 |
| w_bump_via_read_param | `!c.bump()` on a `?C` param | cannot write-borrow through a read borrow `?C` | B | take `c: !C` |
| w_push_in_loop | push while iterating | cannot write-borrow `v` while a read borrow is live + note | A | — |
| w_closure_no_capture | outer local in a closure | capture it (`\|+n\|` ... `\|~n\|`) | A | — |
| w_int_var_div_float | `Float = a / b` (Ints) | expected `Float`, got `Int` | C | `Float(a) / Float(b)` |
| w_shared_field_write_cell | assign a Cell field through `*S` | "Use an interior-mutable `Cell[T]`" (it already is one) | F | `s.n.set(2)` |
| w_optional_if_as / w_vec_get_plus | `f() + 1` on an optional | `+` requires numeric operands; got `Int?` | B | + `?? 0` |
| y02 | `errdefer` in `sub main` | accepted (dead code) | — | LANGUAGE QUESTION 2 |
| y03 | `break :outer` with no label | names no enclosing loop or block | A | — |
| y04 | a move in `errdefer` | a `defer` body cannot move or drop `r` | A | (says `defer` for `errdefer`) |

Tally, about 190 probes: A ≈ 55, B ≈ 40, C ≈ 60, D ≈ 25, F ≈ 9.
The C and D rows sit almost entirely in the parser (foreign keywords)
and in unbound-name resolution (no did-you-mean). D1, D2, D4, D5 and D6
together would turn about 60 C/D rows into A. The F rows: py16, rs12,
c04, rg34, rg41, rg54, x09, w_shared_field_write_cell, and (partially)
c18's `||`, whose hint `or` is wrong when the left side is an optional.

## LANGUAGE QUESTIONS (surface is frozen; listed only)

1. **`for x, i in xs` order.** Python (`enumerate`), Go (`for i, x := range`), and Rust
   (`.enumerate()` yields `(i, x)`) all put the index first. Rig puts it
   second, so `for i, x in xs` over `[10, 20]` silently prints
   `10 0 / 20 1` (probes/rg53). This is the only silent-wrong newcomer
   program I found. Options: keep it, and add a diagnostic when the
   second binding is named `x`/`item`/`elem` or the first `i`/`idx`/
   `index` (a lint, which is heuristic); or change the order.
2. **`errdefer` in a function that cannot fail** is accepted and never runs
   (probes/y02). Reject it ("this function cannot fail; use `defer`")?
3. **A non-exhaustive statement `match` over an enum** silently runs no arm
   for the missing variants (rg23; documented in SPEC §7). Rust and Zig
   users expect exhaustiveness. Require `_ =>` (or all variants) for a
   statement match over an enum, and keep the partial form for
   integers and Bool?
4. **Lifetime of a borrow of a temporary** (T1): state in SPEC §8 "Temporaries"
   that `?e` of a temporary lives only to the end of its statement, and
   make that rule the one the ownership checker enforces.
