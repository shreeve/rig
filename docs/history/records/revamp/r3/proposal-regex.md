# Proposal: std.regex, a linear-time matching engine (NEEDS 24)

For the design owner. Status: proposal; no code changed. **Priority: after
traits and Map/Set** (`proposal-traits-map.md`); nothing in Trig is blocked
now, because semver's seven patterns are hand-written matchers that work.
Evidence is `misc/TypeScript/tsc/internal`, non-test code.

## 0. Recommendation

1. Write it **in Rig** (`std/regex.rig`), not as a Zig wrapper: Zig's std has no
   regex, so a wrapper means writing the engine in Zig anyway, outside the
   sanitizer-checked, dogfooded language.
2. Engine: a **Pike VM** (parse, compile to a small program, simulate all
   threads in lockstep) with captures. O(len(input) x len(program)), no
   backtracking, no exponential case. A lazy DFA for `is_match`/`find` bounds
   is a phase 2, only if a measured workload needs it.
3. Syntax: RE2's, without back-references and look-around (those need
   backtracking, so they are rejected, not emulated).
4. A `Regex` is an **owned, immutable** value; matching state lives in a
   separate `Matcher`; results are **views of the input**.
5. No global cache in std. A cache is userland (`Map[String, *Regex]`).

## 1. Demand

| Site | Pattern shape |
|---|---|
| `semver/version.go`, `version_range.go` | 7 fixed anchored patterns: `^(0\|[1-9]\d*)(?:\.(...))...$`, `(?i)`, `\s+`, `\|\|` |
| `diagnostics.go:127` | `{(\d+)}` formatting, run per diagnostic message |
| `modulespecifiers/util.go:116` | **pattern compiled at run time** from tsconfig `paths` |
| 42 `regexp.` refs in total; ~10 are test or tooling | most are `MustCompile` at package level |

So the shapes: anchored full matches with groups, a global find-all with one
group, and run-time patterns. Backtracking features are not used.

## 2. Ownership (CORE sentences 1, 4, 7; nothing new)

- `Regex` is an `obj` holding its program in lists. It is **owned**: it moves,
  drops with its scope, and is shared with `*Regex` (a plain refcount of an
  immutable value; no cycle is possible, it holds no handles). It never
  mutates after `compile`, so `?Regex` lends are shared freely.
- Scratch state (thread lists, capture slots) is **not** inside `Regex`: that
  would make every match a write lend and a shared `*Regex` unusable. It lives
  in `Matcher`, created by `re.matcher()` and declared `from re` (a view that
  keeps `re` lent). Creating one allocates; its use does not, beyond growth.
- A `Match` or `Captures` holds the input as a `?String`, so every returned part
  is `from s`, as `text.cut` results are: while a match lives, the `String` it
  came from stays lent. Nothing is copied except by `replace` (it returns an
  owned `String`, so the allocation is in its type).
- Safe code cannot corrupt memory: the VM indexes its own lists with checked
  bounds; there is no `raw` anywhere.

## 3. API

```rig
use std.regex

sub main()
  re = regex.compile("^(\\d+)\\.(\\d+)$") catch
    return
  m = !re.matcher()
  if (!m).captures("12.34") as c
    print(c.get(0), c.get(1), c.get(2), c.count)
  print((!m).is_match("12.x"))
  print(regex.compile("a(b") catch "bad pattern")
```

```output
12.34 12 34 3
false
bad pattern
```

| Function | Result |
|---|---|
| `compile(pat: ?String) -> Regex!` | parse and compile; fails with `regex.Error`: `syntax`, `unsupported` (back-reference, look-around), `too_big` |
| `re.error_pos` | not available (errors carry no data yet); `regex.check(pat: ?String) -> Int?` gives the byte offset of the first problem, or `none` |
| `re.groups() -> Int` | number of capture groups, group 0 excluded |
| `re.group_index(name: ?String) -> Int?` | the index of a named group |
| `re.matcher() -> Matcher from re` | scratch for matching; allocates |
| `(!m).is_match(s: ?String) -> Bool` | unanchored search, any match |
| `(!m).find(s) -> Match? from s` | leftmost match (leftmost-first, as Perl, Go, RE2) |
| `(!m).find_at(s, start: Int) -> Match? from s` | search from byte offset `start`, with `^`/`\b` seeing the text before it |
| `(!m).captures(s) -> Captures? from s` | the match and every group |
| `m.start`, `m.end`, `m.text` | a `Match`: byte offsets, and the matched `?String` |
| `c.get(i: Int) -> (?String)?`, `c.name(n: ?String) -> (?String)?` | group text; `none` when the group did not take part |
| `c.span(i) -> Span?` | its offsets |
| `(!m).find_all(s) -> Matches from s` | iterator of `Match`; empty matches advance by one rune, like Go |
| `(!m).split(s, limit: Int = -1) -> RegexSplit from s` | parts between matches, iterator |
| `(!m).replace(s, tpl: ?String) -> String`, `replace_all` | owned result; template `$1`, `${name}`, `$$` |

Spelling: `compile` and `check` are module functions (a value is made by a
function, as `new_doc()`); matching is methods on the value, with `(!m)` as
`Doc.parse` and `Split.next` already write it. The `[]`/`()` rule is
untouched: patterns are runtime strings, so compile-time `regex[...]` is not
offered (a compile-time-checked literal is a later option, section 8).

**One-shot sugar.** `re.is_match(s)` and `re.find(s)` directly on `Regex`, which
build a matcher inside (allocating, documented). They make `semver`'s call
sites one line, and cost an allocation per call. Recommended: **provide them
but name the cost** in the table ("allocates a matcher"), because the
alternative is every user writing the three-line matcher dance before a single
test. Decision 5.

`replace_with(s, |m| ...)` needs closures (NEEDS 5); until then
`replace` templates cover `{(\d+)}` formatting, though that case is better done
by a loop over `find_all` and `Match.start`.

## 4. Syntax subset (RE2, UTF-8, bytes of the input are runes via `rune_at`)

- Literals and escapes: `\n \t \r \f \v \a \x41 \x{1F600} \\ \.` etc.
- `.` (any rune but `\n`; with `(?s)` any rune), classes `[a-z0-9_]`, `[^...]`,
  `[[:alpha:]]` ASCII classes, `\d \w \s \D \W \S` (ASCII, as RE2).
- Anchors `^ $ \A \z \b \B`; with `(?m)` the line forms.
- Groups `( )`, `(?: )`, `(?P<name> )` and `(?<name> )`; alternation `|`.
- Repeat `* + ? {n} {n,} {n,m}`, each with a lazy form `*?`. Counts are bounded
  (<= 1000) and program size is bounded (<= 100K instructions): `too_big`
  otherwise, so compile cost is bounded and a hostile pattern cannot blow up.
- Flags `(?i) (?m) (?s) (?U)` and scoped `(?i:...)`. **`(?i)` is ASCII-only in
  phase 1** (all of semver); Unicode folding arrives with `unicode.simple_fold`
  (`proposal-unicode.md`, phase 3).
- Phase 3: `\pL`, `\p{Greek}` and `\p{Lu}`, from the same generated Unicode
  tables. Not before a consumer asks.
- Rejected with `unsupported`: `\1`, `(?=`, `(?!`, `(?<=`, `(?<!`, atomic and
  possessive forms. A rejection exists when a `test/reject`-style test proves it.
- Invalid UTF-8 in the input is U+FFFD of size 1 (Go's contract); a pattern
  string must be valid UTF-8, else `syntax`.

## 5. Engine options

- **A. Pike VM (recommended).** Parser to an AST, then a flat instruction list
  (`char`, `class`, `split`, `jmp`, `save n`, `assert`, `match`); two sparse-set
  thread lists swapped per input rune; captures copied-on-write per thread
  (a `List[Int]` slab, index not pointer). About 1,200 lines of Rig. Cost: tens
  of nanoseconds per rune per live thread; fine for the sites above (short
  inputs), bounded by the program size.
- B. Backtracking (Perl, Go's `regexp/backtrack` for tiny inputs): fast on
  easy cases, **exponential on others** and needs a step limit; contradicts
  "no hidden cost". Rejected, except as an internal one-pass optimisation.
- C. Lazy DFA with NFA fallback (RE2, Rust's `regex`): 5 to 50 times faster on
  large inputs, but captures still need the NFA; 2 to 3 times the code and a
  cache with eviction policy (a hidden-looking allocation). Phase 2, behind
  the same API, only when a benchmark (a `find_all` over a large file) shows
  the need. Nothing in the API changes.
- Cheap early wins inside A: a literal-prefix scan with `text.find` for the
  first byte of an unanchored pattern, and "anchored at start" shortcuts. Both
  are internal.

Why Rig and not Zig: json's 1.9 to 7.0 GB/s shows Rig lowers to code as fast as
Zig; a regex written in Rig is Trig's first realistic exercise of `List[Int]`
slabs, `match` on a tagged instruction, and generic-free state machines, and
every bug there is a language test case. The sanitizer runs it. Risks: the
instruction type wants a tagged `enum` with data (`match` on payloads);
`obj Inst(op: Op, x: Int, y: Int)` with an `enum Op` works today and is what
I recommend, so nothing blocks.

## 6. Run-time pattern cache

semver patterns are fixed, so each is a module constant compiled once: but a
module constant cannot hold an owning value (Feature B rejects "owning
constants built on first use"). So fixed patterns live in a `Regexes` obj the
program creates in `main` and passes down, and run-time ones go in a userland
`Map[String, *Regex]` once Map exists. **Std offers no global cache:** it would
be hidden mutable global state and an unbounded allocation. This is also the
rule-5 line: caching policy (size, eviction) is the program's. Document the
pattern in `docs/STD.md` with a ```` ```rig ```` example once Map lands.

## 7. Failing tests (new, under `test/behavior/std/`, plus `test/reject/`)

| File | Proves |
|---|---|
| `regex_basic.rig` | the section 3 program; literals, classes, groups, alternation, anchors |
| `regex_semver.rig` | the 7 semver patterns against 200 version strings, results equal to Go's (golden file made by a Go script run once, checked in) |
| `regex_leftmost_first.rig` | `a\|ab`, `a*?`, `(a*)*` and empty-match advance equal Go's `FindAll` |
| `regex_linear.rig` | `(a*)*b` and `(a\|a)*$` on 100,000 `a`s finish in under a second (a regression against any backtracking) |
| `regex_utf8.rig` | `.` and classes on multi-byte runes, invalid bytes as U+FFFD |
| `regex_replace_split.rig` | `$1`, `${n}`, `$$`; split and `find_all` |
| `regex_views.rig` | the input stays lent while a `Match` lives; result is leak-free under sanitizer |
| `reject/regex_view_after_move.rig` | moving the `String` while a `Captures` lives is rejected |
| `reject/regex_matcher_outlives.rig` | a `Matcher` outliving its `Regex` is rejected |
| `regex_errors.rig` | each `syntax`, `unsupported`, `too_big` case, and `check`'s offset |
| `test/corpus/` | a differential run against Go's `regexp` over generated patterns and inputs, in the deep gate (like `test/matrix.py`) |

## 8. Effort

| Piece | Time |
|---|---|
| Parser (AST, classes, flags, errors, limits) | 3 days |
| Compiler to program, repeat expansion | 2 days |
| Pike VM with captures, anchors, word boundaries | 3 days |
| API: matcher, find, find_all, captures, split, replace | 2 days |
| Tests, Go-differential corpus, docs | 3 days |
| **Phase 1 total** | **about 2.5 weeks**, no soundness classifier touched: fast gate, but it is the first std module with views flowing out of a `from` method on a nested scratch, so expect one extra review round |
| Lazy DFA (phase 2), if measured | 1 week |
| `\p{..}` and Unicode `(?i)` (phase 3) | 2 days after `proposal-unicode.md` phase 3 |

**Later option:** `regex.compile` at compile time for a literal pattern
(`regex.re["..."]`, `[]` is compile time): pattern errors become compile errors
and the program is a module constant. Needs compile-time evaluation of calls;
out of scope here.

## 9. Decisions for the owner

1. Write it in Rig (recommended), or in Zig behind `extern zig`?
2. Pike VM first (recommended); lazy DFA only on measured need?
3. RE2 syntax, rejecting back-references and look-around with `unsupported` (recommended)?
4. Split `Regex` (immutable, shareable `*Regex`) from `Matcher` (scratch) (recommended), or one mutable value?
5. Offer one-shot `re.is_match(s)`/`re.find(s)` that allocate a matcher, with the cost named (recommended)?
6. Errors: `compile` fails with a bare error set plus `regex.check(pat) -> Int?` for the offset (recommended until errors can carry data)?
7. `(?i)` ASCII-only in phase 1 (recommended), Unicode fold in phase 3?
8. `\d \w \s` ASCII (recommended, RE2 and Go) or Unicode?
9. No std-level pattern cache (recommended); cache is `Map[String, *Regex]` in userland?
10. Limits: repeat count 1000, program 100K instructions (recommended), configurable by `compile_with(pat, limits)` later?
11. Scheduling: after traits and Map/Set (recommended), before them, or alongside `std.unicode`?
