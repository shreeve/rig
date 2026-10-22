# Origins: fit with Rig and its users

Role: how each origins design fits Rig and the people who write it.
Every Rig claim below was checked with `bin/rig check`, and with
`RIG_SANITIZE=1 bin/rig run` where a program is accepted, on the revamp
worktree (`d29be15f`). The probes are in `probes-fit/` (`f*.rig`). The
companion reports are `formal.md` (the model, Rust parity) and
`prior-art.md`. This report uses their layer names: **L0** (type-directed
carry, including `produces`), **L1b** (field-precise holder loans),
**L2** (origins inferred from bodies), **L3** (declared `from`).

---

## 0. Bottom line

1. **The pain real programs feel most is not the one the question
   names.** The result channel (`first(?x, ?y)` keeps `y` lent) is real
   but uncommon. The **store channel** is common and worse. A call that
   lends a write view of a value holding any `String` field, plus a
   `String` argument, is assumed to store that argument. So
   `log(!ctx, ?Text("step ", i))` is rejected, and binding the `Text`
   first does not help either (`f5b`, `f5c`, `f5d`). Neither `produces`
   nor `from` on results fixes it.
2. **A bug, not the designed over-approximation, makes it worse.** A
   method call whose receiver is lent to *read* (`?self`) absorbs its
   arguments' loans into the receiver, as if a read receiver could store
   them. `b.show(?q)`, with `fun show(?self, s: String) -> Int`, keeps
   `q` lent while `b` lives (`f2g`). The free-function form of the same
   program is accepted and runs clean (`f2f`). The cause is in
   `walkCall` (`src/ownership.zig`, about lines 2918–2923):
   `if (recv_root) |id| ... absorbLoans(id, stored, ...)` runs for
   every `recv_mode`, `.read` included. The base compiler has it too.
   Fixing it is in scope now: wrong rejections become acceptances. No
   corpus probe covers this shape.
3. **The census.** Real Rig code with a result fed by two or more
   same-typed views is rare:
   - **std:** 3 functions, `text.strip_prefix`, `strip_suffix`, and
     `cut`, out of 14 view-returning functions;
   - **tests:** about 5% of view-returning functions.

   The suite has **one** reject test that depends on the
   over-approximation (`test/reject/ownership/nll_returned_borrow_still_used.rig`,
   also SPEC's example at `SPEC.md:3086`). The suite cannot measure the
   pain: its probes test that loans are *kept*, never that they are
   *freed*, so false rejections are invisible to it by construction.
   Every pain case in this report came from a probe written for this
   report, or for `core-audit/loans.md`.
4. **Ranked by how often a real program hits them** (§1.5):
   1. the store channel and the read-receiver bug: loggers, builders,
      contexts, and any `!x.f(s)` on a struct with a `String` field;
   2. parser cursors `next(!self) -> ?Tok` over non-String tokens (L0
      fixes these);
   3. lookups whose key has a different type from the result (`produces`
      or L0 fixes these);
   4. lookups and text helpers whose key has the *same* type as the
      result (`get(?self, name: String) -> String?`, `strip_prefix`
      with a computed prefix), which only `from` or inference fixes;
   5. two-owner holders (`pair.rig`, `Split` with a computed separator),
      which need L1b;
   6. callbacks.

   Callbacks need nothing: a `?fun` argument whose result cannot hold a
   view already contributes no loans (`f4`, `f4c`, `f4d` are accepted
   and run clean).
5. **Recommendation, from the users' side:**
   - **L0, type-based, for results and for stores.** It needs no
     syntax, and most of the pain disappears.
   - **A declared, checked `from` for results.** The keyword is
     contextual: `-> String? from s`.
   - **A declared, checked `into` for stores**, on the parameter the
     caller lends: `n: String into self`. It defaults to *nothing
     stored*, as in Rust, Swift, and Clang.
   - **L1b last.**
   - **Inference (L2) stays inside the compiler.** It checks every
     `from` and `into` against the body, and it writes the help line
     that names the exact word to add. It is never the default meaning
     of a call.
6. **"100%" for a user** means this: every rejection that comes from
   over-approximation carries a help line naming the one word that
   frees the argument. The compiler can promise that, because L2
   computes the minimal origins anyway. Every origin case Rust accepts
   becomes expressible (formal.md §4). What remains is not about
   origins: views in owned closures and Cells, and callbacks that store
   their argument.

---

## 1. Census

### 1.1 Method

A scanner read every signature in `std/`, `examples/`, `test/behavior`,
`test/reject`, `test/corpus`, and the 292 `rig` blocks in the docs. It
counted functions whose result is a view (`?T`, `!T`, `[]T`, `![]T`,
`String`, or a struct with view fields) and that are lent two or more
views. A `String` parameter counts as lent: it carries the loan of the
`Text` it views. It also listed struct types with two or more view
fields. Each hit was checked by hand.

### 1.2 Counts

| Where | files | view-returning functions | ...lent 2+ views | rejected today only because of it |
|---|---|---|---|---|
| std | 7 | 14 | 4 (`strip_prefix`, `strip_suffix`, `cut`, `split`) | none in std itself; every caller with a computed second argument |
| examples | 9 | 0 | 0 | 0 |
| test/behavior | 837 | 104 | 5 | 0 (all are accepted programs) |
| test/reject | 974 | 72 | 1 | **1**: `nll_returned_borrow_still_used.rig` *expects* the over-approximation |
| test/corpus | 4,560 | 301 | 27 | 1: `syntax-review-designer-p31_over` (`find(?self, key: ?Key) -> ?P`, fixed by `produces`) |
| doc examples | 292 | 25 | 2 | 1: SPEC §"Second-class borrows", the same program as the reject test |

Of the four std functions, `split` legitimately holds both views:
`Split` keeps `sep`. The other three return a view of `s` only. Every
std.text call site in the repo passes a literal as the second argument
(41 call sites), and a literal makes no loan. So std's over-approximation
bites only when the pattern or key is built at run time.

Structs holding views from two owners: `std.text.Split` (`rest`, `sep`),
`UserView` in `test/behavior/types/showcase_program.rig`, and SPEC's
`Pair` example. None is rejected today, because none changes one owner
while a view of the other is live.

**Docs that state the over-approximation as the rule,** and that change
with any narrowing:
- CORE sentence 7 ("carries the loans of everything it was lent");
- SPEC "Second-class borrows" (`SPEC.md:3039`);
- DESIGN "Borrows without lifetimes";
- BEYOND-RUST §2 ("The trade");
- the reject test and SPEC example above.

Under a declared `from`, the reject test and SPEC example stay valid
unchanged, because `first` declares nothing. Under body inference both
flip to accepted, and the documented rule becomes false.

### 1.3 Probes written for this report

All are in `probes-fit/`. "Rust" is what rustc does with the natural
translation: elided or obvious lifetimes, per formal.md's method.

| Probe | Shape | Today | Fixed by |
|---|---|---|---|
| `f1_prefix_loop` | `for name in names: key = Text(name, "="); if text.strip_prefix(?line, ?key) as v: !found.push(v)` | ✗ `key` does not live long enough | `from s` on std's `strip_prefix` (L3), or L2 |
| `f1b_prefix_tmp` | same, `-key` after the call | ✗ | L3 / L2 |
| `f2_lookup`, `f2e_lookup_loop_print` | `env.get(?q)` in a loop, `fun get(?self, name: String) -> String?` | ✗ "`q` goes out of scope while **`env`** still borrows it" | **read-receiver bug**, then `from self` (L3) or L2 |
| `f2f_lookup_free_fn` | same as `f2e`, written as a free function `get(?env, ?q)` | ✓ runs `1 3 a` | (shows the bug is the receiver) |
| `f2g_read_method_int` | `k = b.show(?q)` with `show(?self, s: String) -> Int` | ✗ | **read-receiver bug** only |
| `f2b_lookup_struct` | `t.find(?probe) -> (?Entry)?`, key also an `Entry`; write `probe` | ✗ | L3 `from self` / L2 |
| `f2c_lookup_key` | same with `key: ?Key` | ✗ | L0 / `produces` |
| `f2d_lookup_print` | `v = env.get(?q) ?? "?"; -q` | ✗ | L3 / L2 |
| `f3_two_buffers` | `Diff(old: ?a, cur: ?b)`; `o = d.old_view()`; `b[1] = 9` | ✗ | L1b + (`from self.old` or L2) |
| `f4_callback`, `f4c_pick_by`, `f4d_pick_by_wrap` | `?fun(?Item) -> Bool` / `-> Int` predicate capturing a local | ✓ runs clean | (already type-based: `keepsCallable`) |
| `f4b_callback_ret` | `call(f: ?fun() -> ?Wrap)` returning the capture | ✗ (correct) | n/a |
| `f5_sub_store` | `sub show(v: !View, b: ?In)` reads only | ✗ `y` does not live long enough | `into` (default nothing) / L2 |
| `f5b_sub_log` | `sub log(ctx: !Ctx, msg: String)`, `Ctx` has `name: String`; `m = Text("step ", i); log(!ctx, ?m)` | ✗ | `into` / L2 (not L0: `Ctx` can hold a String) |
| `f5c_sub_log_temp` | `log(!ctx, ?Text("step ", i))` | ✗, and the hint "bind the value to a name first" is wrong (`f5b` is that) | `into` / L2 |
| `f5d_method_log` | `!log.say(?name); -name` | ✗ | `into` / L2 |
| `f6_split_next` | `a = !parts.next(); b = !parts.next()` | ✓ `a b` | (String carry rule) |
| `f6b_split_sep` | `split(?line, ?sep)`, keep a part, `-sep` | ✗ | L1b + (`from self.rest` or L2); Rust accepts |
| `f7_parser_cursor` | `a = !p.next(); b = !p.next()` with `next(!self) -> ?Tok` | ✗ use of `p` while a write loan is live | L0 |
| `f7b_parser_text` | `p.text(?toks[1]) -> String`, then write `toks` | ✓ `x 9` | (String carry rule) |
| `f8_env_static` | `v = os.env(?t) ?? "unset"; -t` | ✗, though std documents the String as living for the whole program | `from static` on the extern declaration |

### 1.4 Shapes that already work

The cases below are accepted today and run clean, so a newcomer never
meets the over-approximation in them:
- iterators over `String` (`Split`, `Lines`, `Words`);
- string accessors on a parser;
- predicates and scoring callbacks;
- any call whose second argument is a literal.

The existing `String` rule (`viewLoans`/`addViewLoan`) is the reason:
a `String` can only view a `Text` or a literal, so loans on values that
own no `Text` are dropped. That rule is L0 specialized to `String`, and
it has caused no complaint. It is good evidence that type-based
narrowing fits Rig users: it is invisible, and it does what they expect.

### 1.5 How often real programs hit each shape

The repo has no large application, so this estimate is by program
kind. It counts which line a typical program of that kind writes in its
first 200 lines.

| Program kind | Line that hits it | Frequency | Layer |
|---|---|---|---|
| Anything with a logger, context, builder, or reporter struct holding a `String` name | `!ctx.log(?Text(...))`, `log(!ctx, ?m)` in a loop | **high**; nearly every program that formats messages | `into` (or L2); and the read-receiver bug for `?self` methods |
| Parser or tokenizer over a token array | `t = !p.next()` twice, `peek` then `next` | **high** in parsers | L0 |
| Lookup table, symbol table, or interpreter environment keyed by a different type (`Key`, `Int`, index) | `e = t.find(?k)`, then change `k`; `get_counted(?t, i, !n)` (r04) | high | L0 / `produces` |
| Same, with `String` keys and `String` values (env vars, config, headers) | `v = env.get(?name)` where `name` is built per iteration | medium | L3 `from self` / L2 |
| Text processing with computed patterns | `strip_prefix(?line, ?key)`, `after(hay, key)` (st05) | medium-low; most patterns are literals | L3 in std |
| Two-owner holders, then change one owner | `Diff(old, cur)`, `Split` with a computed `sep` | low | L1b |
| Generic `pick`/`first` of two same-typed views | `first(?x, ?y)`, then change `y` | low | L3 / L2 |
| Callbacks | predicates, scorers | none today | none |

---

## 2. The same programs under each design

The designs, as a user meets them:

- **T:** today.
- **D0:** L0 + `produces`, for results and for stores. No syntax.
- **D1:** D0 + L1b, field-precise holder loans. No syntax.
- **D2:** D0 + L2: callers use summaries inferred from callee bodies.
  No syntax.
- **D3:** D0 + `from` on results and `into` on stored parameters
  (stores default to nothing), checked against the body by L2. L2 also
  writes the help lines.

D0, D1, and D2 add no syntax, so a program reads the same under each.
They differ only in which programs compile. D3 changes signatures
only, never call sites. Each program below is written once, the way a
Rig user would write it, with D3's words marked `# D3`.

### P1. Lookup (a symbol table)

```rig
struct Var
  name: String
  value: String

struct Env
  vars: Vec[Var]

  fun get(?self, name: String) -> String? from self      # D3
    for i in 0..self.vars.len
      if self.vars[i].name == name
        return self.vars[i].value
    none

  fun slot(?self, key: ?Key) -> (?Var)?                   # D0 suffices: a Key cannot hold a Var view
    ...

sub main
  env = load()
  for n in ["HOME", "PATH"]
    q = Text("RIG_", n)
    if env.get(?q) as v
      !seen.push(v)
```

### P2. A parser holding views of two buffers

```rig
struct Parser
  src: String
  toks: []Tok
  pos: Int

  fun next(!self) -> ?Tok                 # D0: Parser reaches Tok only through a read view
    t = ?self.toks[self.pos]
    self.pos += 1
    t

  fun text(?self, t: ?Tok) -> String      # works today (String rule)
    self.src[t.start..t.start + t.len]

sub main
  p = Parser(src: ?src, toks: ?toks, pos: 0)
  kw = !p.next()
  name = !p.next()
  print(p.text(kw), p.text(name))
```

### P3. Text: `after(hay, key)` and `strip_prefix`

```rig
pub fun strip_prefix(s: String, prefix: String) -> String? from s    # D3, in std
pub fun cut(s: String, sep: String) -> Cut? from s                   # D3, in std

fun after(hay: String, key: String) -> String? from hay              # D3, user code
  i = text.find(hay, key)?
  hay[i + key.len..]

sub main
  for name in names
    key = Text(name, "=")
    if text.strip_prefix(?line, ?key) as v
      !found.push(v)
```

### P4. A struct of two views

```rig
struct Diff
  old: []Line
  cur: []Line

  fun old_view(?self) -> []Line from self.old       # D3 + L1b
    self.old

sub main
  d = Diff(old: ?a, cur: ?b)
  o = d.old_view()
  !b.push(line)           # needs L1b: `o` views only what `d.old` views
  print(o.len)
```

### P5. A callback taking `?fun`

```rig
fun find_by(xs: []Item, pred: ?fun(?Item) -> Bool) -> (?Item)?            # works today
fun best_name(xs: []Item, name_of: ?fun(it: ?Item) -> String from it) -> String from xs   # D3: names in the fun type
```

### P6. A logger (the store channel)

```rig
struct Ctx
  name: String
  count: Int

  sub log(!self, msg: String)            # D3: no `into`, so `msg` is not kept
    self.count += 1
    print(self.name, msg)

  sub rename(!self, n: String into self) # D3: it keeps `n`
    self.name = n

sub main
  for i in 0..3
    !ctx.log(?Text("step ", i))
```

### 2.1 Which programs compile

✓ accepted, ✗ rejected.

| Program | T | D0 | D1 | D2 | D3 |
|---|---|---|---|---|---|
| P1 `get` with a String key built per iteration | ✗ (bug, then the result) | ✗ | ✗ | ✓ (after the bug fix) | ✓ (after the bug fix) |
| P1 `slot` with a `Key` | ✗ | ✓ | ✓ | ✓ | ✓ |
| P2 cursor `next` twice | ✗ | ✓ | ✓ | ✓ (with L0 inside) | ✓ |
| P3 computed prefix or key | ✗ | ✗ | ✗ | ✓ | ✓ (std writes `from s` once) |
| P4 two-owner holder | ✗ | ✗ | ✗ | ✗ | ✗ |
| P4 + L1b | | | ✗ | ✓ | ✓ |
| P5 predicate | ✓ | ✓ | ✓ | ✓ | ✓ |
| P5 selector returning a view of its argument | ✗ | ✗ | ✗ | ✗ (no body) | ✓ |
| P6 `log` with a formatted message | ✗ | ✗ | ✗ | ✓ | ✓ |
| `os.env(?t)` | ✗ | ✗ | ✗ | ✗ (no body) | ✓ (`from static` on the extern) |

D2 and D3 accept the same programs wherever there is a body. D3 also
covers every bodiless boundary: function types, `extern zig`, and a
stable public API. So D2 never removes the need to learn the declared
form. It only postpones meeting it.

### 2.2 Readability

**A Python or Ruby programmer:**
- Reads `-> String? from s` as English: "returns a String from s".
  Nothing to decode, no new punctuation, and it sits where they look
  for "what do I get back".
- Reads `n: String into self` as "n goes into self". That is the
  effect, written where it happens. It is in the North Star's spirit:
  keeping a caller's data is an effect, and Rig shows effects.
- Never meets D0 or D1: they only stop errors that a Python programmer
  would find absurd anyway ("a key can't give me an entry").
- Finds D2 equally silent until it rejects a call. The reason then lies
  in another function's body, possibly in another module.

**A Rust programmer:**
- `-> String? from s` is `fn strip_prefix<'a>(s: &'a str, prefix: &str)
  -> Option<&'a str>`, with no lifetime parameter to declare and none to
  thread through structs. It is place-based, like Mojo's `ref[a]` and
  Rust's own planned place lifetimes (prior-art.md §0).
- `into self` is Rust's `Person<'a>` plus `name: &'a str`.
- D3's store default ("nothing") is exactly Rust's elision: an elided
  input gets a fresh lifetime, so it cannot be stored.
- D2 will look magical, and then fragile, the first time a library
  update breaks their build.

**One readability cost of D3:** lookups on `String`-keyed `String`
tables need `from self`. Rust's elision rule 3 (`&self` wins) would
avoid that. I recommend against copying it: it is an exception list
("methods differ"), and today's union default is sound without it.
The help line makes adding `from self` a one-step fix.

### 2.3 Diagnostics

Today, for `two.rig`:

```
two.rig:8:3: error: cannot write-borrow `y` while a read borrow is live
two.rig:7:18:   note: read borrow taken here
```

The reader sees `r = first(?x, ?y)` and thinks "but `r` is `x`". Under
D3, in the vocabulary of the vocabulary pass:

```
two.rig:8:3: error: cannot lend `y` to write while a read loan is live
  !y.push(1)
  ^
two.rig:7:17: note: `r` carries the loan: `first(?x, ?y)` returns a view,
  and without `from` a result carries the loans of every argument that
  could hold it
two.rig:9:9: note: `r` is used here
help: `first` returns a view of `a` only (two.rig:2). Say so, and `y` is
  free after the call:
    fun first(a: ?Vec[Int], b: ?Vec[Int]) -> ?Vec[Int] from a
```

The store channel under D3, when a body stores what it did not declare
(the error lands on the library author, not the caller):

```
ctx.rig:9:5: error: `rename` keeps a view of `n` in `self` after it returns
    self.name = n
    ^
help: say so in its signature: `sub rename(!self, n: String into self)`
```

The same error under D2 lands on the caller, and must cite the callee's
body:

```
main.rig:12:5: error: cannot lend `y` to write while a read loan is live
main.rig:11:9: note: `r` carries the loan: `first` may return a view of
  its second argument
lib/pick.rig:14:5: note: here, through `pick(b, a)`, which returns its
  first argument (lib/pick.rig:22)
```

The reasoning chain grows with the call graph. A user debugging it
reads library internals, and fixes nothing in their own file.

Two of today's messages mislead independently of the design. Both should
be fixed with the read-receiver bug:
- `f2e`: "`q` goes out of scope while **`env`** still borrows it", where
  `env` was lent only to read;
- `f5c`: "bind the value to a name first", where binding does not help
  (`f5b`).

### 2.4 What a newcomer must learn

| Design | New concepts |
|---|---|
| D0 | none: "a view comes only from an argument that could hold it", which reads as common sense |
| D1 | none: "each field keeps its own loans" |
| D2 | nothing to write. But "a call's effect on my variables depends on the callee's body" is a new and unusual idea. Its errors point outside the user's code, and function values and extern declarations still need the declared form |
| D3 | two contextual words, each with one meaning, each met first in a help line that writes it out: `from` (what a result views) and `into` (what a function keeps in a write argument) |

---

## 3. Syntax for declared origins

| Option | Example | Verdict |
|---|---|---|
| **`from` after the result type** | `-> String? from s`, `-> ?Tok from self.toks`, `-> Split from s, sep` | **Pick.** English, place-based, sits at the result. It extends to paths (`self.old`), to lists, and to function types (`?fun(it: ?Item) -> String from it`). It is not a keyword today, and `from` is used as a name (`sub transfer(from: !Account, ...)`, a `Segment.from` field), so it must be contextual, "a keyword only directly after a type in a signature", as `of` is contextual inside `[ ]` |
| `of` | `-> String? of s` | Reject: `of` already means fill (`[n of x]`), and "String of s" reads as "made of" |
| `in` | `-> String? in s` | Reject: `in` is `for`'s, and reads as membership |
| `where` (reserved) | `-> String? where s` | Reject: reads as a constraint clause |
| a sigil on the source parameter | `^s: String`, `s: String^` | Reject. Rig's sigils are operations on values at use sites; a declaration marker dilutes the algebra. It cannot say which output (result or which write argument), nor name a path (`self.src`) |
| the source inside the result type | `-> ?(a) Vec[Int]`, `-> ?[a]Vec[Int]`, `-> a.?T` | Reject: `?a` already means "lend `a`"; `[ ]` is compile-time brackets and collides with `?[]T`; cryptic to a Python reader |
| an attribute | `@from(a)` | Reject: `@` is raw builtins, and Rig has no attributes |
| stores: `from` on the write parameter | `sub put(v: !View from b, b: ?Wrap)`, `sub add(!self from n, n: String)` | Second choice. One keyword for all outputs, but a forward reference, and `!self from n` reads poorly |
| **stores: `into` on the kept parameter** | `sub put(v: !View, b: ?Wrap into v)`, `sub add(!self, n: String into self)` | **Pick.** It reads as the effect ("n goes into self"), sits on the parameter the caller lends, which is the one the caller asks about, and refers backward |
| static results (extern only) | `pub fun env(name: String) -> String? from static` | `static` is contextual after `from`; Rig bodies get it from L2, so only `extern zig` declarations write it |

Function types need parameter names for `from` to name anything. Today
`?fun(it: ?Item) -> Bool` is a parse error ("unexpected `it`; expected a
type"). Optional names in function types are a small grammar change,
and they help docs anyway.

---

## 4. API stability and modules

### 4.1 If origins are inferred from bodies (D2)

**The library author:**
- **v1:** `pub fun lookup(t: ?Table, key: String) -> String?` returns a
  stored value. Users write `v = lookup(?t, ?k); -k; use(v)`.
- **v1.1:** the author adds a fallback, `?? key`. Their tests pass.
- **Result:** every caller that drops or changes `k` while `v` lives
  stops compiling. The error is in the user's file, and it cites the
  library's line. The signature did not change, so no semver tool,
  diff review, or doc diff warns the author.

**The user** cannot see from the docs which arguments stay lent:
- the only truth is the body, plus every body it calls (SCC fixpoints);
- a docs generator must print the inferred origins to be useful, and at
  that point it is printing the annotation;
- `extern zig` (std's `find`, `os.env`) and every `?fun` parameter have
  no body, so the user meets declared origins anyway.

**Modules:**
- Summaries must be exported in each module's interface, as generic
  requirements are today (formal.md §2.5).
- Rig compiles whole programs, so this is buildable.
- But a module's meaning to its importers then depends on code they do
  not see.
- This also cuts against Core §10's "rules follow the value's type, never
  where the value came from": what a call holds would follow the
  callee's body.

### 4.2 If origins are declared and checked (D3)

- **The signature is the contract.** Widening the body beyond it is an
  error in the author's own module, with a fix-it.
- **Changing `from s` to `from s, prefix`** is a visible signature
  change. Narrowing is compatible: callers only gain.
- **The docs show it with no extra tooling.** STD.md's table rows become
  `strip_prefix(s: String, prefix: String) -> String? from s`.
- **`rig check` output:**
  - at a rejecting call, the help line of §2.3, naming the exact word
    and the callee line that proves it;
  - optionally `rig check --origins file.rig`, which prints, per
    function, the declared origins next to the minimal ones L2 found:
    `text.rig:52 strip_prefix: result from s (declared s)`,
    `env.rig:9 get: result from self (declared: every argument; narrow
    with "from self")`.
  - No warning on functions that never cause a rejection: that would be
    noise.

**The burden, measured:**
- **Results:** 3 annotations in all of std (`strip_prefix`,
  `strip_suffix`, `cut`), and about 5% of view-returning functions in
  the tests.
- **Stores:** a scan of `test/behavior`, examples, std, and the doc
  examples found 45 functions lent both a write view and a view
  argument. Only about 4 of them store the argument into the write
  target. Those are setters: `sub add(!self, n: String)` with
  `!self.names.push(n)`, `fill`, `put`, `keep`. They would write
  `into`. The other ~41 are freed by the "nothing stored" default.

### 4.3 The store default is the one hard choice

D0 alone narrows stores by type: an argument whose type cannot be held
by the write target is not absorbed. That does not fix the logger:
`Ctx` holds a `String`, so it can hold `msg`.

To fix the logger by declaration, the default must be *nothing stored*,
with `into` where a function keeps a view. That is Rust's elision,
Swift's `@lifetime(dst: copy src)`, and Clang's `lifetime_capture_by`
(prior-art.md §0.5d). It turns today's accepted setters into rejections
with a fix-it, so it is a language change for after the feature freeze.
It is not a consolidation. Until then, D0's type-based narrowing of
stores, plus the read-receiver fix, are in scope and take most of the
edge off.

The asymmetry with results is principled, and fits one Core paragraph:
- A result's view-ness is visible in its type (`-> ?T`). A union over
  the arguments that could produce it is sound, and costs the caller
  only if the caller keeps the result.
- A store is invisible in the types (`!Ctx` does not say "and I keep
  `msg`"), and lands in a value the caller already holds past the call,
  so its cost is always paid.

---

## 5. Recommendation

**Order:**

1. **Now, as a consolidation fix:** stop absorbing argument loans into a
   receiver lent to read (`walkCall`'s `recv_root` absorb, for
   `recv_mode == .read`). The class is "a store through a path that
   cannot write". Siblings to check: a `*T` receiver, a `?self` holding
   a `!T` field (already rejected as "lend the write borrow held here
   through a read borrow"), and the `consumed_recv` path. Add `f2g`
   and `f2e` as tests. Also fix the two misleading notes (§2.3).
2. **D0, L0 + `produces`, for results and stores.** No syntax. It fixes
   parser cursors, keyed lookups, and counters. It generalizes the
   String rule users already rely on without noticing.
3. **`from` on results,** checked by L2, with the help line. std.text
   writes `from s` three times. `extern zig` declarations may write
   `from static` (`os.env`). Function types gain optional parameter
   names.
4. **After the freeze: `into`,** with stores defaulting to nothing.
5. **L1b last,** when a two-owner holder (`Split` with a computed
   separator, `Diff`) shows up in a real program.
6. **Body inference is never the meaning of a call.** It is the checker
   for `from` and `into`, and the source of every help line.

**A Core sentence 7 that fits the users** (one paragraph, no exception
list):

> **7.** A function returns a view only of what it was lent, or of
> something that lives for the whole program. A call's result carries
> the loans of the arguments that could hold such a view, or only of
> those its signature names with `from`. A call keeps a view of an
> argument after it returns only in its result, or in a write argument
> its signature names with `into`. The compiler checks each body
> against its signature. Every other loan the call was lent ends with
> its statement.

Its desugaring is formal.md's: arguments become statement temporaries,
and the result and the `into` targets take the loans the signature
names. Nothing new is emitted.

---

## Probe index (`probes-fit/`)

- **Rejected today, accepted by the recommended design:**
  - `f1_prefix_loop`, `f1b_prefix_tmp`, `f2b_lookup_struct`,
    `f2d_lookup_print`, `f3_two_buffers` (needs L1b), `f6b_split_sep`
    (needs L1b);
  - `f2c_lookup_key`, `f7_parser_cursor` (by L0);
  - `f5_sub_store`, `f5b_sub_log`, `f5c_sub_log_temp`, `f5d_method_log`
    (by `into`);
  - `f8_env_static` (by `from static`);
  - `f2_lookup`, `f2e_lookup_loop_print`, `f2g_read_method_int` (by the
    read-receiver fix; `f2_lookup` also needs `from self`).
- **Rejected correctly:** `f4b_callback_ret`.
- **Accepted, and run sanitizer-clean:** `f2f_lookup_free_fn`
  (`1 3 a`), `f4_callback` (`2 5`), `f4c_pick_by`, `f4d_pick_by_wrap`
  (`2 10`), `f6_split_next` (`a b`), `f7b_parser_text` (`x 9`),
  `f7c_parser_text_only`.
