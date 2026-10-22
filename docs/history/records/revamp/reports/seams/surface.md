# Rig's language surface: heartburn, and a path back to a small core

Read-only review. Trees: `main` at 8a82fab (`/Users/shreeve/Data/Code/rig`) and
the text branch `text-core` at 59e7bed (`/Users/shreeve/Data/Code/rig-text`,
which is main plus Text). I read AGENTS.md, DESIGN, SYNTAX, SPEC, WELCOME,
STD, ROADMAP, the text branch's SPEC §2/§7/§10, `std/*.rig`, the INTERNALS
facts table, the ledger's user decisions, and the four earlier purity reviews.
Every claim marked with a probe name was checked with the text branch's
`bin/rig run`. The probes are in `scratchpad/seams/surface/` (`run.sh` runs them).

## The short version

Rig's core is still small: its sigils, `e!`/`e?`, second-class borrows, and
drop at scope end. The heartburn comes from one habit. Each time a
convenience was needed, it was added as a rule keyed to a position or a type,
not as one general rule. That produced:

- **six separate "lend as a view" conversions**, with holes between them;
- **three answers to "does a read need `?`"**;
- **two kinds of view**: String, which may sit in a Vec and has `==`, and
  `[]T`/`?T`, which may do neither;
- **a list of positions where a temporary may live**;
- **a list of element types a Vec may hold**.

The text branch made each of these lists longer, because text touches all
of them at once. Eight changes remove most of the exceptions. Three of them
reopen user decisions and are flagged as questions.

---

## 0. What the earlier reviews found, and what has been fixed since

| Earlier finding | Status now | Probe |
|---|---|---|
| A bare `.name` fails when `T` has no variant of that name | **Fixed.** A failure must name its error set (`Lookup.missing`). One piece is left: a bare error *value* or an error-typed *binding* as a function's last line still fails, with no `return` (`e = E.bad` … `e`). `std/text.rig`'s `parse_bool` relies on this. | a03 |
| Errors are identified by name alone (`Disk.timeout == Net.timeout`) | **Fixed.** Each error belongs to its set. | SPEC §13 |
| `print(v, grow(!v))` reads a stale value | **Fixed** (#29) | SPEC §7 |
| `use a as b`, `use std.x` | **Fixed** | SPEC §14 |
| Implicit reads differ by position | **Not fixed, and wider.** The bare-read positions now also include `==` operands, `Text(...)` and `!t.add(...)` arguments, and a `?Text` binding lent as a String. | b01–b05, c02, h07 |
| `!` does four jobs; `=!` | **Not fixed.** `=!` was kept by user decision, twice. | a04 |
| `dup = !s.insert(k)` reads as "not" | **Not fixed.** This is still a pending user question. `g = !flag` on a Bool is rejected, but `dup = !s.insert(1)` is accepted. | a01, e01 |
| `-x` drops in one position and negates in another | **Not fixed.** The user reverted `drop x`. A statement `-n` on a Copy value is still accepted and does nothing. | a05 |
| Cell is changed through read paths | **Unchanged** (by design) | a02 |
| A struct holding a Cell copies silently; a by-value parameter can be changed through a `?self` method (SPEC says this is rejected); a `=!` binding can be changed | **None fixed.** `b = a` forks the state, `via(a)` changes its parameter, and `f =! Counter(...)` then `f.hit()` changes `f`. | a02 |
| `new x: T = e` and `new x =! e` do not parse | **Not fixed** | a07, a07b |
| A local `w = !m` is rejected, while a field `h.w = !m` re-points the borrow | **Not fixed** | d04, d05, d06 |
| `?F` through a function-type alias is not a borrowed callable | **Not fixed** | g03 |
| `print` swallows write errors | **Not fixed** (`runtime.zig` 1432–1443: `catch {}`) | — |
| No bitwise NOT; `x = :l for` does not parse; `catch` binds looser than `??` | **Not fixed** | d07–d09 |
| No methods on `T` in generic bodies; no `Vec` of owning structs, of `Vec`, or of `Text`; no `?v[i]` | **Not built** (the user settled the designs) | e02–e05, c06 |

---

## 1. Heartburn inventory

**Hurt** means how often a programmer hits it and how confusing it is:
**H**igh, **M**edium, or **L**ow. **Kind** is one of three:

- **essential**: the design needs it;
- **concession**: a deliberate trade, often the user's decision;
- **accident**: it grew rule by rule, and nobody would design it this way.

The last column counts commits in `git log` that fixed or patched the area.

### A. Lending and reading (the biggest source)

| # | Rule or special case | What the learner must memorize | Hurt | Kind | Evidence | Fix commits |
|---|---|---|---|---|---|---|
| A1 | **Implicit reads** | A bare owning value is read in place as a receiver (`p.m()`), a `match` subject, a `print`, `Text(...)` or `!t.add(...)` argument, an `==` operand, and a field base. It must be written `?p` as a function argument (**even an `Int`**: `sizei(k)` for a `?Int` parameter is rejected), as a `for` source (`for x in ?v`), and in `if ?o as x`. Where `?` is needed, a bare name can mean nothing else, since a move is `<p` and a clone `+p`. So the `?` carries no information; it is ceremony that applies in some positions only. | **H** | accident | b01, b02, b03, b04, b05 | "implicit/bare" 12 |
| A2 | **Six "lend as a view" conversions, with holes** | These are accepted: `?a` → `[]T` (array); `!w` → `[]T` (write slice); `?t` → String and `String?` (Text); a `?Text` binding → String, bare; `?b` → `?T`/`!T` (Box); `?b` → String (`Box[Text]`); and a function, literal, or owned closure → `?fun`. These are **not**: `?v` → `[]T` for a **Vec** (you must write `?v[..]`; `sort.sort(!a)` works but `sort.sort(!v)` does not); `?h` → `?P` for a **shared handle** (there is **no way at all** to pass a `*P`'s value to a `fun f(p: ?P)`); `?o` → `String?` for a `Text?`; and a `?Text` as a `for` source. The compiler has a separate fact for each: `arrayViewOf`, `readsAsView`, `unboxes`, `callableOf`, `readsThrough`, and Text's lend recorded as `arrayViewOf`. | **H** | accident | b07, f01, f07, f08, f04, h07, c04 | "slice" 26, "view/Text" 39 |
| A3 | **Five ways to spell a slice** | `s[a..b]` of a String is bare; `?t[a..b]` of a Text needs `?`; `?xs[a..b]` of an array or Vec needs `?`; a `![]T` binding's read slice must be `?w[a..b]`; `p[a..b]` of a `?Text` is bare. | M | accident | c01, c02 | — |
| A4 | **Box versus shared handle** | A Box reaches the members of a struct or enum, but a `Box[Text]` or `Box[Int]` reaches **no** members: `b.len` and `!b.add(...)` are both rejected, even written `(!b).add`. `match b` on a boxed enum is rejected (`match ?b`), while `match s` on an owned enum reads bare. A `*T` reaches members, but cannot be lent as `?T`. | M–H | accident | c05, c07, c10, h05, f01 | "Box" 13 |
| A5 | **A held borrow is forwarded differently for reads and writes** | A held `?T` is forwarded bare, but a held `!T` must be marked again (`!w.m()`, `f(!w)`). | L | concession (principled: every `!` marks a change) | b06 | — |
| A6 | **Receiver sigils** | `?`, `!`, and `<` before a *place* and a method call bind to the receiver, while `+`, `*`, `~`, and `-` bind to the result. The rule needs tree surgery in `src/rig.zig`, and only a place qualifies: `?make().count()` is `?(make().count())` and is rejected, while `(?make()).count()` is accepted. | M | concession (user decision) | f06, c13, c14 | "receiver" 21 |
| A7 | **When a Bool-returning write call needs the long form** | `(!s).insert(k)` is required in conditions and in `and`/`or`/`not` operands. `dup = !s.insert(k)` and `print(!s.insert(k))` are accepted, and read as "not" to every C, Rust, or JS eye. Yet `g = !flag` on a Bool is rejected. | M | concession (user decision 3) that is now inconsistent | a01, e01 | "Bool" 5 |
| A8 | **Borrowed callables** | A function name or a literal goes to a `?fun` bare; a stack closure needs `?f`; an owned closure needs `?cb`. A `?F` through an alias is not a borrowed callable at all. | L–M | accident (alias), concession (the rest) | g03 | — |

### B. Ownership kinds: Copy, owning, clone

| # | Rule or special case | Why it hurts | Hurt | Kind | Evidence |
|---|---|---|---|---|---|
| B1 | **Copy or owning is decided only by structure** | A move-only type with no resource must declare an **empty `drop` body**. `std/random.rig` does this: "The empty `drop` makes it an owning value". Without it, `use_it(t); use_it(t)` silently copies. | M | accident | e06, std/random.rig |
| B2 | **A struct holding a Cell is Copy** | `b = a` silently forks mutable state. A by-value parameter is changed through a `?self` method, which SPEC §10 says is rejected (a checker hole). A `=!` "fixed" binding changes. | **H** | accident / hole | a02 |
| B3 | **A Cell changes through read paths** | `c.set(v)` through a `?self` method, a `?T`, or a `*T`: the `!` does not mark every change. This is Rust's `Cell`, and a fair trade, but DESIGN and WELCOME still claim "every mutation is visible". | M | concession | a02 |
| B4 | **`Cell[Vec]` forwards a hand-picked list of members** | Only `push`, `pop`, `clear`, `len`, `[i]`, and `get(i)`. There is no `insert` or `remove`, and no `for x in ?c`. `!c.push(x)` is **rejected**: the one mutation whose `!` is forbidden. The list will have to be repeated for `Cell[Text]` and `Cell[Map]`. | M | concession (user approved) | d01, d02, d03 |
| B5 | **`+x` means different things by type** | For a handle, a count bump; for plain data, a copy; for a Text, **a new heap buffer**; for a Vec or Box, rejected. DESIGN's cost table still says "a count bump for a handle". | M | accident | g01, g02 |
| B6 | **What a Vec may hold** | Plain data, handles, and boxes only. `Vec[Text]`, `Vec[Vec[T]]`, and `Vec[OwningStruct]` are rejected, and an element of a Vec of handles or boxes cannot be indexed, lent, or have a field read (`v[0].n`, `?v[0]`, `+v[0]`): only a `for` loop reaches it. | **H** | concession ("not yet"; the design is settled) | c06, e02, e03, e03b, e05 |
| B7 | **Arrays hold plain data only, and `for x in arr` copies the array** | Large arrays copy silently. | L | concession | SPEC §2 |

### C. Views and Text (the text branch)

| # | Rule or special case | Why it hurts | Hurt | Kind | Evidence |
|---|---|---|---|---|---|
| C1 | **String is a privileged view** | A String is "Copy plain data" that may carry a loan. Unlike `[]T` or `?T`, it may sit in a `Vec`, and a struct holding it keeps `==`. `Vec[[]Int]` is rejected, and a struct with a `[]Int` field has no `==`. What a String result borrows is inferred from the argument types (`holdsViewOnly`, `viewLoans`, `Borrows.text`), not from anything written. | **H** | concession (the view decision), built as special cases | h01, h02 |
| C2 | **Whether a String may enter shared storage depends on where it came from** | `Cell("")` plus `c.set("lit")` works. `c.set(?t[..1])` is rejected, and so is any String parameter. A generic `Holder[String]` that stores `T` in a Cell is rejected **even when every String is a literal**. An owned closure cannot capture a String parameter. The ROADMAP's "static Strings" fix would add a third kind of String. | **H** | accident (type-level check of a value-level fact) | c11, c12 |
| C3 | **A Vec of views keeps its Text borrowed until the Vec is dropped** | A struct holding a view is released at its last use (c09), but a `Vec[String]` pins its Text to the end of scope, because the Vec's drop counts as a use. You must write `-views` by hand. | M | accident | c08, c09 |
| C4 | **`Vec[Text]` is rejected, and the workaround is `Vec[Box[Text]]`** | A `Box[Text]` element reaches no Text members (`b.len` is rejected), and the Vec cannot be indexed. So the workaround does not work for ordinary text code. | **H** | accident chain (B6 + A4) | c06, c07 |
| C5 | **A `?Text` binding is lent as a String bare, in some places only** | `head(t: ?Text) -> String` can return `t[0..2]` or `t` bare, but `for b in t` is rejected, and `self.title` through a `?self` needs `?self.title`. | M | accident | c02, h07, g06 |
| C6 | **`?t` versus `?t[..]`** | These are two spellings of one thing. `?t` also works where `String?` is expected, but `?o` of a `Text?` does not. | L | accident | f04 |
| C7 | **Temporaries** | A fresh value may live to the end of its statement only in listed positions: a `print`/`Text` argument, an `==` operand, a `match` subject, a part read (`make().len`), or lent with `?`. It is rejected as a method receiver (`make().count()`), yet `(?make()).count()` and `Log.count(?make())` are accepted. The fix-commit history is the evidence: 27 commits mention temporaries. | M–H | accident (grew position by position) | c13, c14, c15 |
| C8 | **A String result borrows every String argument** | So `os.env(key)` is "a view of `key`", although its bytes are static. A signature cannot say "the result is static". | L | concession | STD.md std.os |
| C9 | **Text is built with `Text(a, b)` and `!t.add(...)`; `+` on strings is rejected** | Allocation is visible, and there is one formatter, the one `print` uses. | L | essential | WELCOME |

### D. Bindings and assignment

| # | Rule or special case | Why it hurts | Hurt | Kind | Evidence |
|---|---|---|---|---|---|
| D1 | **`=!` fixed binding** | It is `!`'s fourth meaning. `x =!y` needs its own rejection. A module-level `=!` parses only to be rejected. `new x =! e` does not parse. "Never changes" is false for a Cell-holding value. | M | concession (user kept it twice) | a04, a07b, a02 |
| D2 | **`new` takes one shape only** | Only `new x = e`, and it doubles as the way to re-point a write-borrow local. | L–M | accident | a07, d05 |
| D3 | **`=` on a borrow place depends on where it is** | A local `w = !m` is rejected ("write `new w = !m`"); a field `h.w = !m` re-points; a read borrow `r = ?b` re-points; `w = 5` writes through. | M | accident | d04, d05, d06 |
| D4 | **Writing through `!T` fields** | `u.count += 10` changes a variable declared far away. It is visible where the loan is taken, not where the write happens. | M | concession | SPEC §7 |
| D5 | **`=` means a constant at module level and a variable in a function** | | L | concession | SPEC §3 |

### E. How position changes what a sigil means

| # | Rule or special case | Why it hurts | Hurt | Kind | Evidence |
|---|---|---|---|---|---|
| E1 | **`-x` drops as a statement and negates as a value** | The last line of a `fun` negates; the last line of a `sub` drops. A statement `-n` on a Copy value is accepted and does nothing. | M | concession (user reverted `drop x`) plus an accident (the no-op) | a05 |
| E2 | **`<x` has several effects** | It moves a binding. `<p.f` *writes* the struct when the field is optional (takes it, leaving `none`), copies a Copy field, and is otherwise rejected. `<n` on a Copy value means "done with it". | L–M | concession | g04 |
| E3 | **`!` belongs to four families** | Write borrow, failure, `=!`, and `!=`. | M | concession | — |
| E4 | **Tail moves** | A bare name in `return x`, on the last line, in `if` branches, and in a ternary moves without `<`, but a `break` value needs `<`. | L–M | concession | a06 |

### F. Control flow

| # | Rule or special case | Hurt | Kind | Notes |
|---|---|---|---|---|
| F1 | **Two `swap`s**: `swap(!a, !b)` for places, `!a.swap(i, j)` for elements; disjoint fields are special-cased | L | concession (user kept both) | Borrows are tracked per root, not per path. Fine as is. |
| F2 | **`pass`** | L | essential | Follows from exhaustive `match`. Fine. |
| F3 | **Labels** go only on loops, `match`, and `raw`; `:` has five roles; no label in a `while` header; `x = :l for` does not parse | L | concession / accident | The rule "a label goes where a jump can leave" is good. The gaps are grammar debt. |
| F4 | **Four `catch` forms**: a value, `\|e\|` with a value, a jump, and `\|e\|` with a block. `catch` binds loosest while `??` binds tighter, so `f() catch 1 == 1` is a type error. `return` in a handler leaves the function, although the bars look like a closure's. | L–M | concession | d07 |
| F5 | **`as`** only in `if` and `while` conditions, joined with `and` | L | essential | |
| F6 | **`for` never calls user code**, so iterators are `while !it.next() as x` | L now, M later | concession (user decision) | See the traps in §4. |
| F7 | **`for x, i` puts the element first** | L | concession | A hint covers the mistake. |

### G. Effects and failure

| # | Rule or special case | Hurt | Kind | Evidence |
|---|---|---|---|---|
| G1 | **A bare error value or binding as the last line fails, with no `return`** | L–M | accident (left over from the `.name` fix) | a03, std/text.rig `parse_bool` |
| G2 | **`print` swallows write errors and exits 0** | L–M | accident | runtime.zig |
| G3 | **`sub main` and `test` may propagate without being marked `!`** | L | concession | SPEC §1 |

### H. Generics and types

| # | Rule or special case | Hurt | Kind | Evidence |
|---|---|---|---|---|
| H1 | **A generic body cannot call a method on `T` or read its field** | **H** (for the standard library) | concession (the user approved the design; not built) | e04 |
| H2 | **Generic functions and methods of generic types are not values** | L | essential (Zig) | |
| H3 | **Type arguments in expressions must be spellable as expressions** (`Vec[[]Int]()` is rejected; use an alias) | L–M | concession | SYNTAX §11 |
| H4 | **No bitwise NOT** (`~` means weak) | L | accident | d09 |

### Roots

About two thirds of the High and Medium rows come from five roots:

1. There is **no single rule for lending**: A1, A2, A3, A4, A8, C5, C6.
2. There is **no single notion of a view**: C1, C2, C3, C8.
3. There is **no single notion of ownership kind**: B1, B2, B5.
4. **Temporaries and elements are handled by position lists**: C7, B6, C4.
5. **`!` and `=` are overloaded**: A7, D1, D2, D3, E3.

---

## 2. The pure path: eight changes

They are ordered by exceptions removed per unit of disruption. "Cost" is
compiler work plus the migration of the docs and suite. **Q** marks a change
that reopens a decision the user already made; it is put to the user as a
question.

### P1. One lending rule: a sigil lends the view the context expects

**Rule it replaces.** Today there are six coercions (`arrayViewOf`,
`readsAsView`, `unboxes`, `callableOf`, Text's `?t`, `?Text` read bare) and
four holes (Vec, `*T`, `Text?`, `for` over `?Text`).

**New rule.** Each type has a short, fixed list of *views*, and `?x` / `!x`
lend whichever view the context expects. It is one table:

| Owner `x : X` | Views `?x` can lend | Views `!x` can lend |
|---|---|---|
| any `T` | `?T` | `!T` |
| `[N]T`, `Vec[T]`, `![]T` | `[]T` | `![]T` |
| `Text` | `String` | `!Text` |
| `Box[T]` | the views of `T` | the write views of `T` |
| `*T` | the read views of `T` | (none: a handle only reads) |
| `X?` | `View?` for each view of `X` | |

The table composes, so `Box[Text]` → `String` and `*Text` → `String` need no
rule of their own. Slicing is the same lend with bounds: `x[a..b]` is the
`[]T` or String view of part of `x`. Member access through `Box` and `*T` then
works for every type, because `b.len` is simply a read of the value inside.

```rig
# before                                  # after
sort.sort(!v[..])                         sort.sort(!v)
print(total(?v[..]))                      print(total(?v))
fun area(s: ?*Shape) -> Int               fun area(s: ?Shape) -> Int    # one function serves Shape, Box[Shape], *Shape
b = Box(Text("x"))                        b = Box(Text("x"))
#   b.len, !b.add("!") impossible             print(b.len); !b.add("!")
for b in ?t        # but a `?Text` param     for b in ?t        # and `for b in t` for a ?Text param,
                   # t: `for b in t` fails                      # like every other read of it (see P2)
```

**Removes** A2, A3 (mostly), A4, C4's second half, C5, and C6. The
compiler's six facts become one `lendsAs(node) -> View`.

**Cost.** **M.** Typecheck gathers the coercions into one table. Ownership
already walks each coercion as a borrow of the root, so the new rows
(`*T` → `?T`, Vec → slice) are the same loan on the same root. Emit adds
`&h.value` for a handle and `v.items` for a Vec. No syntax changes, and no
accepted program changes meaning; a set of rejections become acceptances.

### P2. One read rule (**Q**: reopens decision 13, "lending always shows its sigil")

**Rule it replaces.** A read needs `?` as an argument, a `for` source, and an
`if … as` value, but not as a receiver, a `match` subject, a `print`/`Text`
argument, an `==` operand, or a `?Text` held binding. A Copy value needs
`?k` for a `?Int` parameter.

**Recommended rule.** *A read borrow is implicit wherever one is expected; `?`
may always be written; `!` and `<` must always be written.* This is exactly
today's `match` rule, applied everywhere. A bare owning name can never mean a
move (that is `<x`) or a clone (that is `+x`), so no program changes meaning.
Only rejections become acceptances, and the call site still shows everything
that can change or leave: `!` and `<`.

```rig
# before                                  # after (both spellings accepted)
print(size(?p))                           print(size(p))
for x in ?v                               for x in v
if ?o as x                                if o as x          # x : ?T, as `match o` already binds
sizei(?k)       # k: Int                  sizei(k)
w = first_word(?t)                        w = first_word(t)  # still borrows t; the checker says so on misuse
```

**The alternative that keeps decision 13 literally.** Require `?` for every
read borrow of an *owning* value: `match ?s`, `print(?v)`, `?a == ?b`,
`Text(?t)`. Keep the receiver implicit, as DESIGN admits. This is consistent
too, but noisier, and it is the direction the user already moved away from
(for example, `print` and `match` read bare). Either is fine. The present mix
is the only bad option.

**Removes** A1, the `?Int` case, most of A3 and C5, and the most common error
a newcomer meets (the earlier readability review counted 595 `?x` sites).

**Cost.** **S** in the checker, since the loan is the same one the sigil
would take. Docs and hints need a sweep, and a formatter can pick one style.

### P3. One temporary rule: every fresh value lives to the end of its statement

**Rule it replaces.** Today a temporary may live only in a list of positions
(`print`/`Text` arguments, `==`, a `match` subject, a part read, lent with
`?`), and is rejected as a method receiver or elsewhere. `?make().count()` is
rejected while `(?make()).count()` is accepted.

**New rule.** A fresh value (the existing `handsOverFresh` predicate) that
nothing moves is dropped when its statement ends, wherever it stands: as an
argument, a receiver, an operand, a subject, or a part. Only two things stay
errors: a borrow of it, or a view of it, kept past the statement; and an
expression statement whose value would be thrown away.

```rig
# before                                  # after
l = make()                                print(make().count())
print(l.count())
print(Log.count(?make()))                 print(make().count())
```

**Removes** C7. This also stops the stream of temporary fixes (27 commits),
because one predicate replaces the position list.

**Cost.** **S–M.** The slot, flag, and `dropStmtTemps` machinery exists; this
widens its trigger from "positions" to "any fresh value not moved". Receivers
of `!self` methods on temporaries stay rejected ("the change would be lost"),
which is a reason about meaning, not about position.

### P4. One kind of view: String is simply `[]U8` with UTF-8 by convention

**Rule it replaces.** Today String is Copy plain data with a hidden `view`
bit. It may sit in a Vec and keeps `==`, unlike `[]T` or `?T`. Whether it may
enter a Cell depends on its type in generic code and on its origin elsewhere
(C1, C2, C3, C8).

**New rule.** `String`, `[]T`, `![]T`, `?T`, and `!T` are **views**, and they
follow one set of rules:

- A read view copies freely, and a write view moves.
- A view carries its loans wherever it goes: fields, `Vec`, optionals,
  captures, and results.
- `==` on a struct holding views compares what they view.
- **Shared storage (Cell, Signal, owned closures, `*T`) accepts a value only
  when it carries no loan.** This is checked per value, from the loans the
  checker already follows, not per type. A literal, a module constant, and
  `os.args()` carry none.
- Dropping a Vec of views does not count as a use of what they view (Rust's
  `may_dangle`).

```rig
# before                                   # after
v: Vec[[]Int] = Vec()      # rejected       v: Vec[[]Int] = Vec()     # a Vec of views, like Vec[String]
h = Holder[String](...)    # rejected,      h = Holder[String](...)   # accepted; h.put("a") passes,
h.put("a")                 # even literal   h.put(s)                  # rejected only when s may view a Text
views: Vec[String] = ...                    views: Vec[String] = ...
!views.push(?t[..1])                        !views.push(?t[..1])
print(views)                                print(views)
-views                     # needed         !t.add("!")               # views is dead after its last use
!t.add("!")
```

The generic case is handled with the requirement machinery that exists. A
body that stores a parameter's value in shared storage records "argument `x`
must carry no loan", and each *call* checks its argument's loans, as it
already checks borrow modes. This is the ROADMAP's "Static Strings" item,
done as one rule for all views instead of a third kind of String.

**Removes** C1, C2, C3, and the Text-specific parts of `viewLoans`,
`holdsViewOnly`, and `Borrows.text`.

**Cost.** **M–L.** It touches ownership (loans on Vec contents,
per-argument storage requirements) and sema's plain-data rules. It reopens
nothing: the user decided "String = checked view, *like array slices*", and
this makes it literally so. Do it **before** io, fs, and Map freeze their
signatures.

### P5. Owning elements everywhere (the user's settled design, built)

**Rule it replaces.** Today a Vec holds only plain data, handles, and boxes;
it cannot be indexed or lent when it holds handles or boxes; and arrays and
slices hold plain data only.

**New rule.** A Vec, an array, and a `![]T` hold any type.

- An element is a place: `v[i]` is read per P2, `?v[i]` and `!v[i]` lend it,
  and `<v[i]` takes an optional element.
- A bare `v[i]` that would *copy* an owning value out is the error it is
  today.
- `copy` and `fill` still need plain elements. `swap`, and so sorting, only
  move elements, so they work on any.

```rig
# before                                   # after
names: Vec[Box[Text]] = Vec()              names: Vec[Text] = Vec()
!names.push(Box(Text("ann")))              !names.push(Text("ann"))
for b in ?names                            print(names[0].len, names[0] == "ann")
  print(show(?b))    # b.len rejected      sort.sort_by(!names, |a, b| a < b)
```

**Removes** B6, C4, and the `Vec[Box[T]]` pattern. It is also the substrate
Map, Set, and the file APIs need.

**Cost.** **M.** The runtime already drops elements, and `slot`/`constSlot`
reach them. The work is in the loan per element path (borrow the Vec root,
as `for x in ?v` already does). It reopens nothing (decision 20).

### P6. Ownership kinds are explicit, and `+` means one thing (partly **Q**)

**Rule it replaces.** Today Copy or owning is decided only by structure,
which forces the empty-`drop` hack; a struct holding a Cell is Copy; and `+`
behaves four ways.

**New rule.**

- A type's kind is **plain** (copies), **owning** (moves), **handle**, or
  **view**. It is derived from the fields, as today, but a struct may also
  **declare** `owns`: `struct Rng owns`. The ROADMAP already plans exactly
  these words (`copy`, `owns`, `view`) for Zig-backed types.
- **A Cell makes its holder owning (not Copy).** This is the pending user
  question "Cell structs non-Copy", marked **Q**.
- `+x` means "a new owner equal to `x`", for every type that can make one:
  - a count bump for a handle;
  - a copy for plain data;
  - a deep copy for an owning value whose parts can all be copied. Text is
    one. So are a Vec of plain elements and a Box of copyable data.

  The type decides the cost, as Rust's `.clone()` does, and DESIGN's cost
  table says so.

```rig
# before                                   # after
pub struct Rng                             pub struct Rng owns
  state: U64                                 state: U64
  drop(!self)                              # (no dummy drop)
    pass
b = a      # a has a Cell: silent fork     b = a        # rejected: write <a or +a
w = +v     # Vec: rejected                 w = +v       # a new Vec of the same Ints (allocates, as + says)
```

**Removes** B1, B2, and B5. B2's silent forks disappear, because `b = a` and
`via(a)` then need `<a` or `+a`. The SPEC-versus-checker hole (a `?self`
Cell write on a by-value parameter) still needs its own failing test and a
one-line fix; with this change it is no longer a hidden copy, only a rule
violation.

**Cost.** **S** for `owns` and Cell non-Copy (a kind flag in sema). **S–M**
for `+` on Vec and Box (runtime `clone`).

### P7. `=` on a borrow place follows one rule, and `new` only shadows

**Rule it replaces.** Today a local `w = !m` is rejected ("write
`new w = !m`"), while a field `h.w = !m` re-points and `r = ?b` re-points.
`new` takes only `new x = e`.

**New rule.** Assigning a *borrow* to a borrow place re-points it, and
assigning a *value* writes through, for locals and fields alike. The type on
the right decides; this is already how fields work (`writesThrough`). `new`
only shadows, and takes every binding shape: `new x: T = e`, `new x =! e`.

```rig
# before                                   # after
w = !n                                     w = !n
w = 5                                      w = 5          # writes n
new w = !m     # the only way              w = !m         # re-points, as h.w = !m does
new x: U8 = 5  # does not parse            new x: U8 = 5
```

**Removes** D2 and D3.

**Cost.** **S** (grammar: `new` over the whole binding form; typecheck: one
branch).

### P8. A habit never changes what a program means (the Bool part is **Q**)

This change has three small parts:

1. **Bool results of write calls** (**Q**: the user decided the Bool rule
   applies only in conditions, and it is a pending purity question). A
   write-borrowing call whose value is a Bool is written in the long form
   wherever its value is used: `dup = (!s).insert(k)`. That is one rule
   instead of a list of positions, and it matches the fact that `g = !flag`
   is already rejected.
2. **A statement `-x` on a Copy value is rejected.** Today it is a silent
   no-op.
3. **Failing is always written.** A bare error value or error binding as a
   function's last line is rejected, with the hint `return E.bad`, just as
   `.name` already is.

```rig
# before                                   # after
dup = !s.insert(1)       # reads "not"     dup = (!s).insert(1)
-n                       # n: Int, no-op   # error: `-n` drops nothing; `n` is plain data
ParseError.invalid       # last line fails return ParseError.invalid
```

**Removes** A7, E1's no-op, and G1.

**Cost.** **S.** One check each, and a few lines migrated in the suite and
`std/text.rig`.

### Questions for the user (not proposed as changes)

Each of these reopens a decision already made. A recommendation is given only
where the evidence is strong.

1. **`=!`** (D1, E3). The user kept it twice. It is `!`'s fourth job; it
   brings a token trap and a module-level special case; and "never changes"
   is false for Cell holders. A cheap middle path is P7's `new x =! e` plus
   P6's Cell change. The pure option is a word (`fix x = e`) or no fixed
   bindings (the emitter already chooses `const` or `var`).
2. **`-x` statement versus `drop x`** (E1). The user reverted `drop x`. With
   P8 applied, the remaining cost is "the last line of a `fun` negates". Lean:
   keep `-x`, and accept that it is syntax, not ownership.
3. **Receiver sigils and their precedence exception** (A6). Keep them. P3
   makes the `?make().count()` confusion moot.
4. **Two swaps** (F1). Keep them.
5. **`Cell[Vec]` forwarding** (B4). Keep it, but **freeze the list**: do not
   grow it for Text or Map. Everything else goes through `replace`/`set`
   (see the Map trap in §4).
6. **P2's read rule** (decision 13), and **P6's Cell-holders-are-not-Copy**
   and **P8's Bool rule** (pending purity questions).

---

## 3. The core after these changes: ten sentences

1. Every value is **plain** (it copies), **owning** (it has one owner and
   moves), a **handle** (`*T`, `~T`), or a **view** (a borrow of
   something else); a type is one of these by its parts, or by declaring
   `owns`.
2. A bare name only reads: it copies plain data and views, and reads owners
   in place; it never moves, clones, writes, or drops anything.
3. `<x` moves, `+x` makes a new owner equal to `x` (a copy, a count bump, or
   a deep copy, as the type says), and `-x` drops now; any owner not moved
   is dropped where its scope ends, and a value no name holds is dropped
   where its statement ends.
4. `?x` lends `x` to read and `!x` lends it to write, as whichever view the
   context expects (itself, its elements as a slice, its text as a String,
   the value in its Box or handle), and a read lend may go unwritten.
5. At any moment a value has any number of read loans or one write loan, and
   a loan lasts until the last use of every view that carries it, wherever
   that view went (a field, a Vec, an optional, a closure, a result).
6. A function returns a view only of what it was lent, and its result carries
   the loans of everything it was lent.
7. `*x` moves `x` into a counted box, whose handles only read; `~h` holds it
   weakly, and `h.upgrade()` is the way back.
8. Every change is marked by `!` where it is lent, except inside a `Cell`,
   which changes through any path, and so accepts only values that carry no
   loan, as all shared storage does.
9. `e!` propagates a failure and `e?` propagates an absence; failing is
   always written, and every fallible call says what happens to its failure.
10. Only code inside `raw` may break these rules.

**What does not fit.**

- **The Cell exception** (sentence 8) stays an exception. That is honest,
  and it is Rust's own.
- **Write-through `!T` fields** fit (a write view in a field writes where it
  points), but a reader still meets them far from the loan.
- **Syntax rules are not in the core**: `-x` negating as a value, the
  receiver-sigil precedence, `=!`, labels, and `catch` forms. They are not
  ownership, and each is a single documented syntax rule.

The core does **not** fit in ten sentences today. Sentences 2 and 4 would
each need a list of positions (A1, A2), sentence 3 a list of temporary
positions (C7), and sentence 1 the String-is-plain-but-carries-a-loan
exception (C1).

---

## 4. Traps waiting in planned features

### io and fs

**Likely design, and its traps.**

- A `File` struct, Zig-backed and owning, with `read(!self, buf: ![]U8) -> Int!`
  and `read_all -> Text!`.
- A line iterator, `while !r.next_line()! as line`, that returns Strings into
  the reader's own buffer.
- A writer with `!w.write(...)`.

The traps:

1. `Vec[File]` and structs holding a File are rejected (B6).
2. A line view borrows either the iterator or the Text, depending on hidden
   type rules (`holdsViewOnly`). Today `text.lines(s)` views borrow `s`'s
   Text and not the iterator; a reader's views must borrow the reader. The
   call sites look identical.
3. `print` swallows errors while `w.write` fails, which gives two failure
   policies.
4. `close` errors: a `drop` cannot fail.
5. Errors carry no payload (path, errno).

**Fit to the core.**

- Build P4 and P5 first.
- Make view results follow sentence 6 only. A result carries the loans of
  what the call was lent. A view read out of a view-holding struct carries
  that struct's *views'* loans; a view of bytes the struct *owns* carries a
  loan on the struct. That is one rule, stated on types the reader can see.
- Give `print` the io policy: panic on a write failure, or remember it and
  exit non-zero. Choose one policy for both.
- Make `<f.close()!` the fallible way to close. `drop` closes and ignores the
  error, as Zig's `defer f.close()` does, and the docs say so.
- Write through the one formatter (`Text`/`print`): `!w.write(a, b)!`.
- Decide error payloads **before** fs signatures freeze, or commit in
  writing to "no payloads; details come from a returned value".
- Paths are `String` parameters. Returned names are `Text` (owners), not
  views into a directory iterator's buffer, unless that iterator is written
  as a lending iterator per sentence 6.

### Map and Set with owning values

**Likely traps.**

1. `Map[String, V]` with keys that view a Text pins the Text (C3).
2. `Map[Text, V]` needs owning keys (B6).
3. A lookup by `String` into `Map[Text, V]` needs "a Text key compares with a
   String" (Rust's `Borrow<str>`).
4. `get` returning `?V` hits "a generic container cannot lend `?T` for an
   owning `T`".
5. `Cell[Map]` would get a forwarded member list like `Cell[Vec]`.
6. Hashing needs methods on `T` (H1).

**Fit to the core.**

- Build P4 and P5 first.
- Make a lookup take **the key's view** from P1's table: `get(k: KeyView)`,
  where `Text`'s view is `String` and a `Vec[T]`'s is `[]T`. The same table
  that drives lending drives lookups, with no `Borrow` trait.
- The API:
  - `m.get(k) -> ?V?` (a read view, by P1 and P2);
  - `!m.get_mut(k) -> !V?`;
  - `!m.insert(k, <v) -> V?` (it hands back the old owner);
  - `!m.remove(k) -> V?`.
- Iterate with `while !it.next() as e`; do not make Map a compiler built-in
  just to reach `for` (see "`for` over iterators").
- **Do not add `Cell[Map]` forwarding.** Shared maps are
  `*Cell[Map[K, V]]` with `replace`/`set`, and the existing
  "take it out, use it, put it back" idiom is documented once.

### Generics with methods on `T`

**Likely traps.**

1. A body's `x.m()` assumes a receiver mode; an instance whose `m` takes
   `!self` must be rejected at the instance, with the implicit read rule
   applied the same way.
2. Instances with `T = *P` reach methods through the handle, while
   `T = Box[Text]` reaches none (A4).
3. Protocol names get invented per library (`eq`, `hash`, `less`, `fmt`,
   `next`), while `==` never calls `eq`.
4. Body-less Zig-backed generics need "declared requirement bounds" (the
   ROADMAP), which is a trait syntax arriving by the back door.

**Fit to the core.**

- Build P1 first, so member access through Box and `*T` is uniform.
- Keep "operators never call user code". Protocols are named methods that
  library code calls explicitly. Fix the names (`hash`, `eq`, `less`, `fmt`,
  `next`) in STD.md before the first container.
- Write declared bounds in the vocabulary the inferred requirement records
  already use (`[K: ==, hash]`), so future traits are named sets of these,
  not a second system.
- A method call on `T` that returns a view carries the loans of `x`
  (sentence 6), and the body is checked once for the worst case, as it is
  today for moves.

### `Vec[Text]`

The trap is already sprung: it is rejected, and the `Vec[Box[Text]]`
workaround reaches no Text members (c07). Adding forwarding to `Box[Text]`
would only grow A4. P5 is the fix, together with P1 (`?v[i]` lent as String)
and P2 (`v[i].len`, `v[i] == "x"` read bare). Sorting works once `swap`
accepts owning elements.

### `for` over iterators

**Decision.** The user decided `for` never calls user code; iterators use
`while !it.next() as x`.

**The trap.** Built-in collections get `for`, with its sigil modes, index,
`else`, and break value, and everything else gets `while`. The pressure to
make Map and Set compiler built-ins, "so `for` works", would add a third
class, and grow `Cell[...]` forwarding with it.

**Fit to the core.**

- Keep the decision.
- Give `while … as` everything `for` has: it already has `else`, labels, and
  break values. Add the index only if real programs ask for it.
- Keep std Map and Set in Rig, iterated with `while !m.iter().next() as e`
  or an equivalent.
- Make iterator views obey sentence 6, so a lending iterator (a file's
  lines) and a non-lending one (`text.split`) differ only in what they own,
  which their types show.

---

## Appendix: probes

All are in `scratchpad/seams/surface/` and are run with the text branch's
compiler (`run.sh`).

| Group | Probes |
|---|---|
| Earlier findings | `a01`–`a07b` (Bool short form, Cell copies and the hole, error binding as the tail, `=!`, `-x`, tail moves, `new` shapes) |
| Implicit reads | `b01`–`b07` (reads by position, `?Int`, `for` over a Vec, `if as`, `==`/`Text` arguments, held write borrows, array versus Vec as a slice) |
| Text and views | `c01`–`c15` (Text slicing, `?Text` bare, Box[Text], Vec[Text], Vec[Box[Text]], a Vec of views pinning its Text, Cell[String], generic Cell[T] with String, temporary receivers) |
| Other surface | `d01`–`d10` (Cell[Vec] members, write-through, re-pointing, `catch` precedence, labeled value loop, `~` on an integer, Box auto-deref) |
| Bool, Vec, generics | `e01`–`e07` (Bool `!`, Vec of owning values, Vec of handles, generic methods, Vec[Vec], the empty-drop hack, `catch` return) |
| Handles and Text | `f01`–`f09` (`*T` cannot be lent as `?T`, `*Text`, a Text field, `Text?`, a Text payload, receiver sigils) |
| Clone and views | `g01`–`g06` (clone of Text, Vec, and Box; alias `?F`; views of fields) |
| Views compared | `h01`–`h07` (`Vec[[]Int]`, `==` with slice fields, constant slices, matching a Box, `for` over Text and `?Text`) |
