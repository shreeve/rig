# Core audit: reads, lends, and temporaries

Dimension: Core sentences 1, 3 and 4, §3 (temporaries) and §4 (the lend
table). Read-only audit.

- **main:** `/Users/shreeve/Data/Code/rig` at dd36c78.
- **branch:** `/Users/shreeve/Data/Code/rig-text` (`text-core`) at 59e7bed. It is based on 8a82fab, so it lacks main's 871857f7 and the rest of PR #31.

All 116 probes are in `probes/reads/`. `run.sh` runs each probe on both compilers, and `results.txt` holds the last run. A probe name in **bold** below points to that file. Line numbers are `M` for main and `B` for the branch.

---

## 0. Summary

1. **"A bare name only reads" can be adopted without changing what any accepted program means.**
   - Every position where it matters rejects a bare owner today, so each change turns a rejection into an acceptance.
   - The one real conflict is a position the Core does not mention: **a bare owning name in `return` or in a function's tail position moves today** (`t01_return_bare` is accepted on both compilers). That contradicts "it never moves". A `break` value needs `<b`, but `return b` does not.
2. **Main already lends bare in three places, against its own rules.**
   - `for x in a` over a named array is a read loan, not the copy SPEC §6 describes (`f06`).
   - `match s` reads.
   - `print`/`==` read.
3. **The §4 table is less built than the Core says.**
   - Text is a branch feature, not a built one.
   - Box lending is one level deep and does not compose: `Box[Box[S]]` and `Box[[N]T]` are both rejected (`l11`, `l12`).
   - The table leaves out three rows the compiler already has: callables, narrowing a write view to a read view, and lifting `T` to `View?`.
4. **The Core says §3 cuts back "the branch". It also cuts back main.** Main already extends a *borrowed plain* temporary through `if ?opt() as p`, `while ?opt() as q`, `match ?e()` and `for x in ?[..]` (the `lent_borrow` path). A main behavior test asserts this: `test/behavior/ownership/borrowed_temporary_lives_for_statement.rig`.
5. **The branch has a soundness hole that main has closed.** `for x in h.o?`, where the Vec sits behind a borrowed optional field, **double-frees** on the branch (`s03`). `for x in (a if c else b)` emits Zig that does not compile (`s01`). Main rejects both through 871857f7's `makesValue` check, which the branch predates. Both are the "classified by syntax" class that item 4 removes.

---

## 1. Gap table

**Columns.**
- **Status claimed:** what the Core marks.
- **Probe:** the probe's name, then main → branch.
- **Size:** S, M, or L.
- **Step:** the order to build in (see §6).

### Sentence 1 and sentence 4: bare reads and implicit lends

| Core rule | Status claimed | Actual behavior (probe) | Gap | Code location | Size | Step |
|---|---|---|---|---|---|---|
| S1: a bare argument reads (to a `?T` parameter) | decided | Rejected on both, with "lend a read borrow: `?b`" (`a02`, `a05`) | Implicit read lend not built | typecheck `checkExpr` M6660, `mismatch` M6804–6822; ownership `walkConsumed` M1404, `checkNoImplicitCopy` M2102 | S | 2 |
| S1: a `Copy` value passed to `?Int` | decided | Rejected on both (`a03`, `g01`) | Same | Same | S | 2 |
| S1: a `for` source | decided | A bare Vec is rejected: "write `for x in ?v`" (`f01`, `f03`, `f05`). A bare array is **already a read loan** (`f06`: `a[0] = 9` in the body gives "while `a` is borrowed"), although SPEC §6 says the array is copied. | Vec gap, and the SPEC is wrong about arrays | typecheck `checkFor` M1570–1571; ownership `walkFor` M3358 (a place source already gets a loan whatever its sigil); emit `emitFor` M1997 | S | 2 |
| S1: `if o as x` / `while o as x` | decided | An owning `o` is rejected: "bare use … in binding would alias" (`i01`, `i03`). `?o` works (`i01b`), and `<o` moves (`i01c`). | Not built | typecheck `checkOptionalBinding` M1455–1490 (a bare place types `x` as owned); ownership `walkConditionParts` M3148 (`walkConsumed(.binding)`) | S | 2 |
| S1: the `match` subject | decided | An enum reads bare (`m02`). A Box must be written `match ?b` (`m03`). A `*E` cannot be matched at all (`m05`). | Box and `*T` rows missing | typecheck `checkMatch` M1778, Box at M1798–1812, "matchable" check at M1816 | S (Box), M (`*T`) | 3 |
| S1: `print` / `Text(...)` arguments | built | Read bare (`p01`, `p02`, `x01`) | none | `checkPrint` M4706; branch `checkFormatArgs` B4888 | — | — |
| S1: `==` operands | built | Read bare. Few owning types have `==`: Text on the branch (`e04`), and `o == none` (`e05`). | none | `synthEquality` M2827 | — | — |
| S1: a receiver | built for `?self` | `b.total()` reads (`r01`). A `!self` method needs `!b` (`r06`) and a `<self` method needs `<b` (`r04`), as S4 intends. A `Box[S]` receiver works (`r05`), but **a `Box[Text]` reaches no members** (`x08b`, `x09`). | Box[Text] members | typecheck `synthMemberCall` M5964 (diagnostics at M6621–6649); branch B3561 "reaches no fields" | M | 3 |
| S1: field and element reads | built | `b.n` and `b.v.len` read (`d01`). Binding an owning field bare is rejected (`d02`), which is correct. | none | `synthMember` M3477 | — | — |
| S1: closure captures | not mentioned | Always written with a sigil. A bare outer name in the body is rejected (`c01`). `\|b\|` is a parameter, and naming one after a local is rejected (`c02`). | The Core should say captures are declarations and never implicit | resolve.zig M306; typecheck M2380 | doc | 1 |
| S1: "never moves", in returns | **not mentioned** | **A bare owner moves** in `return b`, in a tail `b`, in `if` branch tails, and in a tail `b if c else d` (`t01`, accepted on both). `break b` is rejected and needs `<b` (`t02`). | **Contradicts S1.** An exception the Core does not list. | ownership `checkNoImplicitCopy(top_return)` M2102; `consumeTailName` M1455; `returnMoves` M3074; `walkReturnValue` M3044 | decision, then S | 1 |
| S1: binding right-hand sides, and other takes | §3 "taking" | A bare owner is rejected as a binding (`d03`), a call argument (`k01`), a constructor field (`k02`), a `push` (`k03`), a field assignment (`k04`), and for a handle (`k06`, `k07`). A view copies (`d04`). | none: these already follow "a take needs `<` or `+`" | `reportAlias` M2226 | — | — |
| S1: a stack closure lent to `?fun` | (implied) | A bare `add` is rejected; `?add` is required (`l08b`). A function name lends bare (`l08`). An owned closure needs `?cb` (`l16`). | Inconsistent bare-read rule for callables | typecheck `lendCallable` M7515; `synthBorrow` M3184 | S | 2 |
| S1: a Text read bare as a String | branch | A `?Text` binding or parameter reads bare as a String (`x05`, `x12`). A named `Text` must be written `?t` (`x02`). Through `?self`, the field needs `?self.title[..2]` (`x11`). | Three answers for one type | branch `textAsString` B7008–7039 | S | 2 |
| S4: a write lend is always written | partly built | A held `!T` must be re-marked `!s` (`w01`). A held `?T` forwards bare (`w02`). | none | `checkLendsVisibly` M4901 | — | — |

### Sentence 3 and §3: temporaries

| Core rule | Status claimed | Actual behavior (probe) | Gap | Code location | Size | Step |
|---|---|---|---|---|---|---|
| S3: an unnamed value is dropped where its statement ends | built / decided | **Main:** rejected wherever it is only read (`q12`, `r03`, `q14`, `m04`). Taken values work (`k05`, `i02`, `q11`). **Branch:** accepted, with drops in the right order (`q12`, `r03`, `q05`, `q14`). | Main lacks it; the branch has it | branch B3549–3563, ownership B1306–1365, emit B1037–1099 | M (landing) | 4 |
| §3: reading never moves a name, whatever the form | decided | `print((a if c else b).n)`, `print(o?.n)` and `print((mko(1) ?? d).n)` are rejected on both, each with a different error (`q01`, `q02`, `q03`). `?(a if c else b)` is rejected (`g03`). | The freshness classification | branch `handsOverFresh` B3524, `rejectNotFresh` B3511; main `rejectResourceTemporary` M3470 | M | 4 |
| §3: a receiver is a reading position | decided | `mk(5).get()` is rejected on both (`q04`, `r02`). `(?mk(5)).get()` is accepted on the branch (`q05`). | The receiver is not a read site | `synthMemberCall` receiver calls to `rejectResourceTemporary` (B6229, 6237, 6276, 6306) | S | 4 |
| §3: an `if` / `while` condition is its own statement | decided | Branch: `if mk(1).n == 1` drops **after** the then-body (`q06`). `while mk(10+i).n < 12` drops after each body (`q07`). | Header extension | ownership `walkIfBinding` B3316, `walkConditionParts` B3342, `loopIteration` B3684–3701; emit `emitTempSlots` B1058 | M | 4 |
| §3: a borrow of a temporary stays in its statement; headers count | decided | Branch accepts `if idp(?mk(3)) as r` with `r` used in the body (`q08`), `while idp(?B(n: i)) as r` (`q15`), and `if text.cut(?Text(...)) as kv` (`q16`). **Main** accepts the plain-data form: `if ?opt(3) as p`, `match ?e(5)`, `for x in ?[mk(6), mk(7)]` (the behavior test named in the next column). | Main **and** branch extend | main `lent_borrow` (`checkOptionalBinding` M1459–1462, `checkMatch` M1783–1786, `synthBorrow` M3223); branch as above | M | 4 |
| §3: a call's result that `match` binds is taken | decided | Branch: `match mk()` **reads**, so moving a payload is rejected: "write `match <mk()`" (`q09`). Reading the payload is accepted, held in a hidden variable (`q10`). Main rejects both. | Match reads a temporary | branch `checkMatch` B1781 (`synthReadTemp`), ownership `walkMatch` B3416–3420 | S | 4 |
| §3: a call's result that `for` binds is taken | decided | `for n in mv()` consumes the Vec (`q11`, both). `for n in ?mv()` is accepted on both (`q11`). | `?call()` must become a statement-scoped borrow, and therefore an error | main `lent_borrow`; emit `emitFor` M1997 | S | 4 |
| §3: `??` in a read | decided | `print((mko(1) ?? d).n)` is rejected (`q03`). `d = mko(0) ?? mk(3)` is accepted on the branch and rejected on main (`q13`). | The `takes_whole` special path | main `synthCoalesce` M2992; branch B3001–3021 | S | 4 |

### §4: the lend table

| Core rule | Status claimed | Actual behavior (probe) | Gap | Code location | Size | Step |
|---|---|---|---|---|---|---|
| §4: any `T` lends `?T` / `!T` | built | Yes (`a01`) | none | `synthBorrow` M3173 | — | — |
| §4: `[N]T` lends `[]T` / `![]T` | built | Built only for a **named** array, written (`l01`, `l03b`). `sum(a)` bare is rejected (`l01b`). A temporary array literal is lent only to a call that keeps nothing. | Only the bare form is missing | `arrayAsSlice` M6737–6783, `lentTempLiteral` M6715 | S | 2 |
| §4: `Vec[T]` lends `[]T` / `![]T` | decided | `sum(?v)` is rejected; `?v[..]` is required (`l02`, `l02b`). `zero(!v)` is rejected (`l03`). A `?Vec` parameter cannot be lent as a slice (`l14`). | Not built | new row in `lendsAs` | S | 3 |
| §4: Text lends String / `!Text` | **"built"** | **Branch only** (`x01`, `x07`). | Status is wrong: **branch** | branch `textAsString` B7008 | — | — |
| §4: `Box[T]` lends the views of `T` | **"built"** | `?b` → `?S` and `!b` → `!S` are built (`l05`). Branch: `?b` → String for `Box[Text]` (`x08`). **Not built:** `Box[[N]T]` → `[]T` (`l11`), `Box[Box[S]]` → `?S` (`l12`), and Box[Text] members (`x08b`). | Composition is not built, and `Box[Text]` is a special case | `boxLent` M6785–6802; branch `textOrBoxed` inside `textAsString` | M | 3 |
| §4: `*T` lends the read views of `T` | decided | `get(?h)` is rejected (`l04`). `!h` is correctly rejected (`l09`). Members do work (`l04c`). | Not built | new row | S–M | 3 |
| §4: `X?` lends `View?` | decided | `(?S)?` from `?o` is rejected; today `?o` is `?S?` (`l06`). `Text?` → `String?` is rejected (`x06`). `?Vec?` → `([]Int)?` is rejected (`l07`). | Not built, and the table must name the canonical type (see §2) | new row | M | 3 |
| §4: the table composes | decided | No composition exists (`l11`, `l12`, `x10`: `*Text` → String is rejected). | Not built | `lendsAs` recursion | S once the table exists | 3 |
| §4: missing row, callables | not in the Core | Built: a function, a literal, `?f` of a stack closure, and `?cb` of an owned closure lend as `?fun` (`l08`, `l16`). An alias `?F` is **not** a callable (`l08c`, a bug). | The Core table omits a built conversion | `lendCallable` M7515; `callableOfFn` in resolve M1606 | S | 3 |
| §4: missing row, narrowing | not in the Core | Built: `![]T` is lent as `[]T` (`l13`, the `readsAsView` fact). `!Box` is lent as `?T`. | Omitted | `checkExpr` M6690 (`recordReadView`) | — | 3 |
| §4: missing row, lifting `T` to `View?` | not in the Core | Built on the branch for Text: `?t` → `String?` (`x07`). | Omitted | branch `textAsString` (its `.optional` unwrap) | — | 3 |

---

## 2. Corrections to the Core's status markings

1. **Sentence 1.**
   - **Keep:** "decided".
   - **Change:** "(today some positions still require `?`)" to "(today `?` is required for arguments, including Copy values, a Vec `for` source, `if`/`while … as`, a boxed `match` subject, a stack or owned closure lent as `?fun`, and a named Text lent as a String; **and a bare owner in `return` or a tail position moves**)".
   - **Add an open decision** for the tail move. There are two options:
     - (a) State it as a rule: "`return x`, or a function's last value, takes a bare name, since its scope ends there".
     - (b) Require `<x` everywhere a value is taken.

     Option (a) needs one sentence, and `break v` should then follow it too. Option (b) is consistent but noisy.
2. **Sentence 3** is "built / decided".
   - **Change it to:** "built (scope end); **branch** (statement temporaries, wider than §3); decided (§3)".
   - **Why:** main rejects every owning temporary in a read position.
3. **Sentence 4** is "partly built; the full table is decided".
   - **Keep it, and add:** "implicit read lends: **not built** (branch: a `?Text` binding as a String only)".
4. **§3** is "decided (the branch has a wider rule that is being cut back)".
   - **Change it to:** "decided; **main and** the branch extend header temporaries".
   - **Why:** main's `lent_borrow` lets a borrow of a plain temporary live through an `if … as`, `while … as`, `match` or `for` body.
5. **§4** is "partly built (arrays, Text, Box)".
   - **Change it to:**
     - "built: any `T`, named arrays, one-level Box, callables, `![]T` → `[]T`;
     - branch: Text → String / `String?`, `?Text` bare, `Box[Text]` → String;
     - decided: Vec, `*T`, `X?`, composition, Box members of every type".
   - **Also:** add the three missing rows (callables, narrowing, lifting to `View?`).
6. **§4 `X?` row.** Today `?o` of an `S?` is typed `?S?`, a borrow *of the optional*, and `if r as x` already gives `x: ?S` (`l06b`). The table must say whether `?o` lends `?(S?)` or `(?S)?`. My recommendation:
   - Keep `?S?` as the type of `?o`.
   - Make `View?` a **lend target**: `?o` where `(?S)?` or `String?` is expected.
   - Keep one spelling per type.
7. **§3's list of reading positions.**
   - "A receiver" should be "a `?self` receiver". A `!self` call on a temporary is either rejected ("the change would be lost") or allowed as a write to a temporary. The Core is silent on this.
   - The list should name **block and `match` values** as made values, as design F does. Their inner value is taken out of its scope, so a block-local name there needs `<t`. Without this, "reading never moves a name" reopens the trap of a block-local name read after its block ends.
   - "A call's result that … `match` or `for` binds is taken" should say "a value made there" (a call, a constructor, `+x`, `*x`), not only "a call's result".

---

## 3. Behavior the Core does not cover

1. **Tail and return moves** (above). Today `return b`, a tail `b`, `if` branch tails, and `b if c else d` in tail position all move a bare owner. A `break b` does not: it needs `<b`.
2. **Copying a value out of a borrow** is limited to numbers, `Bool`, `String`, and plain enums. A plain struct behind `?P` is not copied (`v01`: "only a number, `Bool`, `String`, or plain enum is copied out of a borrow"). S1 says "it copies plain data and views". Through a view, only scalars copy. This is the `readsThrough`/`readValue` fact (`sema.readsThrough` M1189).
3. **`for` over an array.** SPEC §6 says "an array is copied", but the checker borrows it (`f06`). The Core's "plain copies" would describe SPEC's wording; the compiler is already on the lend side. The fix is to make the SPEC say the loop lends `[]T`.
4. **Captures** are always declared with a sigil, and `|x|` is a parameter. None of this is in the Core.
5. **Receiver sigils.** `?b.total()` lends `b`, and `(?b).total()` is the same call (`r01b`). This is listed in §7 as syntax. Fine.
6. **Owned closures and stack closures lend differently** (`l08b` and `l16` need `?f`; `l08` lends a function bare). The Core's S1 implies all three read bare.
7. **On the branch, `for x in o?` over an owned optional parameter silently moves** the Vec out of `o` (`s02`, accepted). `for x in h.o?` through a borrow **double-frees** (`s03`). This is the branch missing main's 871857f7. A rebase must keep main's check, and should express it as "for over a place lends, for over a made value takes" (item 4), not with `makesValue`.
8. **Plain-data temporaries.** Main's `lent_borrow` treats a borrow of a plain temporary (no drop) as living through a header. §3 makes no distinction between plain and owning temporaries. Under §3, `if ?opt(3) as p` is rejected even though nothing is dropped. That is consistent with the rule; it is a migration item.

---

## 4. Item 1: what applying "a bare name only reads" changes

**Rule to implement.** The context decides what a bare name gives.

| Expected type | Plain data or a view (bare) | An owner or a handle (bare) |
|---|---|---|
| A value | copies | is rejected: write `<x` or `+x` (unchanged) |
| A view | lends implicitly | lends implicitly |
| Reading position (`print`, `==`, a receiver, a field base, a `match` subject, a `for` source, an `as` value) | copies (unchanged) | reads in place |

**Rejections that become acceptances.** No currently accepted program changes meaning, for two reasons:
- Each row below is rejected today, so no accepted program contains it.
- Where a bare name is accepted today, it is either a read already (`print`, `==`, a receiver, `match`, an array `for`) or a copy of plain data or a view. Both stay.

| Probe | Today | After |
|---|---|---|
| `a02`, `a05` | `size(b)`, `count(b.v)` rejected | an implicit `?b` |
| `a03`, `g01` | `sizei(k)` with a `?Int` parameter rejected | an implicit `?k` (also when inferring a generic `?T`) |
| `f01`, `f03`, `f05` | `for x in v` rejected | a `[]T` lend of `v` (ownership already loans the root) |
| `i01`, `i03` | `if o as x` over an owning optional rejected | `x : ?T`. Plain optionals still copy. Implementation must keep `x: Int` for `Int?`, or writes to `o` inside the body become rejections. |
| `m03`, `m05` | `match b` over a Box rejected; `*E` unmatchable | lend through the table |
| `l01b` | `sum(a)` rejected | an implicit `[]T` lend |
| `l04b`, `l05b` | `get(h)` and `get(b)` rejected | lend through the table |
| `l08b` | `twice(add, 0)` rejected | lend the closure |
| `x02`, `x03`, `x05b` | `first(t)`, `for b in t`, `for b in t` for a `?Text` rejected | String lends |

**What stays rejected.** Every taking position: `d02`, `d03`, `k01`–`k07`, `t02`. A write lend must always be written (`w01`, `r06`), and so must a consuming receiver (`r04`).

**Meaning-change risks checked.**
- **Generic inference.** `id[T](x: T)` with a bare name is still a take. Only a `?T` parameter gains an implicit lend.
- **Plain optional in `if … as`.** It must keep copying, or writes to `o` in the body become rejections. This is not a meaning change, but it would be a regression.
- **A struct holding a Cell lent implicitly.** It lends exactly as `?c` would. With `?c` written today, the same Cell writes happen.
- **Overloads.** Rig has none.

**Code that decides each case today, and the change.** The fix is the same in every case: typecheck records one lend fact (§5) on the bare node, and ownership and emit read that fact instead of checking `e.isKind(.read)`.

| Position | typecheck | ownership | emit |
|---|---|---|---|
| Argument | `checkExpr` M6660 → `mismatch` M6820 (the hint) | `walkConsumed` M1404 → `checkNoImplicitCopy` → `reportAlias` | `emitArg` |
| `for` | `checkFor` M1570 (delete the error) | `walkFor` M3375 (already loans a place; the `resource_vec` flag keys on written `?`, M3384) | `emitFor` M1997 (`isPlace`) |
| `as` | `checkOptionalBinding` M1469–1488 | `walkConditionParts` M3158 | the as-binding emit (pointer capture) |
| `match` | `checkMatch` M1780 (mode chosen by sigil) | `walkMatch` M3205 (`lent` decided by sigil) | `evalSubject` |
| Callable | `lendCallable` M7515, `synthBorrow` M3184 | `lentCallable` M1511 | `emitLentCallable` |

**Size.** The checker work is S: about 40–60 lines, one helper (`implicitLend`), and about 6 call sites. The suite and doc migration is optional, since `?x` remains legal. 595 written `?x` sites could later be normalized by a formatter.

---

## 5. Item 2: one `lendsAs` table

### The conversions today

| Fact (sema.zig) | Recorded by | Read by | Lend-table row |
|---|---|---|---|
| `arrayViewOf` (`.borrowed`) M1269 | `arrayAsSlice` M6737 | ownership `isArrayView` M1709; emit M3079 (`&a`) | `[N]T` → `[]T` / `![]T` |
| `arrayViewOf` (`.temporary`) | `lentTempLiteral` M6715, `arrayAsSlice` | emit M3800, M4121, M4439 | the same row, of a temporary (this is a §3 matter) |
| `readsAsView` M1342 | `checkExpr` M6690 | ownership `walkConsumed` M1420 (downgrades the loan to a read) | narrowing: `![]T` → `[]T` |
| `unboxes` M1332 | `boxLent` M6785 | emit M2742, M2965, M4433 (`emitUnboxed`) | `Box[T]` → `?T` / `!T` |
| `callableOf` M1281 | `lendCallable` M7515 | ownership M1511, M2655; emit M2741, M4246, M4405 | callable → `?fun` |
| branch `lendsText` B1397 | `textAsString` B7021 | emit B2760 | `?Text` → String |
| branch `arrayViewOf` reused for Text | `textAsString` B7031 | emit (bytes) | Text → String |
| branch `textOrBoxed` (inline) | `textAsString` | — | `Box[Text]` → String (a hand-made composition) |
| `readsThrough` M1189 | `readThrough` M3435 | ownership M1330, M2191; emit M2678, M2743, M2833, M2909 | **not a lend.** It is the reverse: the value read out of a view. Keep it separate. |

### Design

**Where it lives.** `sema.zig` gets a pure function on types. The rule depends on the type only, never on the source form (Core §9).

```zig
pub const LendStep = enum { same, elems, text, unbox, handle, optional, narrow, callable };
pub const Lend = struct { kind: enum { read, write }, steps: [4]LendStep, len: u2, implicit: bool };

/// How a value of type `from` is lent as `want`, or null. Composes by recursion:
/// Box[Text] -> String = .{unbox, text}; *Vec[T] -> []T = .{handle, elems}.
pub fn lendsAs(ctx: *const SemContext, from: TypeId, want: TypeId, kind: Kind) ?Lend
```

- **Rows.**
  - `same`: `T` → `?T` / `!T`.
  - `elems`:
    - `[N]T` or `Vec[T]` → `[]T`;
    - `![]T` for write;
    - for a `for` source, `[]T` is the expected view.
  - `text`: Text → String; write → `!Text`, which is `same`.
  - `unbox`: `Box[T]` → recurse on `T`, write allowed.
  - `handle`: `*T` → recurse on `T`, read only.
  - `optional`: `X?` → `View?`, recursing on `X`.
  - `narrow`:
    - `!T` → `?T`;
    - `![]T` → `[]T`.
  - `callable`: a function, a closure literal, a stack closure, or `*fun` → `?fun`.
  - **Lift.** Where `View?` is expected and a non-optional `X` lends `View`, lift it. This covers Text → `String?` today.
- **Record.** `ctx.recordLend(node, Lend)`, keyed like the other facts. This **replaces** six facts: `array_views` (borrowed), `views` (readsAsView), `unboxed`, `callables`, the branch's `text_lends`, and the branch's Text reuse of `array_views`. `arrayViewOf(.temporary)` folds into the temporaries fact (`dropsTemp`) once §3 lands.
- **typecheck.** One call in `checkExpr`, after `synthExpr`:
  - `if (lendsAs(actual_or_inner, expected, kind)) |l| return recordLend(e, l)`.
  - If `e` is `?x` or `!x`, `actual` is its operand's type with `implicit = false`.
  - If `e` is a bare place with a read lend, `implicit = true` (sentence 1). A bare write lend is rejected with "write `!x`".
  - It replaces `arrayAsSlice`'s lending branches, `textAsString`, `boxLent`, `lendCallable`'s lend part, and `recordReadView`. On the branch that is about 120 lines (45 + 32 + 18 + 28, plus parts).
  - The same function serves the `for` source (expected `[]T` or String), the `match` subject (expected `?E`), and the `?self` receiver (expected `?T` / `!T`). That fixes A4 (`x08b`, `x09`, `m03`, `m05`, `x03`, `x05b`) with no extra rules.
- **ownership.** It needs only `lendOf(node) -> ?{kind, root}`:
  - Walk the lent place as `walkBorrow(place, kind)`, where `kind` is already downgraded by `narrow`.
  - For `callable`, call `lendClosure`.
  - The loan root is the same var for every step: a handle, a box, a Vec, and an optional all loan their own binding. So no new loan logic is needed.
  - This replaces `isArrayView`, `readsAsView`, and `lentCallable`, plus the `e.isKind(.read)` checks at `walkMatch` M3205 and `walkFor` M3384.
- **emit.** `emitLend(node, lend)` folds the steps from the inside out:

  | Step | Emitted Zig |
  |---|---|
  | `same` | `&x` (today's `emitAddressOf`) |
  | `elems` (array) | `&a`, which Zig coerces from `*[N]T` to `[]T` |
  | `elems` (Vec) | `v.items()` (runtime M783) |
  | `text` | the existing `.bytes()` path |
  | `unbox` | `emitUnboxed` |
  | `handle` | `&h.value` (`RcBox.value`, runtime M288) |
  | `optional` | `(if (o) \|*p\| <inner(p)> else null)` |
  | `narrow` | nothing, since Zig coerces `[]T` to `[]const T` |
  | `callable` | `emitLentCallable` |

  The work is about 60 lines, replacing the branches at M2741–2743, M2965, M3079, M4405–4439, and B2760.
- **Size.** M overall: S for typecheck, S for ownership, M for emit, because of the optional and handle steps. Net about −80 lines on the branch, since six recorders and six readers collapse into one of each.

---

## 6. Item 3: temporaries, branch versus Core §3 (design F)

| Branch mechanism | Lines (branch) | Core §3 / F | Action |
|---|---|---|---|
| `handsOverFresh` | B3517–3547 (31) | Freshness is never asked of a compound form | **Delete.** Replace with `readLeaf` (item 4), which passes the read through inline `if`, `??`, `catch`, `e!` and `e?`. |
| `rejectNotFresh` | B3508–3515 (8) | Reading never moves a name | **Delete.** Its 8+4+1 errors become reads. |
| `readTemp`, `synthReadTemp`, `lendTemp` | B3498–3506, B3549–3563 (~25) | The core rule | **Keep**, rewritten on `readLeaf`. |
| `through_temp`, `synthPath`, `checkPartOfTemp` | B121–123, B3587–3623 (~35) | A part of a temporary that is taken is rejected in one check | **Delete.** Reading a part goes through `readLeaf`. In the take path, an owning part of a made value is rejected once. |
| `??` `takes_whole` | B3001–3021 (~20) | Remove | **Delete.** In a read, `??` passes the read through. In a take, each operand must hand over an owner, which ownership's `checkNoImplicitCopy` already checks by recursing through `??`. `q13` stays accepted. |
| `rejectResourceTemporary` at receivers | B6229, 6237, 6276, 6306 | A `?self` receiver is a read site | **Change** to `readLeaf`. A `!self` call on a temporary stays rejected with "the change would be lost". |
| `recordTempDrop`, `dropsTemp` | sema B1401–1409 | Core | **Keep.** |
| `holdTemp`, `dropStmtTemps`, `stmt_drops`, `reportTempOutlived` | B1325–1365, B395, B750 (~55) | Core (design B inside the checker) | **Keep.** Drop the `at` parameter if only the loop used it. |
| Header extension: `walkIfBinding` / `walkConditionParts` outside `walkStmtValue` | B3316–3360 | Headers are statements | **Change.** Walk each `if` / `while` condition, guard, and `match` / `for` subject through `walkStmtValue` (about +15). |
| If-join check in `capture`, `isStmtTemp` | B905–916, B743–748 (~12) | Not needed once headers are statements | **Delete.** |
| `while` per-pass drops in `loopIteration` | B3684–3701 (~5) | Headers are statements | **Delete.** |
| Hidden variable for the `match` subject | B3416–3420 (5) | A made subject is taken (`match <e`) | **Delete.** In typecheck `checkMatch` B1781, a made subject in read mode is checked as `.consume`. |
| emit `TempSlot.resets`, the `while` branch of `emitTempSlots`, the `__rig_reset_N` label | B107–109, B1065–1076, B2779–2786 (~25) | Remove | **Delete.** |
| runtime `keep`'s "drop a value still live from an earlier pass" | runtime B173 (1) | Remove | **Delete** the line. Keep `keep`. |
| `emitTempSlots`, `writeTempDrop`, `tempSlot`, `hasTemps`, the slots for value bodies and block tails | B1023–1099, B3809 (~70) | Keep: flags are needed under `and` / `or` / `?:` / `??` / `catch` and on failure | **Keep.** **Add** a labeled block per header that owns its slots: `if (c: { slots; const v = cond; drops; break :c v; }) \|x\|`, the same for `while`, guards, and `match` / `for` subjects (about +35). Check `?? continue` inside a `while` header block. |
| main `lent_borrow` (header extension for plain borrowed temporaries) | M `checkOptionalBinding` 1459–1462, `checkMatch` 1783–1786, `synthBorrow` 3223 | Headers are statements | The branch already deleted it. Landing removes it from main. |

**Tests that change.** Paths are on the branch unless marked "main".

- **Becomes accepted behavior:**
  - `reject/ownership/not_fresh_owner_read.rig` (8 errors);
  - `reject/ownership/temporary_branch_names_owner.rig` (4);
  - `reject/ownership/fallback_bare_owner.rig`;
  - `reject/types/fallback_not_fresh.rig`;
  - `reject/ownership/temporary_match_moves_payload.rig` (the move is now allowed);
  - SPEC §7's reject example for `make().count()`.
- **Rewritten to bind first:**
  - `behavior/ownership/temporary_views_in_statement.rig` (lines 26, 29);
  - `behavior/ownership/temporary_field_read.rig` (`for n in ?mv()` at line 25 becomes `mv()`);
  - main's `behavior/ownership/borrowed_temporary_lives_for_statement.rig` (`if ?opt(3) as p`, `while ?opt(0) as q`, `match ?e(5)`, `for x in ?[..]` become taking forms);
  - `behavior/ownership/temporaries_read_then_dropped.rig` and `temporaries_drop_order.rig` (the `while` per-pass expectations change, because drops now happen before the body).
- **Reject tests whose header errors come from the new rule, keeping their lines:**
  - `if_header_view_escapes.rig` (5);
  - `if_value_header_view_escapes.rig` (4);
  - `while_header_view_one_error.rig` (2);
  - `temporary_views_kept.rig` (21:19);
  - `temporaries_not_kept.rig` (25);
  - `temporary_match_view_escapes.rig`.
- **New behavior tests:**
  - `q06` and `q07` (the condition's temporary is dropped before the body);
  - `q04` (`mk().get()`);
  - `q01`, `q02`, `q03` (reads of names through compound forms);
  - `s01`, `s03` (made versus place `for` sources).
- **Docs:**
  - SPEC §7 "Temporaries" (blocks at about B3118, 3139, 3168, 3186);
  - SPEC §10 Text;
  - WELCOME (its one example stays valid);
  - INTERNALS `dropsTemp` (B631–637, 706).
- **Corpus.** It does not assert acceptance. Corpus probes that use header borrows (`review-box-p77`, `fix-r2`, `review-sc4-sf_y`/`sf_z`, `p-forms`, `review-revamp-checkers-p-t3`/`t6`/`t7`, `review-text3-b6`) just become rejections with diagnostics, which the corpus allows.

**Expected net lines.**

| Area | Removed | Added | Net |
|---|---|---|---|
| typecheck | ~120 | ~45 | ≈ −75 |
| ownership | ~25 | ~15 | ≈ −10 |
| emit + runtime | ~26 | ~35 | ≈ +10 |
| **Source total** | | | **≈ −75 (range −60 to −100)** |
| Tests | | | roughly balanced: 6 reject files become behavior files |

The source total sits on top of landing the branch's core (+250), so landing F from main is about +175.

---

## 7. Item 4: one "what this expression hands over" classifier

### Today

| Classifier | Where | It calls a place | It calls fresh | Disagreement |
|---|---|---|---|---|
| `isPlaceExpr` | typecheck M8062 / B8315 | any leaf (**literals too**), `member`, `index`, `?x`, `!x` | everything else, including `a if c else b`, `o?`, blocks | It calls a literal a place, and a ternary over names a temporary |
| emit `isPlace` | emit M5525 / B5647 | the same as `isPlaceExpr` | the same | It emits a **consuming loop** for any non-place Vec, which causes `s01` and `s03` on the branch |
| `makesValue` | typecheck M8053 (main only) | — | `call`, and `call!` / `call?` | Narrower than `handsOverFresh` |
| `handsOverFresh` | branch B3524 | a name, `member`, `index`, `?x`, `!x`, `~x`, `lambda`, `builtin` | `call`, `*x`, `+x`, `<x`, literals, arrays, jumps; recurses through `if`, `match`, block, `??`, `catch`, `e!`, `e?` | It says `~x` is not fresh; `isTemporary` calls literals fresh |
| `isTemporary` | typecheck M3255 | `placeOf` base: a symbol, or a borrow-typed list | any other base | — |
| `placeOf` / `placeRoot` / `lentPlace` / `unborrowedNode` | typecheck M1058 / M7872 / M7865 / M7859 | path utilities: they find the root, and differ on peeling `<` | — | `placeRoot` peels `<`; `lentPlace` does not |
| `resolvePlace` | ownership M1590 | a name that is a tracked var, `member`, `index` (**not** `?x`) | — | It treats `?x` as not a place, while `isPlaceExpr` treats it as one |
| `checkNoImplicitCopy` / `movedTail` | ownership M2102 / M1840 | `.src`, `member`, `index`; recurses through branches | **everything else, including `?x`, `!x`, `~x`, `lambda`, `builtin`** | It calls `?x` fresh, while `handsOverFresh` calls it not fresh |
| `consumedTemporary`, `hoistReceiver`, `evalSubject` | emit M4251, M4318, M2270 | `isPlace` | the rest | — |
| `isValueExpr` (ownership) / `isValueStmt` (emit) | M4012 / M5573 | — | — | They disagree on whether a block or an else-less `if` is a value |

### Design

**Facts.** Typecheck computes a fact once per expression it synthesizes in a value position:

```zig
pub const Hands = union(enum) {
    place: Root,       // a name or a member/index path of one; Root = symbol + whether the path passes through a borrow
    part_of_made,      // a member/index path whose base is .made (mk().v[0])
    made,              // call, constructor, Text(...), +x, *x, <x, a literal, an array literal, a block value, a match value
    lend: Lend,        // ?x, !x, or an implicit lend (§5); it hands over a loan on Root
    view,              // a value of view type (a ?T / []T / String name): a copy carries its loans
    branches,          // inline if, ??, catch, e!, e?: the leaves decide
    jump,              // return / break / continue
};
pub fn handsOver(ctx, node) Hands
```

- **Leaves.** It is decided by node kind and symbol, in typecheck, where names are resolved (so a literal is never a place). It is stored as `sema.facts.hands`.
- **Rule for compound forms.** `branches` never decides anything itself. A consumer recurses, using `ir` accessors for the operands.

**Consumers, each by name.**

| Today | Becomes |
|---|---|
| `readTemp` / `lendTemp` / `rejectResourceTemporary` / `rejectNotFresh` / `handsOverFresh` / `synthPath` / `checkPartOfTemp` | `readLeaf(e)`: `.made` records a temporary drop if `ownsResource`; `.place`, `.view`, `.lend` do nothing; `.part_of_made` calls `readLeaf(base)`; `.branches` recurses |
| `checkNoImplicitCopy` / `movedTail` / `takes_whole` / `makesValue` (taking) | `takeLeaf(e, sink)`: `.made` is fine; `.place` with an owning type gets `reportAlias` (the tail-move exception, if kept, keys on `sink == .ret` here); `.part_of_made` with an owning part is rejected; `.lend` is fine; `.branches` recurses |
| `checkFor` M1570/M1577, emit `emitFor` M1997 | `.place` / `.view` lends the source (`lendsAs` `[]T`); `.made` takes it (a consuming loop); `.branches` means a read of each leaf, emitted as a pointer per branch (made leaves go in temp slots through `rig.keep`, which already returns a pointer) |
| `checkMatch` mode, ownership `walkMatch` `lent`, emit `evalSubject` | `.made` → consume; `.place` → read lend; `.lend` → as written |
| `checkOptionalBinding` | the same as `match` |
| emit `isPlace`, `consumedTemporary`, `hoistReceiver`, `isVariantDiscard` | `handsOver(e) == .place` or `.made` |
| ownership `resolvePlace` | stays a **path resolver** (root and steps), called only after `handsOver` says `.place` or `.lend` |
| `placeOf` / `placeRoot` / `lentPlace` / `unborrowedNode` | one `pathOf(e) -> {root, steps, through_borrow}`; `<` is peeled only by the move walker |
| `isValueExpr` / `isValueStmt` | one `yieldsValue` in sema (separate axis; fix the disagreement while here) |

**What it fixes.**
- Disagreements 1–9 in the classifier inventory.
- The branch's `s01` and `s03`.
- The "not a fresh value" errors.
- The `?(a if c else b)` rejection (`g03`).

**Size.** M: about 120 lines added, about 200 removed across the three passes. Do it **before** §3's migration, because §3's `readLeaf` and `takeLeaf` are its first two consumers.

---

## 8. Recommended order (the Step column)

1. **Decisions and doc fixes.**
   - The tail-move rule (open decision).
   - Captures are written.
   - SPEC §6's array wording.
   - The Core's status corrections in §2.
2. **Implicit read lends** (sentence 1), on today's conversions. Small, and it changes no accepted program.
3. **`lendsAs`** (§5): Vec, `*T`, `X?`, composition, Box members of every type, the callable alias fix.
4. **The `handsOver` classifier** (§7), then **§3 / design F** on top of it, as the strings branch lands. Main's 871857f7 check is subsumed by `handsOver`.
