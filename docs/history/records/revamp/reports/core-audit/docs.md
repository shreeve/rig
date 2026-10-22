# Core audit: documents against the Core

Auditor's area: the written language (SPEC, SYNTAX, WELCOME, README, FAQ,
DESIGN, STD, INTERNALS, ROADMAP, AGENTS) on `main` at `dd36c78`, and the
doc changes on `rig-text` (`59e7bed8`).

Probes are in `probes/docs/`. `results-main.txt` and `results-rig-text.txt`
hold their output. `main` was checked with `bin/rig`, built after `dd36c78`.
The `rig-text` binary is from 00:31 on Sep 30, six minutes older than that
branch's last commit.

**One caveat about the branch diff.** `rig-text` forked at `8a82fabe`, before
PR #31 merged. So `git diff origin/main -- SPEC.md ...` appears to delete
several things that exist only on main:

- SPEC §4's paragraph and example on assignment order;
- the §7 rule about indexes inside a borrowed place;
- the §6 rule that a `for` over a Vec needs a place or a call;
- every mention of `RIG_SANITIZE`;
- INTERNALS' bullet on emitting assignments.

These are not intended deletions. The merge must keep main's text. The
diff against the merge-base shows only additions in these areas.

---

## 1. Contradictions

**How to read the table.** "Core" names the sentence (s1–s10) or section
(§1–§9) of CORE.md. "Today" means the doc correctly describes current
behaviour but contradicts the Core's stated intent. "False" means the
sentence is wrong even today (see §4). Replacement wording assumes the
Core's leans on the open decisions.

### SPEC.md (main)

| file:line | says | Core says | replacement |
|---|---|---|---|
| SPEC:98 | `String`: "immutable UTF-8 bytes; a Copy value" | §1: String is a **view** | "a read view of text: bytes it does not own. It copies, carrying any loan it holds." (Also fix the branch's SPEC:97, which keeps "a Copy value".) |
| SPEC:252-253 | "Arrays hold plain data only … a collection of resources is a `Vec`" (also **false**: probe p03) | §5: arrays hold anything | "An array holds values of any type. `[n of x]` copies `x` into every slot, so `x` must be one that copies: plain data or a read view." |
| SPEC:349-352 | "Of a String it is a String. Of an array or a `Vec` of plain data it is written `?xs[a..b]`" | s1, §4: "A slice `x[a..b]` is the same lend" | "`xs[a..b]` reads part of `xs`, as `xs` reads it. `?xs[a..b]` lends that part as a `[]T`, and `!xs[a..b]` as a `![]T`, for any element type." |
| SPEC:400-410 | An array goes where a slice is expected "in three ways". A bare named array is rejected. A temporary array is accepted only by "a call that keeps no borrow"; "anywhere else … rejected" | s1, §3, §4 | "Where a `[]T` is expected, `?a` lends all of an array or Vec (the lend table), and a bare `a` lends it to read. A temporary array is lent as any temporary is, until its statement ends." |
| SPEC:456-460 | `!xs[a..b]` is taken "of an array or a `Vec` of plain data" | §5 | "`!xs[a..b]` lends part of anything `!xs` can lend." |
| SPEC:468-470 | "a bare `s[a..b]`, which would borrow `s` unseen, is rejected" | s1 | "`s[a..b]` reads that part of `s`." |
| SPEC:474-476 | "A slice's elements are plain data: `[]T` and `![]T` with a `T` that owns a resource are rejected" | §5 | Delete. "A slice views elements of any type. Reading an element reads it in place (§5)." |
| SPEC:525-528 | `copy`/`fill` need plain elements; "`swap` also moves the handles of a `Vec` of them" | §5: swap works for any element type | "`copy` and `fill` copy values in, so their elements must copy (s1). `swap` exchanges elements of any type." |
| SPEC:681-690 | Two kinds: Copy and owning. Owning includes "a `*T` or `~T` handle" and "an owned closure". `Cell`s of Copy values are Copy | §1: four kinds. Handles are their own kind. A struct with a Cell is not plain (decision 2) | Replace with Core §1's table. Add one line per kind for what a bare use, `<`, and `+` do. |
| SPEC:820-827 | The long form `(!set).insert(k)` is required only where a `!` would start a condition or an `and`/`or`/`not` operand. "Elsewhere … the short form is accepted" | decision 6 (lean yes) | "A write-borrowing call whose value is a `Bool` is always written in the long form, `(!set).insert(k)`." |
| SPEC:1592-1604, 1619-1620, 1677 | `x =! e` fixed bindings, and the module-level `=!` rejection | decision 5 (lean: replace with a word) | Rewrite with the chosen word, e.g. `fix x = e`. Note that SPEC:4888-4891 lets a `=!` binding be a compile-time argument (probe p36), so dropping fixed bindings would remove that feature too. |
| SPEC:2101-2105 | "A `Vec` is walked in place, so the loop borrows it and says so: `for x in ?v`; a bare `for x in v` … is rejected" (p05) | s1 | "`for x in v` reads each element in place, as `for x in ?v` does. `for x in !v` lends each to write, and `for x in <v` takes each." |
| SPEC:2181-2195 | A `for` over a Vec expression that is neither a place nor a call is rejected (`?(a if c else b)`) | §3: reading never moves | "A `for` source is read in place, whatever form it has. A call's result is taken by the loop (§3)." |
| SPEC:2494-2498 | "The move is written `<x`; only a bare name returned directly … moves without it" (p02) | s1: "It never moves" | Either "Every move is written, `return <x` included", or keep the exception and write it into s1 (see Core edit C1). |
| SPEC:2883-2888 | "`new w = !m` (`w = !m` is rejected, since it would write through `w`)", while a field `h.w = !m` re-points | §6, decision 4 | "Assigning a borrow to a place that holds one re-points it, for a local and a field alike (`w = !m`). Assigning a value writes through it (`w = 5`)." |
| SPEC:3085-3091 | "a borrow of a number, `Bool`, `String`, or plain enum reads as the value … Other values … are not copied out of a borrow" (p08: `fun f(p: ?P) -> P` is rejected for a plain struct) | s1: a bare name "copies plain data" | "Reading a borrow of plain data, a struct of plain fields included, copies the value. An owner or handle is read in place and never copied out." |
| SPEC:3110-3112 | "`+x` … for a Copy value it copies. A struct with drop glue has no clone." | s2: `+x` is "a copy, a count bump, or a deep copy, as the type says" | "`+x` makes a new owner as its type says: a copy of plain data, a count bump of a handle, or a deep copy of a Vec, Box, or Text, or of a struct of them." Whether a type with a `drop` body gets `+` is not covered (Core edit C9). |
| SPEC:3160-3165 | A temporary owner may be bound, returned, passed, … "Anywhere else (a field read, a borrow, **a method receiver, a `print` argument**, …) … must be bound to a name first" | §3: a print argument, a receiver, and a field read are reading positions | Replace with Core §3. |
| SPEC:3179-3184 | A borrow of a temporary lives "only as long as the call it is lent to", in a fixed list of positions | §3: "may be used only within its statement" | Replace with Core §3's second paragraph. |
| SPEC:3273-3274 | "for a named owning value, write the move: `*<x`" (p10) | s8: "`*x` moves `x`". **The Core is wrong here, not SPEC** | Keep SPEC, and fix s8 (Core edit C2). |
| SPEC:3304 | "Handles are owning values" | §1: handle is a kind of its own | "Handles are their own kind. A bare name reads one; taking it is `<h` (move) or `+h` (another count)." |
| SPEC:3465-3468 | Vec elements are only "Copy primitives, … plain data …, shared handles …, weak handles, or boxes" (p04: `Vec[Vec[Int]]` and `Vec[Row]` are rejected) | §5 | "Elements are of any type." |
| SPEC:3475-3476 | `v[i]` and `v.get(i)` work only for a Copy `T` (p12, p29) | §5: "`v[i]` reads it" | "`v[i]` reads an element in place, and `?v[i]` / `!v[i]` lend it. `v.get(i)` is a `T?`: a copy of plain data, a read view otherwise." |
| SPEC:3482-3486 | An owning element "is a borrowed slot, where `v` must be a binding or a field of one" | s1, §5 | "`for x in v` reads each element in place, whatever `v` is." |
| SPEC:3560-3561 | "A box … is never copied or cloned" | s2 (`+` on Box is decided) | "`+b` makes a new box holding `+` of its value." |
| SPEC:3576-3579 | "A box of anything other than a struct or enum … reaches no members through it" (p07). "A Vec holds boxes as it holds handles" | §4: a `Box[T]` lends "the views of `T`" | "A box reaches whatever its value reaches: `b.len` of a `Box[Vec[T]]`, `?b` as any read view of `T`." |
| SPEC:3646-3647 | `Signal[T]` holds only "a Copy or plain-data value" | s9: shared storage accepts any value that carries no loan | "A Signal holds any value that carries no loan, as a Cell does." |
| SPEC:3921-3926 | A borrowed callable is never "a field's, an element's, a module-level binding's, or a type argument" | §5 (containers hold views), s6 | "A borrowed callable is a read view. It goes where a view goes and carries its loans (s6)." (Needs a Core ruling: Core edit C10.) |
| SPEC:4074-4078 | "An optional held in a binding is bound by moving or cloning it: `if <m as x`, `if +m as x`" (p06) | s1 | "`if m as x` reads the value in place, so `x` is a read view of it. `if <m as x` takes the value, and `if !m as x` lends it to write." |
| SPEC:4206-4210 | `??` with an owning optional only "when it is a temporary … or moved … but not when it is reached through a borrow" (p20) | §3: `print(o ?? d)` moves nothing | "`o ?? d` reads `o`. Where the value is only read, nothing moves. Where it is taken, write `<o ?? d`." |
| SPEC:4376-4381 | A function fails by producing an error value: `return E.name`, "a binding of an error set's type, or an error it caught … including when the error is the final value of an `if` or `match` branch block" (p11 runs) | s10 and decision 3: "Failing is always written: `return E.name`" | "A fallible function fails only with `return`: `return E.name`, or `return err` for an error it caught. A bare error value on a last line is rejected, with the hint `return E.bad`." |

### SYNTAX.md

| file:line | says | Core says | replacement |
|---|---|---|---|
| SYNTAX:294-296 | "`=!` is one token, so `x =!y` could be a fixed binding … a `=!` touching the operand after it is rejected" | decision 5 | Delete once `=!` is replaced. |
| SYNTAX:320-329 | The long form "is required where a write-borrowing call returning `Bool` would start a condition" | decision 6 | "… is required wherever such a call's `Bool` is used." |
| SYNTAX:724, 731-733 | `x =! e` "reads as 'set, dammit!'" | decision 5 | Use the chosen word. |
| SYNTAX:901-908 | `for x in xs` gives "a copy … of an array, slice, or String", `for x in ?v` the elements of a Vec, and "A Vec is always walked with a sigil" | s1 | "`for x in xs` reads each element of any source: a copy of plain data, a read view otherwise. `?`, `!`, and `<` on the source lend or take." |
| SYNTAX:1180-1183 | `s[a..b]` is only for a String. `?xs[a..b]` is "a read … slice of an array or Vec". `?a` where a `[]T` is expected is `?a[..]` | s1, §4 | "`xs[a..b]` reads part of any sequence, and `?xs[a..b]` / `!xs[a..b]` lend it. `?x` lends whatever view the context expects (SPEC's lend table)." |
| SYNTAX:1307-1308 | "`*x` moves a value into a new shared handle (`*<x` for a named owning value …)" | s8 says `*x` moves `x` | SYNTAX is right. Fix the Core (C2). |
| SYNTAX:1322 | A `+x` capture is "a copy of a Copy value, or a clone of a handle" | s2 | "a new owner, as `+x` makes one" |

### WELCOME.md

| file:line | says | Core says | replacement |
|---|---|---|---|
| WELCOME:115-117 | "a write is always spelled out … so every mutation is visible" | s9: one exception, `Cell` | "… so every mutation is marked, except inside a `Cell`, which changes through any path ([SPEC §10](SPEC.md#cell))." |
| WELCOME:201-202 | "`*Cell[Int]` is a shared cell, the one way to share state that changes" | s9 lists Cell and Signal | "the way to share state that changes (a `Signal` adds subscribers)" |
| WELCOME:218-220 and 521-522 | "a bare name never moves an owning value" (**false today**: p02, `return r`) | s1 (decided) | Correct once s1 is built. Until then: "a bare name moves only in `return x` (or a last line `x`)". |
| WELCOME:227, 393 | `x =! 1`, and the `let` hint "or `x =! 5` for a fixed binding" | decision 5 | Use the chosen word. |
| WELCOME:474-476 | "Every place where the habit would change a program's meaning is an error" (**false**: p32, `dup = !s.insert(1)` runs) | decision 6 | True once decision 6 lands. Until then: "… where it starts a condition or an operand of `and`/`or`/`not`". |
| WELCOME:620-621 | "heap strings and string building: `String` is an immutable view" | §1 lists `Text` | The branch already rewrites it. Keep the branch's wording. |

### DESIGN.md

| file:line | says | Core says | replacement |
|---|---|---|---|
| DESIGN:50-53 | Moves, …, mutation "each have a marker" | s9: Cell is the one exception | "… mutation (except inside a `Cell`, the one interior-mutable type, which is why it accepts only values that carry no loan)" |
| DESIGN:54-58 | Implicit: "copying plain data, reading through a shared handle, lending a receiver to a `?self` method, and moving a local out with `return x`" | s1: a bare name only reads, never moves | "What stays implicit is reading: copying plain data, and lending to read wherever a value is only read (a `?T` parameter, a receiver, a `for` source, an `as` binding). Every move is written." |
| DESIGN:108 | `+x`: "a new owner (`T` is Copy or a handle)" | s2 | "a new owner: a copy, a count bump, or a deep copy, as `T` says" |
| DESIGN:197-198, 304 | "`x =! e` is the one place `!` appears in an operator that is not about borrowing or failure" | decision 5 removes `!`'s fourth meaning | Delete, or describe the word that replaces it. |
| DESIGN:249-251 | "a reader sees whether a value is lent or handed over without looking up the callee" | s1 makes read lends unwritten | "A reader sees whether a value is changed or handed over without looking up the callee. A bare name is only ever read." |
| DESIGN:282 | `sort(!v[..], \|a, b\| a < b)` (**false**: no such function, p35) | §4: `sort.sort(!v)` works for a Vec | `sort.sort_by(!v, \|a, b\| a < b)` |
| DESIGN:329-330 | "A habit can make a program fail to compile, never change what it means" (**false**, p32) | decision 6 | True once decision 6 lands. |

### STD.md, FAQ.md, ROADMAP.md

| file:line | says | Core says | replacement |
|---|---|---|---|
| STD:193-195 | "An `Rng` moves (`a = <r`) and is never copied". This is done with an empty `drop` body (std/random.rig:8-12, p09) | §1: a move-only plain type "declares that on the type … It does not fake a `drop` body" | "`Rng` is declared `unique`: it moves, and `fork` makes a second one on purpose." |
| STD:233-235 | Sorting works "on Vecs (`!v[..]`, `?v[..]`) alike. The elements are plain data, as a slice's are." (p13) | §4, §5 | "… on arrays and Vecs alike (`!v`, `?v`), for any element type that `<` orders" |
| STD:268 | `sort.sort_by(!v[..], …)` | §4 | `sort.sort_by(!v, …)` |
| STD:320-321 | "on arrays and on Vecs through a slice" | §4 | "on arrays and Vecs" |
| FAQ:9-10 | "Numbers, strings, structs, enums, and arrays are plain values" (a struct holding a Vec is not: p04) | §1 | "Numbers, Strings, and structs, enums, and arrays made of them are plain values. A struct holding a `Vec` owns it." |
| FAQ:98-99 | "`x =! e` binds for good" | decision 5 | Use the chosen word. |
| ROADMAP:31 | Zig-backed types take "the kinds `copy`, `owns`, and `view`" | §1 calls the kinds plain, owning, handle, view; decision 1 suggests `unique` | Use the Core's names: "the kinds of [Core §1]: plain, owning, view, and `unique`". |

### rig-text branch (SPEC and docs as of `59e7bed8`)

| file:line (rig-text) | says | Core says | replacement |
|---|---|---|---|
| SPEC:3112-3117 | A value that "reaches an owner a name holds (`o?` …, `a if c else b`) is no temporary: reading it where it stands would move that owner, so it is rejected" (p19 on rig-text) | §3: "Reading never moves a name … `print(a if c else b)` and `print(o ?? d)` move nothing" | "A value that reaches an owner a name holds is read in place, as the name is." |
| SPEC:3108-3110 | "A `match` over a temporary reads it, so an arm cannot move a payload out" | §3: "A call's result that … `match` … binds is taken, as `<e` would take it" | "`match make()` takes the result, so its arms own the payloads, as with `match <e`." |
| SPEC:3110-3112 | "Anywhere else (a method receiver, a field that owns a resource …) … must be bound" | §3: a receiver and "a field or element read" are reading positions | "A temporary read as a receiver or through a field lives until its statement ends." |
| SPEC:3160-3164 | "the temporaries of an `if` header, a `match` subject, and a `for` source live through the whole statement, so an `as` binding may hold such a borrow in the body" | §3: a condition and a subject "are statements of their own" | "A header is a statement of its own. A borrow of a header's temporary ends with the header. What the header binds is taken and lives through the body." Under the Core, the branch's own example at SPEC:3176 (`if text.cut(?Text("k=v"), "=") as kv`, then `kv` used in the body) becomes a rejection. Core edit C6 asks for that example to be ruled on explicitly. |
| SPEC:3764-3773 | A generic body storing a `T` in a Cell "cannot be instantiated with a `T` that holds a String, even when every String passed is a literal" | s9: "checked per value: decided" | "A Cell accepts a value that carries no loan, so a literal String may go in. A String parameter carries its caller's loan and may not." |
| SPEC:3776-3779 and 3782 | "`Vec[Text]` is rejected, and `Vec[Box[Text]]` holds Texts" (p27) | §5: "`Vec[Text]` … just work[s]" | "A Vec holds Texts as it holds any value: `Vec[Text]`." Delete the `Vec[Box[Text]]` example. |
| SPEC:690-692 | "A **Copy** value is plain data: numbers, `Bool`, `String`, …" | §1: String is a view | Use the four-kind table. |

---

## 2. Exception lists in SPEC

I counted every "X, except …" rule, every list of positions, and every list
of admitted types in SPEC.md on main. That is **123** of them. Line numbers
are from main.

Markers:

- **R**: removed by the Core. It disappears, or becomes a one-line
  consequence of the cited sentence or section.
- **S**: a syntax rule kept under §7. **S+** means §7's list does not name
  it yet.
- **N-own**: an ownership rule the Core does not cover. It must be added to
  the Core or cut.
- **N-type**: a type, syntax, or FFI rule outside ownership. The Core
  should declare these out of its scope.

The form column says what kind of rule it is:

- X: an except-rule;
- P: a position list;
- T: a type list;
- L: some other restriction.

**Totals: R 65 · S 22 (7 already in §7, 15 more to list) · N-own 20 · N-type 16.**

| # | SPEC lines | rule | form | mark |
|---|---|---|---|---|
| 1 | 248-253 | arrays hold plain data only; `[n of x]` copies | T | R §5 (the fill copies by s1) |
| 2 | 349-353 | a String slices bare; arrays and Vecs of plain data slice with `?` | T/X | R s1, §4 |
| 3 | 358-360 | only a slice leaves a side open | L | S+ |
| 4 | 394-398 | a borrowed array parameter can return a slice; one taken by value cannot | X | R s7 |
| 5 | 400-410 | "three ways" an array becomes a slice; bare rejected; temporary only to a call that keeps nothing; "anywhere else" rejected | P | R §4, §3, s1 |
| 6 | 456-460 | write-slice sources; String and `[]T` read-only; fixed, loop, and pattern bindings and parameters read-only | T/P | R §5 (+ N-own mutability) |
| 7 | 466-470 | `![]T` not copied; a call reborrows it; returned only from a `!` param; bare `s[a..b]` rejected | X | R s1, s7, §1 view row |
| 8 | 470-474 | `![]T` accepted where `[]T` is, lent to read | X | N-own (lend-table row for held write views) |
| 9 | 474-476 | slice elements are plain data | T | R §5 |
| 10 | 520-530 | `copy`/`fill` need plain; `swap` moves Vec handles | T | R §5 (+ s1 for copy) |
| 11 | 612-623 | `read`/`write` on a list of byte containers | T | R §4 |
| 12 | 676-677 | a handle never holds a borrow | L | R s9 |
| 13 | 681-690 | Copy vs owning lists | T | R §1 |
| 14 | 706-707 | parameters immutable, except `!T` | X | N-own (binding mutability) |
| 15 | 708-710, 746-751 | forms of a default value | T | S+ (constant forms) |
| 16 | 786-792 | write lends and moves never implicit; held read lent bare, held write with `!` | X | R s1, s4 |
| 17 | 814-821 | short-form receiver-sigil checks | L | S §7 (receiver rule) |
| 18 | 821-827 | Bool long form only in condition, `and`/`or`/`not` positions | P | S §7 (decision 6 deletes the list) |
| 19 | 965-970 | `c.bump` must be called; generic methods are not values | X | N-type |
| 20 | 1098-1101 | a generic type's Vec, Cell, and array element rules hold per instance | T | R §5 |
| 21 | 1387-1394 | a generic copy of `T` needs plain; taking an element of a non-consuming loop; unwrapping from a borrowed optional | P | R s1, s2 |
| 22 | 1394-1396 | a type argument cannot be a borrow or hold one | X | N-own |
| 23 | 1440-1445 | ever-deeper instances rejected | L | N-type |
| 24 | 1506-1513 | an alias is not a value; aliases of other types have no constructor | X | N-type |
| 25 | 1568-1572 | forms of a constant value | T | N-type |
| 26 | 1592-1604 | module-level `=!` rejected | L | S §7 (decision 5) |
| 27 | 1617-1621 | `x = e` declares or assigns; through a write borrow | X | R §6 |
| 28 | 1644-1649 | assignment order | L | R §6 |
| 29 | 1676-1678 | no implicit shadowing; `=!` always declares | L | S+ (§6 `new`) |
| 30 | 1706-1707 | parameters and loop, pattern, and `as` bindings are immutable | T | N-own (mutability) |
| 31 | 1709-1717 | every local read: what counts as a read; parameters exempt | P | S+ (lint) |
| 32 | 1738-1740 | no sigil on a call of a function-valued field | X | S §7 |
| 33 | 1744-1753 | literal typing through `+ - *` but not `/ %` | X | N-type |
| 34 | 1819-1838 | equatable types, and the list that has no `==` | T | N-own (derive `==` from kind) |
| 35 | 1840-1843 | ordering types | T | N-type |
| 36 | 1923-1926 | prefix `!` is never negation; valid only where `!Bool` is expected | X | S §7 |
| 37 | 1965-1967 | where `if`/`match` are expressions | P | S+ |
| 38 | 1995-2000 | `-x` drop vs negate positions; only a binding is dropped | P | S §7 (+ N-own "only a name") |
| 39 | 2015-2020 | a statement must have a use | P | S+ |
| 40 | 2054-2056 | safe builtins list | T | S+ |
| 41 | 2075-2078 | statements a guard may end | P | S+ |
| 42 | 2082-2091 | `while` step forms; jumps in the header | P | S+ |
| 43 | 2095-2105 | `for`: Vec needs a sigil; bare rejected; arrays copied; a call's Vec consumed | P/T | R s1, §3 |
| 44 | 2135-2142 | `for !xs` needs a binding or field; `for <v` needs an owner | X | R s2, s4 |
| 45 | 2181-2195 | a Vec source must be a place or a call | P | R §3 |
| 46 | 2200-2205 | labels only on loops, `match`, and `raw` | P | S §7 |
| 47 | 2224-2228 | a `break` value is taken like a return value | P | R §3 |
| 48 | 2232-2251 | match subject types; a guard moves nothing; alternatives bind none | T/X | S+ (patterns), R s1 (guard) |
| 49 | 2310-2320 | subject sigils; Bool with `!`; `match !e` needs a place; `<e` needs an owner; boxed enums through a borrow | X | R s1, s4, §4 (Bool: S) |
| 50 | 2384-2387 | where `pass` stands | P | S §7 |
| 51 | 2422-2431 | `errdefer` positions; a deferred body cannot move, drop, or propagate, and reads only earlier names; a one-line `defer` declares nothing | P/X | N-own (defer) |
| 52 | 2475-2478 | `<x` of a Copy value or borrow copies; `<p.f` of a Copy field leaves `p` whole | X | R s2 |
| 53 | 2494-2498 | move positions; a bare `return x` moves | P/X | R s1, §3 (Core must rule: C1) |
| 54 | 2566-2569 | moved in a loop "unless" it is left or reassigned | X | R s2, s3 |
| 55 | 2589-2593 | only whole bindings move | X | R §5 (needs fields: C7) |
| 56 | 2595-2607 | "the exception": take an optional field or element; writable path, owner, generic `T?` vs `T`; `<(a if c else b)` rejected | X | R §5 (+ N-own: `<`'s operand is a place) |
| 57 | 2649-2654 | `replace`/`swap` values hold no borrow | X | R §5 |
| 58 | 2672-2685 | `swap(!a[i], !a[j])` rejected; use the collection's `swap` | X | R s5 |
| 59 | 2718-2723 | aliasing rule, numbers included | L | R s5 |
| 60 | 2740-2750 | how long a borrow lives (list of later uses) | P | R s6 |
| 61 | 2799-2812 | argument order; storage-sharing types keep a read loan; plain copied; a write receiver's arguments may read it | T/X | R s1+s6 (+ N-own: two-phase receiver) |
| 62 | 2853-2858 | an index cannot write-borrow its place's root (assignment differs) | X | N-own (place evaluation order) |
| 63 | 2883-2888 | `new w = !m`; `w = !m` rejected; a field re-points | X | R §6 |
| 64 | 2888-2893 | writing through a field's borrow needs write access; a plain param, capture, or temporary cannot | P | R s9 (+ N-own mutability) |
| 65 | 2893-2899 | a write borrow is lent with `!p`, moved with `<p`, not copied; bare `w` copies the value | X | R §1, s1 |
| 66 | 2898-2903 | a field's `!T` is read-only through `?T`/`*T`; a loop binding cannot hold an element write borrow | X | R s4, s8 (+ §5) |
| 67 | 2989-2992 | `!x` needs a changeable binding; a temporary cannot be write-lent | T | N-own (mutability; temp write lend) |
| 68 | 3016-3023 | second-class borrow bullets | L | R s6, s7 |
| 69 | 3085-3092 | number/Bool/String/plain-enum borrow reads as value; "other values" not copied out | T | R s1 |
| 70 | 3110-3113 | clone: handle or Copy only; no clone with drop glue | T/X | R s2 (+ N-own: `+` on a `drop` type) |
| 71 | 3117-3122 | a borrowed parameter cannot be dropped | X | R s3 |
| 72 | 3154-3156 | reverse drop; a drop-body value cannot borrow a later one | X | R s3, s6 |
| 73 | 3160-3165 | temporary owner positions; "anywhere else" bind | P | R §3 |
| 74 | 3179-3184 | positions for a borrow of a temporary | P | R §3 |
| 75 | 3203-3205 | a drop body takes exactly `!self` | L | S+ |
| 76 | 3257-3264 | a drop body cannot move or reassign `self`; drop only on non-generic structs | X | R s1 (+ N-own §18) |
| 77 | 3273-3276 | `*<x` for a named owner | X | R s8 (Core wording: C2) |
| 78 | 3304-3306 | bare copy of a handle rejected; `*h` of a handle rejected | X | R §1, s8 (+ absorption not stated) |
| 79 | 3308-3314 | handle access is read-only; "Vec is no exception" | X | R s8 |
| 80 | 3387 | `c.get()` only for Copy/plain | T | R s1 |
| 81 | 3393-3397 | Cell `T` list; holds no borrow | T | R s9 |
| 82 | 3399-3408 | `Cell[Vec[T]]` forwarded members; copy-only elements; no element borrow | T/X | N-own (special case: add as a desugaring or cut) |
| 83 | 3410-3414 | by-value params and loop/match bindings cannot change a Cell | X | N-own (mutability) |
| 84 | 3465-3468 | Vec element types | T | R §5 |
| 85 | 3475-3477 | `v[i]`, `v.get(i)` only for Copy `T` | T | R §5 |
| 86 | 3482-3488 | `for` over a Vec: owning element is a borrowed slot; `v` a binding or field | X | R s1, s6 |
| 87 | 3558-3562 | a Box is never cloned | X | R s2 |
| 88 | 3573-3579 | Box reach: a non-struct box reaches no members; `T` holds no borrow; a Vec holds boxes "as it holds handles" | T/X | R §4 |
| 89 | 3646-3649 | Signal holds plain values only; no stack Signal | T | N-own (Signal's kind) + R s9 |
| 90 | 3658-3661 | reentrant `set` queued; subscribing in a subscriber panics | L | N-type (runtime) |
| 91 | 3691-3693 | a bare bar entry naming a local is rejected | X | S+ |
| 92 | 3707-3714 | capture table by type | T | R s2, s4, s8 |
| 93 | 3716-3729 | closure body may not move, drop, or store captures | X | N-own (closures have no Core desugaring) |
| 94 | 3731-3734 | `\|!x\|` is `w = !x` then `\|<w\|` | L | R s6 (already a desugaring) |
| 95 | 3753-3756 | a nested closure cannot move an outer capture | X | N-own (closures) |
| 96 | 3776-3781 | where a closure's parameter types come from | P | N-type |
| 97 | 3847-3853 | stack closure positions; binding fixed, not copied or moved | P | N-own (a stack closure's kind) |
| 98 | 3867-3874 | four forms a `?fun` accepts | T | N-own (lend table has no callable row) |
| 99 | 3921-3926 | a borrowed callable is never a field, element, module binding, or type argument; `!f` rejected | P | R §5, s6 (needs ruling: C10) |
| 100 | 3928-3932 | only a written `?fun` is a borrowed callable | X | N-own |
| 101 | 3995-4000 | owned closure params plain; no borrow captured; `*` only on a literal | T | N-own (param rule) + R s9 |
| 102 | 4021-4023 | no fields through an optional; `as` name scope | X | N-type |
| 103 | 4048-4051 | where `a?` goes; not in deferred code | P | R s10 |
| 104 | 4074-4078 | an optional binding is bound only by `<m` or `+m`; a temporary owns | X | R s1, §3 |
| 105 | 4084-4089 | `?T?` lending; plain copied; a Cell holder is borrowed; `?`/`??` reject a borrowed resource | X | R s1, s4, decision 2 |
| 106 | 4148-4152 | `while` step reads bindings only when plain; `as` "nowhere else" | P | S+ (`as`) (+ N-own step rule) |
| 107 | 4195-4212 | `??` jumps; label in a `while` header; chain "except"; owning optional only temporary or moved | X/P | S §7 (`??`) + R §3, s10 |
| 108 | 4260-4271 | fallibility checks; `T!` only as a return type; `E!` rejected | P | R s10 (+ N-type) |
| 109 | 4376-4382 | fails by a bare error value, binding, or branch value | P | R s10, decision 3 |
| 110 | 4384-4388 | bare `.name` is a variant of `T` in a list of positions | P | R s10 |
| 111 | 4433-4443 | which error set a bare `.name` means | X | N-type |
| 112 | 4638-4653 | visibility rules | X | N-type |
| 113 | 4779-4786 | what `raw` permits; an extern is only called, even in `raw` | T | R "Only raw" |
| 114 | 4812-4816 | extern data and C types | T | N-type |
| 115 | 4838-4843 | Zig-backed: no ct params, cannot fail; a borrowless view result "lives as long as the program" | X | N-own (static exception to s7: C3) |
| 116 | 4869-4877 | type-parameter names; ct value types | T | N-type |
| 117 | 4885-4892 | compile-time argument forms (a `=!` binding included) | T | N-type (+ decision 5 dependency) |
| 118 | 4981-4983 | `print` rejects `[]U8` | X | N-type |
| 119 | 5035-5039 | §18 unsupported list | T | arrays: R §5; rest N-own |
| 120 | 2132-2133 | loop bindings immutable "two source sigils change that" | X | N-own (mutability) |
| 121 | 2301-2310 | match payload binding table | T | R s1, s4 |
| 122 | 2422-2425 | `errdefer` only where the function can fail | P | R s10 |
| 123 | 4006-4007 | `T` accepted where `T?` is expected; `none` needs a known type | X | N-type |

**What the N-own items need.** The 20 N-own items reduce to ten missing
Core statements:

- binding mutability: items 6, 14, 30, 64, 67, 83, 120;
- closures and borrowed callables: items 93, 95, 97, 98, 100, 101;
- `defer`: item 51;
- the static-view exception to s7: item 115;
- a held write view lends read: item 8;
- evaluation order of a borrowed place: item 62;
- the `Cell[Vec]` surface and Signal's contents: items 82, 89;
- `==` by kind: item 34;
- generic type arguments that are views: item 22;
- `+` on a type with a `drop` body: item 70.

Each is a proposed Core edit in §5 below.

**Exception lists that already contradict each other.** Some of the 123
contradict one another inside SPEC:

- Item 1 says arrays hold plain data only. SPEC's own example at 2961-2964
  (`xs = [!n, !m]`) is an array of write borrows.
- Item 56's "or element" is only reachable for plain optionals. No `Vec`
  or array can hold an owning optional (p24, p33).
- Item 61 exempts a write receiver's arguments from the same-call rule
  that item 60 states.

---

## 3. The `docs/CORE.md` plan

### Where the Core sits

1. **Move the file and change who it speaks to.** Move CORE.md to
   `docs/CORE.md` and title it "Rig in one page". Drop "draft", "you
   chose", and the status column. Each sentence keeps the one-line
   example it implies. It ends with "What is not built yet", which links
   to ROADMAP.
2. **Make the docs rule hold.** AGENTS rule 1 says "Docs make no claims
   the test suite does not check". A CORE.md that states decided but
   unbuilt rules breaks this rule. Two fixes:
   - (a) `docs/CORE.md` lands one sentence at a time, as each is built,
     while this draft stays in `.git/revamp`; or
   - (b) better: add a `rig pending` block kind to `test/run`. Such a
     block must currently fail. When it starts passing, the suite fails,
     so the doc gets flipped to `rig` in the same change.

   With (b), every Core sentence gets one `rig` block and one
   `rig reject` block, or `rig pending` blocks for what is not built yet.
3. **The reading order** becomes README, then CORE, then WELCOME, then
   SYNTAX and SPEC:
   - README's "A short tour" opens with one line, "Rig's whole ownership
     model is one page: [docs/CORE.md](docs/CORE.md)", and README's
   "The sigils" table links each sigil to its sentence.
   - WELCOME's "The central idea" becomes the four kinds and the ten
     sentences in teaching form (below), ending "the precise version is
     [CORE.md]".
   - SPEC's preamble says that every ownership rule in SPEC is derived
     from a Core sentence, and that each such section opens with
     "Follows from s*N*".
4. **AGENTS changes:**
   - Add `docs/CORE.md` to the Map, along with the missing README.md,
     FAQ.md, docs/STD.md, and `std/`.
   - Add a rule: "A SPEC ownership rule cites the Core sentence it
     follows from. One that cites none is an exception and needs a Core
     change first."
   - The "How we build" rule says a feature states its desugaring "in
     `docs/INTERNALS.md`". INTERNALS holds none today (`grep -i desugar`
     finds nothing). Either point the rule at CORE §9, or start an
     "INTERNALS: Desugarings" section. Its first entries would be the
     ones SPEC already states: `|!x|` (SPEC:3731), `x op= e`, `!v.push`
     as `(!v).push`, and `?a` as `?a[..]`.

### How SPEC reorganizes around the Core

| SPEC section today | after |
|---|---|
| §2 "Copy values and owning values" | Becomes "Kinds": Core §1's table, plus the rule for a struct's kind (Core edit C5). |
| §2 Arrays, Slices (ownership paragraphs) | One paragraph: a slice is a lend of part of a sequence (s4, §4). The three-ways paragraph, the temporary-array paragraph, the plain-elements rules, and the writable-slice exception list go. |
| §3 Structs: receiver table | Derives from s1 (`?self` unwritten), s4 (`!self` written), and s2 (`<self`). The Bool long form becomes one §7 syntax line. |
| §4 Bindings and assignment | Core §6, with the `=` rule on borrow places and binding mutability (C4). |
| §6 `for`, `match`, `if … as` | One table: a header reads its subject (s1), lends it (s4), or takes it (s2); a header is its own statement (§3). The Vec-source rule and the bare-`for` rejection go. |
| §7 Ownership | Rewritten as derivations, in Core order: 7.1 Reading (s1); 7.2 Moving, cloning, dropping (s2, s3); 7.3 Lending: the lend table (s4, §4); 7.4 Aliasing (s5); 7.5 How long a loan lasts, and results (s6, s7); 7.6 Temporaries (§3, one paragraph); 7.7 Places and assignment (§5, §6); 7.8 Changes and shared storage (s9). |
| §8 Drop glue | Stays as the mechanics of s3. |
| §9 Handles | Derives from s8. The "Vec is no exception" paragraph goes. |
| §10 Cell, Vec, Box, Text, Signal | Member tables only. Element-type lists, Box's member exceptions, `Vec[Box[Text]]`, and the per-type Cell/Signal content rules go; s9 states the content rule once. `Cell[Vec]` forwarding stays only if the Core admits it (C8). |
| §11 Closures | Opens with the closure desugaring (C10): a stack closure is a view of its captures, and an owned one a handle. The positions lists shrink to consequences. |
| §12 Optionals | `as`, `?`, and `??` are s10 plus the `X?` lend row. The `if <m`/`if +m` requirement and the `??` owner exceptions go. |
| §13 Errors | s10 and decision 3. "Failing" shrinks to `return E.name`. |
| §1, §2 numbers, §3 generics, §5 operators, §14–§18 | Unchanged. §18 loses "an array of owning values". |

**What can be deleted outright.** About 40 paragraphs and about 25
examples of these kinds:

- the `rig reject` examples that prove restrictions the Core removes:
  - `total(a)` bare array (SPEC:437-454);
  - `for e in ?(a if …)` (2186-2196);
  - the bare `for x in v` rejection;
  - `[2 of Vec[Int]()]`, which stays only as a copy rejection;
  - the branch's `Vec[Box[Text]]` example;
  - `print((*User(age: 5)).age)` and `r = ?S(n: 1)`, which become the
    one §3 example;
- the Bool long-form position list;
- the module-level `=!` rejection;
- the "Other values … are not copied out of a borrow" paragraph;
- the Vec element list;
- the Box "reaches no members" paragraph;
- the borrowed-callable "never a field's" list, if C10 lands;
- the branch's static-String Cell paragraph, which shrinks to the
  per-value rule.

### Length estimate

| part | branch today (lines) | after (lines) |
|---|---|---|
| ownership-heavy sections (§2 arrays and slices, §3 receivers, §4, §6 headers, §7–§12, Text) | ≈ 2,750 | ≈ 1,700 |
| everything else (§1, numerics, generics, operators, errors, modules, raw, ct, print, §18) | ≈ 2,490 | ≈ 2,500 |
| **SPEC total** | **5,242** (main: 5,049) | **≈ 4,200** (−20%) |
| `docs/CORE.md` | — | ≈ 250 with examples |

In more detail, by SPEC section:

| | §2 | §3 | §4 | §5 | §6 | §7 | §8 | §9 | §10 | §11 | §12 | §13 | §14–18 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| today (main) | 606 | 908 | 118 | 327 | 387 | 742 | 67 | 105 | 306 (+158 Text) | 318 | 240 | 305 | 474 |
| after | ≈460 | ≈810 | ≈110 | ≈310 | ≈330 | ≈420 | 67 | ≈95 | ≈300 | ≈260 | ≈180 | ≈290 | ≈490 |

The bigger win is not the line count. Prose exception lists drop from 65
to 0, and every remaining ownership paragraph cites the sentence it
follows from.

### How WELCOME should teach the Core to a Python or Ruby programmer

1. **Start from the habit they already have.** "In Python, `b = a` makes
   two names for one object. In Rig, a name owns its value. So `b = a`
   copies a number, but for a list you choose: hand it over (`b = <a`)
   or copy it (`b = +a`)." Show the `rig reject` of `b = a` on a Vec and
   its error, then the two fixes.
2. **Teach the four kinds as four questions about a value:**

   | kind | Python/Ruby intuition | in Rig |
   |---|---|---|
   | plain | an `int`, a small frozen record | copied freely |
   | owning | an open file, a list you alone hold | one owner; `<x` hands it on, `-x` closes it now, the scope's end closes it otherwise (like `with`) |
   | handle | an ordinary Python reference, shared and counted | `*x` shares, `+h` adds a holder, `~h` is a `weakref` |
   | view | a slice or a memoryview onto someone else's data | `?x` reads, `!x` writes, and it cannot outlive what it views |

3. **The ten sentences as a card.** Give one line and one example each.
   Ruby hooks help:
   - Ruby's bang methods (`sort!`, `push`) map onto "every change is
     marked by `!`" (s9): `!v.push(x)`, `sort.sort(!v)`;
   - Python's `del x` is `-x`;
   - `None` and exceptions map to `T?` and `T!` (s10);
   - "a bare name only reads" (s1) is what they expect from Python.
     Reading never surprises them. Only taking and changing are marked.
4. **Then the five tour programs**, each annotated in the margin with the
   sentence numbers it exercises (`# s4: lent to write`).
5. **Add ownership rows to the "From C, Python, Ruby …" table:**

   | Python / Ruby | Rig |
   |---|---|
   | `b = a` (alias) | `b = <a` or `b = +a` |
   | `copy.deepcopy(v)` / `dup` | `+v` |
   | `del x` | `-x` |
   | `weakref.ref(o)` | `~h` |
   | a shared mutable object | `*Cell[T]` |
   | `list.append` / `push` | `!v.push(x)` |

6. **Add two "Habits" entries:** "aliasing assignment", the `b = a` error
   on an owner; and "changing a borrowed list", the error for a missing
   `!`.

---

## 4. Stale and false claims

All of these were checked against `main`. A probe file under
`probes/docs/` proves each one where a probe is named.

| # | file:line | claim | truth | probe |
|---|---|---|---|---|
| 1 | README:12-15 | "There is no standard library … yet" | std.math, os, time, random, sort, and slices ship; README:268-271 lists them itself | p01 |
| 2 | WELCOME:218-220 and 521-522 | "a bare name never moves an owning value" | `r` as a last line and `return r` move an owner bare (SPEC:2496 says so) | p02 |
| 3 | WELCOME:474-476 | "Every place where the habit would change a program's meaning is an error" | `dup = !s.insert(1)` compiles. A C reader sees "not" | p32 |
| 4 | DESIGN:329-330 | "A habit can make a program fail to compile, never change what it means" | Same as #3 | p32 |
| 5 | WELCOME:323 | `sub main` becomes `pub fn main() void` | It becomes `pub fn main(__rig_init: std.process.Init.Minimal) void` (INTERNALS:1183 is right) | p31 |
| 6 | WELCOME:115-117 | "every mutation is visible" | `c.set(…)` through a `?Cell` mutates with no `!` | p34 |
| 7 | DESIGN:50-53 | mutation "each ha[s] a marker" | Same as #6 | p34 |
| 8 | WELCOME:201-202 | `*Cell` is "the one way to share state that changes" | `*Signal` is another (SPEC §10) | (SPEC example) |
| 9 | DESIGN:282 | `sort(!v[..], \|a, b\| a < b)` | No such call: `sort.sort` takes one argument; it is `sort.sort_by` | p35 |
| 10 | SPEC:252 | "Arrays hold plain data only" | Arrays hold read and write borrows: `[?a, ?b]`, `[!n, !m]` (SPEC's own example at 2961) | p03 |
| 11 | SPEC:2595-2596 | an "optional field **or element**" can be taken | For owning values, only a field. No Vec or array holds `*T?` or `Box[T]?`. The element form works only for plain optionals | p24, p33, p37 |
| 12 | FAQ:9-10 | "structs, enums, and arrays are plain values" | A struct holding a Vec owns it; `Vec[Row]` is rejected for that reason | p04 |
| 13 | SPEC:1644 and CORE §6 | indexes are evaluated "from the outside in" | The order is left to right (outer index first). "Outside in" reads as the opposite to many readers | p38 |
| 14 | SYNTAX:41-42 | "A program that runs declares its entry point, `sub main`" | Or `fun main -> Int` (SPEC §1) | — |
| 15 | SYNTAX:408 | a borrowed callable is "a parameter's type" | Also a local's or a result's (SPEC:3921-3922) | — |
| 16 | WELCOME:607-612 | `*x`, `Box(v)`, `Vec`, and owned closures are "the only things that allocate" | `std.os.args()` allocates in the runtime. On the branch, `Text(...)`/`!t.add` allocate too | — |
| 17 | AGENTS "How we build" | a feature "states its desugaring … in `docs/INTERNALS.md`" | INTERNALS contains no desugaring section and no desugaring. The rule is unmet | grep |
| 18 | AGENTS Map | lists the docs | Omits README.md, FAQ.md, docs/STD.md, and `std/` | — |
| 19 | CORE §4 status | "partly built (arrays, **Text**, Box)" | `Text` is unbound on main; it is branch-only | p16 |
| 20 | CORE §6 status | assignment order: "**branch** (safety-net, PR #31)" | PR #31 is merged; HEAD `dd36c78` is that merge; SPEC:1651-1674 runs | — |
| 21 | CORE s10 | every fallible call says what happens "`!`, `catch`, or `??`" | `f() ?? 0` on a `T!` is rejected: `??` needs an optional | p22 |
| 22 | CORE §5 | "today `Vec[Text]` is rejected" | On main there is no `Text`. What main rejects is `Vec[Vec[Int]]` and `Vec[Row]` with an owning field | p04, p27 |

**Checked and true.** These docs claims were probed and hold:

- DESIGN absorption ("a `!T` is accepted where a `?T` is expected", p25);
- std.os's static Strings (p30);
- `=!` as a compile-time argument (p36);
- the silent state fork of a copied struct holding a Cell (p14). This is
  real, and is exactly decision 2.

**Not checked line by line.** INTERNALS is a compiler guide. I checked its
claims that touch the Core:

- the borrow-of-temporary sentence (INTERNALS:628-633, matches main);
- "no LALR conflicts" (no `@conflicts` in `rig.grammar`);
- the `main` signature.

I did not probe its numeric limits: 64 blocks, 1000 tree depth, and 256
queued releases.

---

## 5. Edits to CORE.md

### Status markings

- **C-status-1.** In §4, change "**partly built** (arrays, Text, Box)" to
  "**built** for arrays and Box. **branch** for Text. **decided** for
  Vec, `*T`, and optionals." (p16, p17, p18)
- **C-status-2.** In §6, change "**branch** (safety-net, PR #31)" to
  "**built**".
- **C-status-3.** s10: delete `??` from "`!`, `catch`, or `??`" (p22).
  `??` handles absence, not failure.
- **C-status-4.** s1: "today some positions still require `?`" understates
  it. Name the positions:
  - a `?T` parameter (p21);
  - a `for` over a Vec (p05);
  - `if m as x` (p06);
  - an array slice;
  - a borrow read of plain structs (p08);
  - a ternary or `??` over owners (p19, p20).
- **C-status-5.** In §5, change "today `Vec[Text]` is rejected" to "today
  `Vec[Vec[T]]`, `Vec[Row]` for a `Row` that owns, `Vec[*T?]`, and arrays
  of handles are rejected (p04, p24, p26). On the branch, `Vec[Text]` is
  too."

### Contradictions inside the Core

- **C1. Does `return x` move?** s1 says a bare name "never moves". §3
  lists `return` among taking positions. Today `return x` and a last-line
  `x` move bare (p02), and WELCOME and DESIGN advertise that. Pick one
  and say it in s1:
  - (a) "In a taking position, a bare owner, handle, or write view is an
    error: write `<x` (move) or `+x` (new owner). This includes
    `return`."
  - (b) "… except `return x` and a last-line `x` of a local, where the
    name's scope ends anyway."

  Option (a) is cleaner. Option (b) is one exception, but it should then
  be listed. Also make it an open decision, since it changes every
  function that builds and returns an owner.
- **C2. s8 "`*x` moves `x`" contradicts s1.** Write "`*e` moves its
  operand into a counted box: `*<x` for a name, `*Point(...)` for a new
  value" (p10).
- **C3. s7 has an unstated exception.** `std.os.args()` returns a view of
  nothing it was lent (p30, SPEC:4840-4843). Add "… or of what lives for
  the whole program (literals, the program's arguments)". §8's "lives for
  the whole program" fact is the compiler side of this.
- **C4. s1 "It copies plain data and views"** contradicts §1's "a write
  view moves". Write "copies plain data and read views".
- **C5. §1 "A type's kind follows from its parts" has no rule.** State it:
  - a type is **owning** if any part is owning or a handle;
  - otherwise it is a **view** if any part is a view (a write view makes
    it move);
  - otherwise it is **plain**.

  Say where `Cell[T]` sits, given decision 2. Say where a stack closure
  and a `?fun` sit (both are read views). Say where `Signal` sits (only
  behind `*`).
- **C6. §3 headers.** "The subject of a `match` or `for` [is a] statement
  of [its] own" and "a call's result that … `match` or `for` binds is
  taken" need one more clause and one example each. Write: "the header's
  own temporaries end with the header; the value it binds lives through
  the body". The examples:
  - `for x in ?make_vec()`, which SPEC:3181 accepts today: is the loan
    taken in the header still live in the body?
  - the branch's `if text.cut(?Text("k=v"), "=") as kv` (rig-text
    SPEC:3176), which the Core rejects.

  Without these, readers will read §3 in opposite ways.
- **C7. §5 "Each element is a place" leaves out fields.** Write "Each
  field and element is a place". `<p.f` takes an optional field
  (SPEC:2595) and `!p.f` lends one. Also say that `<`'s operand is a
  place or a fresh value: `<(a if c else b)` is written
  `<a if c else <b`.
- **C8. s9 calls `Cell` "the one exception".** But `Cell[Vec[T]]` forwards
  `push`, `pop`, `clear`, `c[i]`, and `c[i] = x` without `!` (SPEC:3399).
  That is a second interior-mutable surface with its own copy-only
  element rule. Either state it as a desugaring ("`c.push(x)` is
  `v = c.replace(Vec()); !v.push(x); c.set(<v)`") or cut it.
- **C9. s2: `+x` "as the type says"** does not say what a type with a
  `drop` body gets. Today it gets none (SPEC:3112), and `Rng` relies on
  that. Say: "A type with a `drop` body, or declared `unique`, has no
  `+`."
- **C10. Closures are absent.** They need a sentence or a §-level
  desugaring:
  - A stack closure is a struct of its captures, called through
    `?self`, so it is a view of what it borrows.
  - An owned closure `*|…|` is a handle whose environment carries no
    loan (s9).
  - `?f` lends either one as a `?fun`.
  - This settles SPEC items 93–101: why a body cannot move a capture,
    and whether a `?fun` may sit in a Vec, which §5 says yes and SPEC
    says no.
- **C11. Sentence 9's scope.** "Every change is marked by `!` where it is
  lent" does not cover assigning one's own binding (`x = 5`) or `<x`/`-x`.
  Add "A name's own value is changed by assigning it."

### Missing rules (from the N-own column of §2)

- **M1. Which names may change.** By-value parameters, loop, pattern, and
  `as` bindings, captures, and fixed bindings may not be assigned or lent
  to write. Owned locals may, and a write view writes through. This is
  seven SPEC exception sites; one sentence covers them all.
- **M2. `defer`.** "Deferred code runs where its scope ends, after the
  owners declared after it are dropped. So it may not move, drop, or
  propagate, nor read a later name."
- **M3. A held write view lends read.** Add a §4 row: "`!T` (a held write
  view): `?w` lends its read views; `!w` reborrows it." DESIGN
  "Absorption" is built (p25).
- **M4. Evaluation order of a lend.** §6 covers assignment. A lend
  `!v[i]` finds its place before the index runs (SPEC:2853), and a write
  receiver's arguments are evaluated before the call writes
  (`!v.push(v.len)`, SPEC:2811). Both need a line, or they are
  exceptions.
- **M5. `==` by kind.** "`==` compares plain values and what read views
  reach. Owners, handles, and view structs have none." This would let
  SPEC's equality exception list (SPEC:1834-1838) be derived.
- **M6. Generic bodies.** "A type parameter stands for any type that
  holds no loan." SPEC:1394 forbids view type arguments. §5 says
  containers hold views, so `Vec[?T]` in a generic body needs a ruling.
- **M7. §7 needs a catch-all.** "Every other rule in SYNTAX.md is syntax."
  Otherwise list the S+ items: open slice sides, `as` placement, statement
  uses, guard statements, `while` steps, the bar-list rule, constant and
  default forms, the unread-local lint, and `-x` taking only a name.
- **M8. Scope.** One line under the title: "Types, numbers, generics'
  per-instance checks, modules, and FFI are outside the Core." Without
  it, the 16 N-type rules look like unlisted exceptions.

### What a newcomer would misread

- **"Loan", "lend", "borrow", and "view".** The draft uses all four
  without defining them. Add a three-line glossary:
  - **lend** (`?x`, `!x`) is the act;
  - a **view** is what you get;
  - a **loan** is what a view carries back to its owner.

  Then use "borrow" nowhere, or only as SPEC's synonym.
- **"A read view copies."** Readers will think the value is copied. Say
  "copying a read view copies the view, not what it views".
- **"handles only read" (s8).** Add "(a `Cell` inside one still changes:
  s9)". Otherwise `*Cell[T]`, the documented way to share state, looks
  forbidden.
- **The §4 table's empty `!x` cell for `X?`.** It reads as "you cannot
  write-lend an optional". Write "`!(X?)`, by the first row". In the
  `*T` row, write "nothing of the value; `!h` lends the handle variable
  itself".
- **§6 "This matches Rust" and "outside in".** Rust evaluates a plain
  assignment's value first. For compound assignment it does so only for
  primitive types. Say "matches Rust for `=`", and say "indexes left to
  right" (p38).
- **The title and the status markers address the maintainer.** "you chose
  it" and "needs your decision" must go before this becomes
  `docs/CORE.md`.
- **§9 "It is written as a desugaring into forms this page already
  covers".** Say where the desugaring is written. INTERNALS has none
  (item 17 in §4), and AGENTS points there.
