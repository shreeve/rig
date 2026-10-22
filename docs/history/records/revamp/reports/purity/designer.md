# Rig: a designer's review for consistency, symmetry, and completeness

Reviewer role: an experienced programming-language designer. This is a read-only
review of `main` at cf644a0 (suite 1762/0/0). I read AGENTS.md, docs/DESIGN.md,
SYNTAX.md, SPEC.md, WELCOME.md, docs/ROADMAP.md, rig.grammar, the ledger's user
decisions and language questions, and the audit reports. I checked every claim
below that is not a quotation from the docs against `bin/rig` with about 110
probe programs, in `scratchpad/purity/designer/` (named `p01`...`z03`; the name
is given where a claim rests on one).

The short version: Rig's core is unusually coherent. The sigil algebra, the
"a habit can break the compile but never change the meaning" stance, square
brackets for compile time, and "accept means correct" all hold up under
probing. The weak spots are around the edges of the algebra: **which reads need
a `?`**, **what `=` does to a borrow**, **`!` doing four jobs**, and a long tail
of v1 restrictions that a standard library will hit on its first day. None of
the recent decisions was a disaster. About half were clean simplifications, and
the other half were reasonable compromises that each left a small rule behind.
Those small rules add up: I count **31 carve-outs** a learner has to memorize,
plus **24 "not yet" restrictions** they will run into.

---

## 1. Where Rig held strong, and where it caved

"Held strong" means the decision made the language smaller or more uniform.
"Caved" means it bought convenience or taste with a new exception. Both are
legitimate trades, but only the first kind is free.

### The user's recent decisions, one by one

| Decision | Verdict | Why |
|---|---|---|
| **Paren-free calls removed** | **Held strong.** The cleanest win of the whole redesign. | It deleted juxtaposition from the grammar, the spacing rule for expressions, the `print f -1` trap, and the text-scanning `]` heuristic (the frontend audit's token merge became possible only because of it). "A name alone never runs code" is a one-line rule with no exceptions. Nothing was lost: 1570 of the 1642 calls already had parentheses. |
| **A prefix sigil touches its operand** | **Held, with two small leaks.** | It keeps the principle "spacing can be wrong but never mean something else", which is a lint, not a meaning. It leaks in two places: `. red` is still accepted as `.red` (probe `y02`) and `@ sizeOf(...)` as a builtin, although both start operands by position. And `x =!y` needs its own rejection because `=!` is one token. |
| **`=!` is the fixed binding** | **Caved (taste).** | It gives `!` a fourth meaning (after write borrow, failure, and `!=`), and DESIGN.md itself calls it "the one place `!` appears in an operator that is not about borrowing or failure". It brings three special rules with it: `x =!y` is rejected as a token trap; a module-level `=!` parses only so that it can be rejected (module `=` already means constant, so the local and module meanings of `=` point opposite ways); and `new x =! e` does not parse (`p02`). It adds little that the emitter's own const/var choice does not already give. |
| **`new` rebinds** | **Held (principled), but half-built, and it now does double duty.** | Explicit shadowing is the right answer to the `x = e` declare-or-assign style. But `new x: U8 = 5` and `new x =! 5` do not parse (`p01`, `p02`), so `new` supports only one of the four binding shapes. And `new w = !m` is also the way to re-point a write-borrow local (see "write-through" below), which is a second job. |
| **`for x, i` is element first** | **Held, against convention.** | It is Ruby's `each_with_index` order and reads naturally ("each x, and its index"). It is also the only silent-wrong program a newcomer writes: `for i, x in [10, 20]` prints `10 0 / 20 1` with no warning, because the hint fires only when the two types differ (`y03`). Python, Go, Rust, JavaScript, and Zig all put the index first. |
| **`match` must be exhaustive** | **Held strong.** | It removed a silent-no-op hole and matches what Rust and Zig users expect. `pass` came with it as a necessity. One consequence to know: a match on an error always needs `_`, since errors are an open set (`y06`). |
| **`pass` added** | **Held (a necessary consequence).** | It is Python's precedent. It is a statement with no value, which is the right choice. |
| **Labels only on loops, `match`, and `raw`** | **Held.** | "A label goes only where a jump can leave" is a principled rule. What remains: `x = :l for ...` (a labeled loop as a value) does not parse (`p09`), and a jump inside a `while` header cannot take a label because `:` there starts the step. |
| **Write borrows exclusive for every type** | **Held strong.** | It removed a Copy-type carve-out, so the aliasing rule now has no exception. It costs `f(!n, n)` patterns, which is the right cost. |
| **Writing through `!T` fields and elements** | **Caved (it completes writes but creates a local/field split).** | `h.w += 1` now works, which is good. But for a local, `w = !m` is rejected ("write `new w = !m`"), while for a field, `h.w = !m` quietly re-points the borrow (`v01` vs `v02`). What `=` does to a `!T` place now depends on whether the place is a local or a field, and for fields on the type of the right side. A read-borrow local `r = ?m` re-points too (`v04`). |
| **`sub f()!` for a fallible `sub`** | **Held strong.** | It pairs with the type `sub(A)!`, and rejecting `fun ... -> Void` removed a duplicate way to write a procedure. `sub main` and `test` blocks remain implicitly fallible, which is a small, documented carve-out. |
| **`String` is a view, `Text` will be the owned text** | **Held on naming; the hard part is undecided.** | The names are right. But `String` is documented as a Copy value, and ROADMAP says "a slice of a built (heap) string will be a borrow of it". Once `Text` exists, a `String` taken from a `Text` has to be borrow-tracked, while a `String` literal does not. That will change what `String` *is* (Copy, or a view with a source), and it touches every API that takes a `String`. It must be settled before the standard library freezes any signature. |
| **`+% -% *%` wrapping operators** | **Held (Zig precedent), but the set is incomplete.** | There is no `<<%` and no rotate. More importantly, **Rig has no bitwise NOT at all**: `~` is taken by weak handles (`~a` on a `U8` says "weak reference requires a shared handle", `u13`), and `not a` requires a `Bool` (`y01`). Hash and bit-twiddling code must write `x ^ U8.max`. |
| **`Int(enum)`** | **Held, one way only.** | Using a type name to convert is uniform: `U8(x)`, `Byte(x)` through an alias, `Meters(3.5)` for a one-field struct all mean "make a T from this". The reverse, `E(1)`, is rejected (`u07`), which is fine until a decoder needs it. |
| **Aliases fully as types** | **Held, with one leak.** | Constructors, limits, and conversions all work through an alias. But `type F = fun(Int) -> Int` then `?F` is *not* a borrowed callable, because "only `?fun(...)` written as such" is one (SPEC §11; probe `p05` fails with a confusing type error). The spelling, not the type, decides. There are also no generic aliases (`type W[T] = ...`, `p16`). |
| **Module constants with `=`** | **Held, but it inverts `=`/`=!`, and the value set is narrow.** | "A module has no mutable globals, so `=` there is a constant" is principled. But it makes `=` mean "variable" inside a function and "constant" at module level, and a module-level `=!` an error. Constants hold only literals, `.variant`, operators, ternaries, and arrays: no struct constant (`ORIGIN = P(x: 0)`, `u03`), no function value (`F = twice`, `p15`), and no associated constants (`u06`). A standard library wants all three (tables, defaults, dispatch tables). |
| **`pub` on fields and methods** | **Held strong.** | Private by default, per module, with enum variants always public, is a clean rule. The only oddity is that a `pub` function may return a private type that importers can hold but not name, and Rust has the same issue. |

### Other special cases found along the way

| Special case | Verdict |
|---|---|
| **Receiver sigils** (`!v.push(x)` = `(!v).push(x)`), plus the rule that a `!`-receiver call returning `Bool` must be written `(!s).add(k)` in a condition or an operand of `and`/`or`/`not` (`r13`) | **Caved.** The precedence exception is well argued (the three sigils are exactly the receiver modes), and the checks keep it honest. But it is an exception to "postfix binds tighter than prefix", it needs tree surgery in `src/rig.zig`, and it drags in the Bool rule, which applies only in some positions (`added = !set.insert(k)` is fine, `if !set.insert(k)` is not). |
| **Statement `-x` drops; value `-x` negates** | **Caved** (the user reverted `drop x`). The same line `-r` drops in a `sub` and negates as the last line of a `fun` (`q01`, `q02`). DESIGN's first law says each sigil "has one meaning". The keyword `drop` exists but declares a destructor rather than dropping anything. |
| **Implicit read borrows** (details in §2) | **Caved.** Some positions read in place with no `?` and others demand one. |
| **`Cell[Vec[T]]` forwards `push`, `pop`, `clear`, `len`, `[i]`, `get(i)` without `!`** | **Caved.** It is interior mutability, which is fine, but it is a hand-picked member list: no `for x in ?c` (`y04`), no `swap`, `fill`, or `copy`. |
| **Two swaps**: `swap(!a, !b)` for places and `!a.swap(i, j)` for elements; `swap(!t.left, !t.right)` on disjoint fields is special-cased while `swap(!a[0], !a[1])` is rejected | **Caved** (user-approved). Borrows are tracked per root, not per field path, so disjoint fields need a special case. |
| **`print`, `replace`, and `swap` are builtins that a declaration may hide; `print` is not a value and takes no keyword arguments** (`z03`) | **Neutral.** It is small, but the "may hide" rule and the "not a value" rule are two more things to know. |
| **`@sizeOf(Int)` takes a type in parentheses** | **Leak** of the "brackets for compile time" rule, inherited from Zig. `@sizeOf[Int]()` is rejected as "the pin sigil is reserved" (`p20`). |
| **Type arguments in expressions must be "expression-shaped"** | **Caved.** `a: Wrap[[3]Int]` works in a type, but `Wrap[[3]Int](...)` in an expression does not (`z01`), and neither do `Vec[[]Int]()` or `Cell[*(Node?)]`. The fix is an alias. It is the price of "no turbofish", and a real one. |
| **`sub main` and `test` may propagate with `!` without being marked fallible** | **Mild carve-out.** `sub main()!` is also accepted (`u01`), so there are two spellings. |

### The exceptions list a learner must memorize

Below are the rules that say "X, except ...". Rules that are simply the design
(for example "a closure's bar list holds captures and parameters") are left out.
Restrictions that are only "not built yet" are in the second list.

**Carve-outs (31):**

1. A read borrow of a receiver is implicit (`p.m()`), but a read-borrow argument needs `?` (`f(?p)`, even for an `Int`: `r01`).
2. A `match` subject is read in place bare (`match s` on an owning enum, `x02`), but a `for` over a Vec needs `?v` (`x03`) and `if o as x` on an owning optional needs `?o`, `<o`, or `+o` (`x01`).
3. `print(x)` reads an owning value bare (`x04`).
4. A held read borrow is forwarded bare; a held write borrow must be marked again with `!` (`v05`, `v06`).
5. `for` over an array, slice, or String is bare (the array is *copied*); over a Vec it needs a sigil, except a Vec that a call returns or a held `?Vec`/`!Vec`.
6. `return x` and a bare last expression move without `<`; everywhere else a move needs `<x`.
7. `<x` of a Copy value is legal and means "done with `x`"; `<p.f` of a Copy field copies and leaves `p` whole; `<p.f` of an optional field *takes* it and leaves `none`; `<p.f` of any other owning field is rejected.
8. Prefix binds looser than postfix, except `?`, `!`, and `<` before a place followed by a method call.
9. That short form is rejected when the call returns `Bool` and stands in a condition or as an operand of `and`/`or`/`not`; it is accepted everywhere else.
10. `?p.m()` is optional; `!p.m()` and `<p.m()` are required.
11. `=` on a `!T` local writes through, and re-pointing is `new w = !m`; on a `!T` field, `h.w = !m` re-points; on a `?T` local, `r = ?m` re-points.
12. A bare `w: !Int` copies its value where an `Int` goes; where a `!Int` goes it must be `<w`.
13. `-x` as a statement drops (only a whole binding, never `-s.f`); `-x` as a value negates; the last line of a `fun` is a value, and the last line of a `sub` is a statement.
14. `Cell` is changed through read paths (`c.set`); `Cell[Vec]` answers exactly six Vec members without `!`, and no others.
15. A borrow of a temporary may be passed only to a call whose result keeps no borrow, or used by `print`, as a `match` subject, as a `for` source, or in an `as` condition.
16. A temporary array is accepted bare as a `[]T` argument (to a call that keeps no borrow); a named array needs `?a`, which then means `?a[..]`.
17. A String is sliced bare (`s[0..2]`, and `?s[0..2]` also works, `r06`); an array or Vec is sliced as `?xs[a..b]`; a `![]T` binding's read slice must be `?s[a..b]`.
18. `swap(!t.left, !t.right)` (disjoint fields) is accepted; `swap(!a[0], !a[1])` is not.
19. At module level `x = e` is a constant and `=!` is an error; in a function `x = e` is a variable and `=!` is fixed.
20. `new` takes only `new x = e`: no type annotation and no `=!`.
21. `x =!y` is rejected (it could be `=! y` or `= !y`).
22. Parameters are immutable except `!T`; loop, pattern, and `as` bindings are immutable except under `for x in !xs`, `match !e`, and an owning `if <o as n`.
23. Every local must be read; parameters are exempt; a value with drop glue counts as read by its own drop.
24. A `fun` needs `->`; a `sub` has none; a fallible `sub` ends its header with `!`; `sub main` and `test` may propagate without it.
25. `()` may be left out in a declaration with no parameters, but never in a call.
26. Plain functions and `Type.method` are values; generic functions, methods of generic types, `extern` functions, `print`, and `c.bump` through a value are not.
27. `?fun(...)` is a borrowed callable only when spelled so, not through an alias.
28. Parameter defaults are literals or constants; field defaults may also be `Vec()`, `Cell(lit)`, or `[n of x]` (`p10`).
29. The handle sigils `*` and `~` bind tighter than a `?`/`!` suffix, while the borrow sigils bind looser (`*User?` is an optional handle, `?User?` a borrow of an optional); slice, array, and function types take no suffix without parentheses.
30. `??` binds tighter than comparison, but `catch` binds loosest, so `g() ?? 1 == 1` is `true` while `f() catch 1 == 1` is a type error (`t11`, `t12`).
31. `catch |e|` uses closure bars, but a `return` in its handler leaves the *function*, while a `return` in a closure leaves the closure.

**Not-yet restrictions a learner will hit (24):** arrays of owning values;
`Vec` of owning structs or of `Vec` (`p11`, `p12`); `v[i]`, `?v[i]`, and even
`v[i].n` on a Vec of handles or boxes (`r07`, `r08`, `s03`, although ROADMAP lists
`?v[i]` and `!v[i]` as "settled"); no clone of a Vec (`u05`); `drop` on enums
and generic structs (`s12`, `s13`); owned closures take only Copy parameters
(`s15`); no method or field on `T` in a generic body (`s01`, `s02`, although
ROADMAP lists this as settled too); compile-time value parameters of types are
integers only; no arithmetic on a compile-time parameter (`[n + 1]T`); no
closure return annotation (`p03`), defaults (`p18`), or keyword arguments
(`p17`); no fallible closure without a typed context (`q11`); no `match` on an
optional (`p13`) or a string; no payload binding by name in patterns; no
generic aliases; no struct, function, or associated constants; `raw` is a
function's last value but not a binding's value (`p06`); `if` and `match` are
not arguments (`q04`, `q05`); no labeled loop as a value; no `if f() as x` for
fallible calls (`q12`); no optional chaining without an optional-returning
function (`q13`); no error payloads; flat modules with no `use a as b`
(`p07`), no `pub use` (`u02`), and no subdirectories.

---

## 2. Inconsistencies and asymmetries

### 2.1 Forms that work in one position but not another

**Reads: the biggest asymmetry.** Here is where a read borrow of an owning
value `r` must be written and where it is implicit:

| Position | Bare `r` | Needs `?r` |
|---|---|---|
| method receiver `r.m()` | reads | (optional) |
| `match r` | reads in place | (optional) |
| `print(r)` | reads | |
| field read `r.f` | reads | |
| argument to a `?R` parameter | **rejected** | `f(?r)` |
| `for x in r` (Vec) | **rejected** | `for x in ?r` |
| `if r as x` (owning optional) | **rejected** (alias error) | `if ?r as x` |
| held `?R` forwarded | reads | |

DESIGN's reason for the argument rule is that the call site should show whether
a value is lent or handed over. But a bare owning `r` can *never* mean anything
else in any of these positions: a move needs `<r`, a clone `+r`, and a bare
owning copy is always an error. So the table is not about safety or
ambiguity. It is a style choice applied in some positions and not others. The
user's decision 13 ("lending always shows its sigil") was later narrowed to
write borrows, which is exactly what the language now enforces uniformly. Reads
never got a single rule.

**Write-borrow assignment.** Local vs field vs read borrow, as in carve-out 11:

```text
w = !m        # local !T: rejected, write `new w = !m`
h.w = !m      # field !T: re-points
r = ?m        # local ?T: re-points
w = <m        # local !T, m: !Int: writes the value m reaches (v03)
```

**Statement vs expression.**
- `if` and `match` are values only as a binding's value, a `return`, or a last
  line, never inside parentheses (`q04`, `q05`). Closures, by contrast, got
  special layout rules so that an indented body works inside `( )`. The same
  layout could carry `if` and `match`.
- `raw` yields a value as a function's tail but not as `y: U8 = raw` (`p06`).
- `-x` is covered in carve-out 13.
- `as` works only in an `if` or `while` condition, never in a ternary or a guard
  (`q14`). That is principled (there is no block to see the name), but it means
  there are two conditional syntaxes with different powers.

**Local vs field vs module.**
- Defaults: field defaults accept `Vec()`, parameter defaults do not (`p10`).
- Constants: a local `=!` may hold any value; a module constant only literals,
  operators, and arrays (`u03`, `p15`).
- Write-borrow re-pointing: covered above.

**`fun` vs `sub` vs closure vs method.**

| Feature | `fun`/`sub` | method | closure |
|---|---|---|---|
| result annotation | `-> R` | `-> R` | **none** (`p03`) |
| default parameters | yes | yes | **no** (`p18`) |
| keyword arguments | yes | yes | **no** (`p17`) |
| may fail | `-> T!` / `sub()!` | same | **only from a typed context** (`q11`) |
| compile-time parameters | yes | yes | no (by design) |
| is a value | yes (non-generic) | `Type.m` yes, `v.m` no | yes |

The closure column is the gap. A closure cannot say what it returns, and so
cannot say it fails, unless it is written where a typed context gives it a type.

**Generic vs plain.** A generic function is not a value; neither is a method of
a generic type (`t10`). A plain function and a plain `Type.method` are. This is
defended in DESIGN (no hidden wrappers), and it is a real Zig limitation, but
it is one more split.

### 2.2 Keywords and symbols doing double duty

| Symbol or word | Jobs |
|---|---|
| `!` | write borrow (`!x`, `!T`, `!self`, `\|!x\|`, `for x in !v`, `match !e`); failure (`T!`, `e!`, `sub f()!`, `sub(A)!`); fixed binding (`=!`); inequality (`!=`). **4 families, 11 positions.** |
| `?` | read borrow (`?x`, `?T`, `?self`, `?fun`); optional type (`T?`); propagate `none` (`e?`); `??`. 3 families. |
| `:` | type annotation; keyword argument; label definition (`:outer for`); label reference (`break :outer`); `while` step (`while c : i += 1`). **5 roles**, one of which needs its own token (`STEP_COLON`) and blocks labels inside `while` headers. |
| `\|` | bitwise or; closure bar list; `catch \|err\|`. The last two look alike but differ on what `return` leaves (carve-out 31). |
| `-` | subtract; negate; drop. |
| `<` | less-than; move; `<<`; `<self`. |
| `~` | weak handle only, which leaves Rig with **no bitwise NOT**. |
| `if` | block `if`; postfix guard; ternary; match-arm guard. Three lexer tokens (`IF`, `POST_IF`, `TERNARY_IF`), told apart by looking ahead for an `else` on the logical line. |
| `else` | `if` else; loop `else` (Python's "no break" semantics, which many find surprising); ternary else. |
| `new` | shadowing; re-pointing a write-borrow local. Contextual keyword (only at statement start). |
| `drop` | declares a destructor, `drop(!self)`; is *not* the drop statement (that is `-x`). |
| `as` | optional binding only. Newcomers try `x as U8` (a cast); the hint exists. |
| `catch` | a value-level fallback and a block-level handler (three grammar alternatives). |

### 2.3 Rules with carve-outs (counted)

The 31 carve-outs above group as follows:

| Area | Count |
|---|---|
| read/write/move visibility (1-13) | 13 |
| containers and slices (14-18) | 5 |
| bindings (19-23) | 5 |
| functions and closures (24-28) | 5 |
| types and precedence (29-31) | 3 |

About half of them (1-5, 8-11, 13, 19-21) trace back to three roots: no single
rule for implicit reads, the receiver-sigil precedence exception, and the
overloading of `!` and `=`.

---

## 3. Grammar and syntax cleanliness

### Size

| Measure | Value |
|---|---|
| `rig.grammar` | 852 lines; about 82 nonterminals and 255 alternatives in the parser section |
| tokens | 114, of which 10 are classified by the lexer rewriter (`POST_IF`, `TERNARY_IF`, `BAR_CAPTURE`, `BAR_EMPTY`, `KWARG_NAME`, `DROP_STMT`, `OF`, `DOTDOT_OPEN`, `NULLISH_JUMP`, `STEP_COLON`) |
| LALR states | 637; 0 conflicts (a real achievement) |
| `src/rig.zig` (layout, classification, IR rewrites, hints) | 2152 lines, about 98 functions |
| reserved words | 41 (11 declaration, 12 control, 7 expression, `raw`, 2 reserved forms, 8 held for later), plus contextual `new`, `of`, `none`, and 5 reserved type names |
| SYNTAX.md grammar summary | about 75 lines |

That is a **medium** surface, not a small one: roughly Go-sized in productions,
and larger than Lua or early Python. The 75-line summary reads well, but it
hides four things: the 10 context tokens, the receiver-sigil tree rewrite, the
capture/parameter split of bar lists, and the `for`-source sigil moved into a
mode slot. In all four, the tree the compiler sees is not the tree the grammar
builds.

### What is clean

- One `block` shape for everything, with indentation mapped straight to
  `(block ...)`.
- The IR schema in the grammar, read by role and never by position.
- No juxtaposition. Brackets are compile time and parentheses are run time.
  Suffixes are absence and failure; prefixes are ownership.
- Zero conflicts, with every lexer decision documented in INTERNALS.

### What is ugly

1. **A second expression language for compile-time integers.** `dim`, `targ`,
   `cexp`, `cadd`, `cmul`, and `cunit` (about 40 lines) re-implement `+ - * / %`
   and parentheses for array lengths and type arguments. Meanwhile, in
   *expression* position, type arguments go the other way, through
   expressions read as types, which cannot spell `[]T`, `[N]T`, `fun(...)`, or
   `*(T?)` (`z01`). So compile-time arguments have two grammars depending on
   position, and neither is complete.
2. **`if` as three tokens**, decided by a look-ahead for `else` on the logical
   line.
3. **The `tail` / `cclosure` / `clambda` path** exists only so that a closure
   whose body is an assignment (`|!t, n| t += n`) can be a last argument; `args`
   special-cases it.
4. **`catch` appears in three alternatives**, and `jump` duplicates the
   statement forms of `return`, `break`, and `continue` with `value` instead of
   `tail`.
5. **Binding forms are written twice**, in `simple` and in `const`, and the
   module-level `=!` alternatives exist only to be rejected.
6. **Three tiers of type precedence** (`ptype`, `tsuffix`, `thandle`) encode
   "handles bind tighter than suffixes, borrows looser, function and slice
   types take none". That is correct, but it is three rules to learn for one
   idea.
7. **`field` covers parameters, struct fields, and variants**, so `?self`,
   `!self`, and `<self` parse in a struct's field list and are rejected later.
8. **`:` in five roles**, plus a dedicated `STEP_COLON` token for
   `while c : step`, a syntax no other language has.
9. **The receiver-sigil rewrite**: the grammar builds `!(v.push(x))`, and
   `rig.zig` rebuilds it as `(!v).push(x)`. It is honest (documented) but
   it is tree surgery.

---

## 4. Completeness gaps that would embarrass a standard library

These are ordered by how early a library author hits them.

### Generics

- **A generic body cannot call a method on `T` or read its field** (`s01`,
  `s02`: "generic bodies can only move, copy, and compare `T` values").
  `HashMap[K, V]` cannot call `k.hash()`, `sort` cannot call `a.less(b)`, and a
  formatter cannot call `x.fmt()`. ROADMAP lists "a generic method call on a `T`
  is checked at each use" as *settled*, but it is not built. **This is the
  single largest blocker.** The fallback (function-pointer fields) works but
  makes every container API clumsy.
- No hashing builtin (`hash(x)`, `s05`) for types that have `==`.
- No generic aliases (`type Map[V] = HashMap[String, V]`).
- A compile-time value parameter of a type is an integer only; there is no
  `[n + 1]T`.

### Containers and ownership

- **A Vec cannot hold an owning struct or a Vec** (`p11`, `p12`); you need
  `Box` or `*T`.
- **Elements of a Vec of handles or boxes cannot be indexed, borrowed, or even
  have a field read** (`v[0].n`, `?v[0]`, `+v[0]`, probes `r07`, `r08`, `s03`).
  Only a `for` loop reaches them. A hash table with owning values cannot look
  up a bucket. ROADMAP says `?v[i]` and `!v[i]` are settled; they are not built.
- No Vec clone (`u05`), and no `insert`, `remove`, `truncate`, `reserve`,
  `extend`, or `sort`.
- Arrays cannot hold owning values.
- No `drop` body on enums or generic structs, so a generic container that needs
  custom cleanup cannot have one.
- Owned closures take only Copy parameters (`s15`), so a callback cannot receive
  an owning event.

### Strings and text

- `Text` does not exist, and there is no concatenation (`p14`), no formatting to
  a string, no `split` or `find`, no char literal (`"a"[0]` is the workaround,
  `s06`), and no `String(bytes)` (`z02`). `print` always ends the line (`z03`),
  there is no stderr, a `[]U8` cannot be printed, and `sub main` cannot take
  arguments (`s08`).
- The borrow model for a `String` taken from a `Text` is undecided (see §1).
- No string patterns in `match`.

### Iteration

- `for` works on ranges, arrays, slices, Strings, and Vecs only. By a user
  decision it never calls user code, so user collections use
  `while !it.next() as x` (which works, `t03`). This is defensible (no hidden
  calls), but it creates a two-class system: built-in collections get `for`
  with its sigil modes and `else`, while user collections get a `while` loop
  with neither. There is no lending iterator over owning elements and no
  adapter story. A Cell[Vec] cannot be walked (`y04`).
- Ranges have no step, no reverse, and no inclusive form (`5..0` is silently
  empty, `u08`).

### Error handling

- **No payloads** (`s11`): an I/O error cannot carry a path or an errno.
- **Error identity is by name across sets**: `A.timeout == B.timeout` holds
  (`y05`). That is Zig's global error set, and it becomes a real problem once
  `io`, `json`, and user code each define `invalid`.
- Functions do not declare their error sets, so no `catch` over an error can be
  exhaustive without `_` (`y06`).
- There is no `try` block (reserved), and no `if f() as x` for a fallible call
  (`q12`).

### Modules

- **Flat, one directory only**: no `std/io.rig` or `use std.io`, no
  `use a as b` (`p07`), no `pub use` re-export (`u02`), and no selective import.
  A standard library needs hierarchy and re-exports on day one.
- **FFI carries only integers, floats, and Bool.** A `[]U8` cannot cross to C,
  so file I/O cannot be written in Rig even inside `raw`. The ROADMAP decision
  (pointer plus length, explicit NUL copy) is settled but not built. **This
  blocks I/O as surely as the generics gap blocks collections.**

### Numbers

- **No bitwise NOT** (`u13`, `y01`), no rotate, no `<<%`, no checked or
  saturating operations, no `USize`, and no math functions.

---

## 5. Ranked recommendations before the standard-library phase

Each item is marked **add**, **unify**, or **remove**, with a rough cost
(S = a day or two, M = about a week, L = more) and whether it needs a user
decision. The ranking puts first what would otherwise be baked into library
APIs and be expensive to change later.

| # | Kind | Change | Cost | Why now |
|---|---|---|---|---|
| 1 | **add** | **Methods and fields on `T` in generic bodies**, checked per instance, as the existing requirement records already do for `+` and `==`. Name the protocol conventions at the same time (`eq`, `hash`, `less`, `next`, `fmt`) so every container uses the same ones. Zig duck-types, so emitting it is cheap; the work is in typecheck requirement records and cross-module export. | M | Every collection and algorithm depends on it, and the design is already "settled" in ROADMAP. Without it, the library is built on function-pointer fields and would need rewriting. |
| 2 | **unify** (decide) | **The `String` / `Text` / `[]U8` model.** Decide whether `String` stays Copy (then a `String` from a `Text` must copy or be restricted) or becomes a borrow-tracked view like `[]T` (then literals are "static" views). Add a byte or char literal and `String`/`[]U8` conversions. | M-L | Every library signature that takes text depends on it. Changing it after the library exists means touching all of them. |
| 3 | **add** | **Element access for owning Vecs**: `?v[i]`, `!v[i]`, `v[i].f` reads through handle and box elements, and `Vec[OwningStruct]` and `Vec[Vec[T]]` (the runtime already drops elements). Also a Vec clone for Copy elements, plus `insert`, `remove`, and `truncate`. | M | Hash tables, trees in arrays, and any container of containers need it. Also "settled" in ROADMAP. |
| 4 | **add** | **FFI buffers and hierarchical modules**: `[]U8`/`![]U8` across `extern` as pointer plus length (settled), `use std.io` over subdirectories, `use a as b`, and `pub use` re-exports. | M | Without buffers there is no I/O; without paths there is no `std.` layout. |
| 5 | **unify** (decide) | **One rule for implicit reads.** Recommended: *"where a `?T` is expected, a bare place is lent for reading; `?` is always allowed; only writes (`!`) and moves (`<`) must be written."* A bare owning value is always an error today, so no accepted program changes meaning; only rejections become acceptances. It removes carve-outs 1-3 and most of 5, and the most common error new users hit (`f(x)` → "lend a read borrow: `?x`", reported at 595 sites in the readability review). The alternative that keeps DESIGN's pillar literally is the opposite: require `?` on `match` subjects and receivers too. Either is consistent; the current mix is not. | S (typecheck) | This touches every library signature and example; settle it before writing thousands of `?` in the library. |
| 6 | **unify** | **One meaning for `=` on a borrow place.** Recommended: make locals behave like fields. Assigning a `T` to a `!T` place writes through; assigning a `!T` re-points it (`w = !m` becomes legal and means re-point). `new` goes back to one job, shadowing. | S | It removes carve-outs 11 and 12's local/field split, and `new`'s double duty. |
| 7 | **remove** (re-open a user decision) | **Remove `=!`.** The emitter already chooses const or var from what the checker knows; "never reassigned" could be a lint instead of a form. It frees `!` from its fourth meaning and deletes the `x =!y` trap, the module-level rejection, and the `new x =! e` gap. **If the user wants to keep fixed bindings**, then at least *complete* the form: allow `new x: T = e` and `new x =! e`. | S (either way) | Carve-outs 19-21 disappear. |
| 8 | **add** | **Bitwise NOT.** Options: `~x` on integers (it cannot collide with `~` on a `*T`, so the type decides unambiguously, as C, Zig, and Rust readers expect), or a word or method. Add `<<%` and rotate alongside. | S | Hashing and bit manipulation are standard-library basics, and today they need `x ^ T.max`. |
| 9 | **unify** | **Closures reach parity with functions**: an optional result annotation `\|x: Int\| -> Int`, which also lets a closure be fallible without a typed context. Consider defaults and keyword arguments too. | S (grammar) + S (typecheck) | Callbacks are the substrate for the reactive library; the parity table in §2 has three holes. |
| 10 | **unify** | **Put `catch` at the precedence of `??`** (both are fallbacks), so `f() catch 1 == 1` reads like `g() ?? 1 == 1`. | S (grammar + migration) | Carve-out 30. |
| 11 | **add** (decide) | **The error model**: at least reserve and decide typed errors or payloads (`T!E`, or error payload variants) and whether identity stays by name. | L to build; S to decide | I/O and parsing errors need context; the decision shapes every fallible library signature. |
| 12 | **add** | **Constants**: struct constants, function values as module constants (an open question in ROADMAP), and associated constants (`P.ZERO`). | S-M | Tables and defaults in library code. |
| 13 | **add** | **`match` on an optional** (`none =>`, `x =>`) and on Strings. | S-M | Parsers and lookups. |
| 14 | **unify** | **Close the small position gaps**: `raw` as a binding's value, `if` and `match` inside parentheses (the closure layout rule already exists), `x = :l for ...`. | S each | Carve-outs that exist only because the grammar has not caught up. |
| 15 | **unify** | **Compile-time arguments in expressions**: let an expression-position type argument accept every type form (`Wrap[[3]Int](...)`, `Vec[[]Int]()`), possibly by folding `cexp` and the type-as-expression reading into one rule. | M (grammar work; must stay conflict-free) | Removes the "name it with an alias" workaround and one of the two compile-time mini-grammars. |
| 16 | **remove** (optional; re-opens a user decision) | **The position-dependent `-x`.** Either `drop x` as the statement (the keyword already exists), or keep `-x` and document the `fun`/`sub` last-line rule prominently. | S | Carve-out 13; DESIGN's first law. |
| 17 | **unify** | **The small leaks**: apply the touch rule to `.` and `@`; lint `for i, x` when the first name looks like an index and both types match; `@sizeOf[T]`-style brackets for type builtins, or document the exception. | S | Polish. |

**The minimum set before the standard library: 1, 2, 3, 4, and a decision on
5.** Items 6-8 are cheap and remove more carve-outs per line changed than
anything else on the list. Items 11 and 16 re-open decisions and should go to
the user as questions, not changes.

---

## Appendix: probe index

All probes are in `scratchpad/purity/designer/`. Each was run with
`bin/rig run`, and the first lines of output were compared to the claim.

- `p01`-`p20`: binding forms, closure annotations, aliases, `raw`, `use as`, defaults, containers, `match` on optionals, constants, builtins.
- `q01`-`q15`: `-x` position, block expressions as arguments, receivers, `?` in `sub`, `!` in closures, fallible `as`, optional chaining.
- `r01`-`r13`: implicit and explicit reads, array copies, slices, Vec element access, Cell, write-borrow exclusivity, the Bool short form.
- `s01`-`s15`: generic method and field access, Vec of boxes, hashing, char, `Text`, `main` arguments, error payloads, `drop` on enums and generics, owning arrays, owned-closure parameters.
- `t01`-`t12`: generic clone and filter, iterator convention, labels, `-> Void`, nested optionals, generic method values, `catch` vs `??` precedence.
- `u01`-`u14`: `sub main()!`, `pub use`, struct constants, enum values, Vec clone, associated constants, int-to-enum, ranges, labeled `match`, bitwise not, float `%`.
- `v01`-`v06`: re-pointing borrows (local, field, parameter, read), forwarding held borrows.
- `x01`-`x05`: implicit reads in `if as`, `match`, `for`, `print`, and arguments.
- `y01`-`y07`, `z01`-`z03`: `not` on integers, `. red`, the `for i, x` silent case, Cell[Vec] iteration, error identity, `catch` exhaustiveness, expression type arguments, bytes to String, `print` keywords.
