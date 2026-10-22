# Core audit: containers, assignment, and the standard library

Auditor dimension: Core §5 (containers hold anything), §6 (assignment),
open decision 4, and every std API checked against the Core.

- Code: main `dd36c78`; the strings branch `rig-text` at `59e7bed8` (`text-core`).
- Probes: `probes/containers/*.rig` (main) and `probes/containers/branch/*.rig`
  (rig-text). Every probe that compiles was run with `RIG_SANITIZE=1 bin/rig run`.
  Probe names are cited in the tables, for example `(v04)`.

---

## 1. Gap table

Status values come from the Core. "Actual" is what the probe shows. The
step numbers point to the plan in §4.

| # | Core rule | Core says | Actual (probe) | Gap | Code location | Fix | Step |
|---|---|---|---|---|---|---|---|
| 1 | §5 `Vec` holds any type | decided | Accepts Copy, plain, `*T`, `~T` and `Box[T]`. Rejects `Vec[Vec[Int]]` (v01), a struct with an owning field (v02), a struct with `drop` (v03), `Box[P]?` (h05), `?Int` (v05), `[]Int` (v06), `Vec[Text]` (branch t01), a struct holding `Text` (t05), and `Vec[random.Rng]` (l04). The branch accepts `Vec[String]` holding views and carries their loans (t04, x09). | Owners, optional owners and views other than String are rejected | `src/resolve.zig:2114-2121` (`builtinElementError`) | S | 1 |
| 2 | §5 arrays hold any type | decided | Any element with drop glue is rejected: Box (a01), Vec (a02), `*P` (a03), a drop struct (a05), Text (t06), Rng (l03). Read and write views work (a07, a08, a09). A struct holding a Cell works through indexing (c03). | Arrays are stricter than Vec: even handles and boxes are rejected | `src/resolve.zig:639-642` (declared); `src/typecheck.zig:4325-4328` (literal) | S–M | 1 |
| 3 | §5 `![]T` / `[]T` of any type | decided | `![]Box[P]` and `![]*P` are rejected (s01, s02). Slicing `Vec[*P]` or `Vec[Box[Text]]` is rejected (s02, t03). | No slice of an owning element exists | `src/resolve.zig:656-659`; `src/typecheck.zig:4211-4218` (`vecSliceElem`) | S | 2 |
| 4 | §5 `v[i]` reads in place | decided | Works for plain elements (p01). For an owning element, every read is rejected, even `v[0].x` or `print(v[0])` (v04, h01, t02). | The check rejects the index before the place machinery runs | `src/typecheck.zig:4194-4198` (`indexInto`) | S | 1 |
| 5 | §5 `?v[i]`, `!v[i]` lend the element | decided | Works for plain elements (p01: `get(?v[0])`, `bump(!v[1])`). Rejected for owners (h02, v04). | Same site as row 4 | `src/typecheck.zig:4194` | S | 1 |
| 6 | §5 `<v[i]` takes an optional element | decided | Works for a plain optional (p03 prints `3 [none]`). An optional owner cannot be stored at all (h05). Ownership already takes from optional places (`walkTake`, `src/ownership.zig:1820-1834`). | Blocked only by admission | row 1 | S | 1 |
| 7 | `+v[i]` clones a handle element | built (sentence 2) | `+v[0]` on `Vec[*P]` is rejected (h04). | Same site as row 4 | `src/typecheck.zig:4194` | S | 1 |
| 8 | Element assignment of an owner drops the old value | implied by §5 ("each element is a place") | Rejected: "cannot replace an element … the old handle would leak". A field of the same type works and drops the old value (f03 prints `drop 1` at the assignment). | The emitter already writes `rig.drop(slot); slot.* = new` for any place (`src/emit.zig:1274-1281`); only the check blocks it | `src/typecheck.zig:884-887` | S | 1 |
| 9 | §5 `swap` works for any element type | decided | Works on `Vec[*P]` (h03). Impossible for arrays and slices of owners (a04, s01), because they cannot be admitted. | Blocked only by admission | rows 2–3 | — | 1–2 |
| 10 | §5 sorting works for any element type | decided | `sort.sort(!v)` on a `Vec` is rejected ("expected `[]T`, got `Vec[Int]`", p02); `!v[..]` is required. `!v[..]` of `Vec[Box[Text]]` is rejected (t03). `Text` has no `<` (branch x04), so `sort.sort` on Texts cannot work even after §5. | Missing §4 Vec lend, missing slices of owners, missing `<` on Text | §4 lend; row 3; the branch's `<` operand check | S each | 2, 7 |
| 11 | §5 `for` over elements gives places | built for Vec | `for x in ?v`, `!v` and `<v` work for `Vec[*P]` and `Vec[Box[P]]` (h03, h06, h07). For an array of plain structs holding a Cell, `for x in ?a` binds a **copy**, and `x.hit()` is rejected (c02). | Array and slice loops copy where §5 says they lend | `src/typecheck.zig:6092`, `3214`, `7741` (loop-copy diagnostics); the ownership for-spec at `src/ownership.zig:3364-3380`, `3854` | M | 4 |
| 12 | push / insert / remove / pop / clear | built | Work for every admitted type (p01, h03). The runtime `Vec` is generic and already drops elements in `clear`, `__rig_drop` and `IntoIter.deinit` (`src/runtime.zig:762-905`). | None in the runtime | — | — | — |
| 13 | `v.get(i)` | the Core says nothing | Copy-out only; rejected for owners (`src/typecheck.zig:6111-6116`; `sequenceGet` at `6346-6369`; Cell `vecGet`). | The Core should say what `get` gives for a non-copyable element (see §3, correction 3) | three `get` implementations | S | 4 |
| 14 | `Vec[Text]` "just works"; the workaround is `Vec[Box[Text]]` | decided | The workaround is weaker than the Core implies. `Box[Text]` reaches no Text methods (`!b.add` is rejected, t07, x08). Elements of a `Vec[Box[Text]]` cannot be indexed (t02), sliced or sorted (t03). Only `for` over it works (x05). | §4 Box composition (methods), plus rows 1–5 | the Box member lookup in `typecheck.zig` (the "reaches no methods" diagnostic) | S | 7 |
| 15 | §6 RHS-first, then indexes outside in, then store | **branch (safety-net, PR #31)** | **Built on main** (PR #31 merged as `dd36c78`). Holds for every target shape probed (o01, o02): local, compound local, field, field array, array, nested `m[i][j]`, Box field, Box field-array compound, through a `!T` parameter, `![]T` element and compound, `Vec` element field array, Cell[Vec] `c[i] = v`, `self.v[i]`, `self.x +=`, `!Vec` parameter element, an `if !o as q` binding, a `match !e` payload, and a compound assignment through a local `!Vec`. A target whose root the RHS moves is rejected (o03). | Status in the Core is stale | — | — | — |
| 16 | §6 assigning a borrow re-points a local | open (decision 4) | `w = !m` on a local `!T` is rejected and the hint is `new w = !n` (b01, b11). | Local and field disagree | `src/typecheck.zig:720-726` | S | 5 |
| 17 | §6 `w = <w2` (moving a write borrow) | open (decision 4) | **Local: silently writes through.** b17 prints `5 2` and emits `w.* = (w2).*`, so the `<` is accepted and ignored. For a non-Copy inner type it is a type mismatch (b24). **Field: re-points** (b21 prints `1 6`). | Inconsistent, and the local form drops the move silently (AGENTS rule 2) | `src/typecheck.zig:747-756` (sets `declared = inner`); `src/ownership.zig:2373-2389` (`reassign` keys on `v.ref == .write`); `src/emit.zig:1117` (`rebound`) | S | 5 |
| 18 | §6 a bare write-borrow name on the RHS | open | Local `w = w2` writes through (b23). Field `self.w = to` is rejected with "bare use of write borrow … use `<to`" (b13). | Inconsistent | `src/typecheck.zig:870-872` (field mode keyed on the RHS type `borrow_write`); `src/ownership.zig:2152` | S | 5 |
| 19 | §6 a read-borrow place | open | Local and field `r = ?b` re-point (b03, b04). `r = 5` is a type mismatch (b18, b22). | Consistent today | — | — | — |
| 20 | §6 a `![]T` place | open | A local `![N]T` is treated as `!T`: `s = !b` is rejected (b15). A `![]T` parameter: "cannot assign … write its elements" (b19). A field `h.s = !b` re-points (b20). | A slice local cannot re-point; a field can | `src/typecheck.zig:713-718` | S | 5 |
| 21 | §6 parameters | — | A `?T` parameter `r = other` is rejected as immutable (b08). A `!T` parameter `w = v` writes through (b07). | The Core says "locals and fields alike" and is silent on parameters, which stay immutable | — | doc | 5 |
| 22 | §6 "`new` … accepts every binding form" | open | Only `new x = e` parses. `new x: T = e` and `new x =! e` are parse errors (b06, b06b). The grammar's `op` role holds one value (`shadow` or `fixed`), so `new x =! e` needs a schema change. | Grammar | `rig.grammar:434` | S (but depends on decision 5) | 5 |
| 23 | §8 fact: "lives for the whole program" | decided | On main every String is static, so nothing breaks. On the branch, `os.env(?name)` ties the result to the Text `name` (x01: "cannot write-borrow `name` while a read borrow is live"), though the env value lives for the whole program. Sentence 7 derives the loans, and no extern can declare otherwise. | False rejection; nothing in the language can state the fact | `std/os.rig` `env`; the extern signature handling | S | 8 |
| 24 | §1 the move-only plain type (decision 1) | open | `Rng`'s empty `drop` makes it unstorable in `Vec` or arrays (l03, l04). A struct holding one cannot be copied (l05, correct). | The workaround costs container admission today | `std/random.rig:8-12` | S with decision 1 | 1 (admission) or decision 1 |

Tests that assert the rejections in rows 1–8 and 16, all of which flip:
`test/reject/types/{vec_index_resource, array_of_resources, array_of_resources_declared_later, slice_element_owning, slice_vec_of_resources, vec_bad_element, generic_vec_element_per_instance, generic_inference_checks}.rig`,
`test/reject/ownership/{slice_resource_vec, repoint_local_write_borrow}.rig`,
`test/reject/modules/foreign_builtin_element/main.rig`, and the SPEC §2/§10 Vec,
array and slice text ("Elements are Copy primitives … or boxes"; "arrays cannot
hold …").

---

## 2. Standard-library conformance

"Changes when the Core lands" marks a signature or doc that will break or
churn. Those changes should land before more modules copy the pattern.

| Module / API | Follows the Core? | Workaround the Core removes | Changes when the Core lands? |
|---|---|---|---|
| `math.abs/min/max/clamp[T](x: T…) -> T` | Yes, for plain `T` and for String views. | — | No. For owners, call with views (`math.min(?a, ?b)`). Check that `T` infers to `String` from `?text`: §4's "the view the context expects" has no expectation in a generic argument. |
| `math.gcd/pow/mod`, `PI`, `E` | Yes | — | No |
| `math` externs (`sqrt` … `powf`, `clamp_bounds`) | Yes (scalars) | — | No |
| `os.args() -> []String` | Yes. Lent nothing, so sentence 7 makes its result static. | — | No |
| `os.env(name: String) -> String?` | **No, on the branch.** The result borrows `name` (x01). | — | Needs a way to declare a program-lived result (design D). Otherwise the signature becomes `-> Text?`, which copies. |
| `time.now`, `Instant.since/elapsed(?self)`, `sleep`, `unix_ns`, constants | Yes | — | No |
| `random.Rng` with `drop(!self) pass` | No (decision 1) | The empty `drop` that fakes ownership | Yes: becomes `struct Rng unique` (or the chosen word). Every admission predicate keyed on "drop glue" (Vec, array and Cell in `resolve.zig:2104-2129`, `639-659`) must move to the §8 facts at the same time, or `Cell[Rng]` breaks. Cell today accepts it only because of the glue. |
| `Rng.seeded/new`, `!r.next/fork/int/float` | Yes. (`Rng.new` uses the `new` keyword as a member name; it parses.) | — | No |
| `!r.shuffle[T](!self, xs: ![]T)` | Yes. Works for owners once slices of owners exist. | Docs say `!r.shuffle(!v[..])`; l06 shows `!v` is rejected | Doc only (§4) |
| `sort.sort[T](xs: ![]T)` | Signature yes | `!v[..]` for a Vec (p02); "elements are plain data, as a slice's are" in STD.md | Signature no. Docs and comments change (§4, §5). `T` needs `<`: add `<` on Text, or Vec[Text] users must use `sort_by`. |
| `sort.sort_by[T](xs: ![]T, less: ?fun(?T, ?T) -> Bool)` | Yes. The body only lends (`?xs[j]`) and swaps, so it works for owners unchanged. | `!v[..]` | No |
| `sort.lower_bound[T](xs: []T, x: T) -> Int`, `sort.search[T](xs: []T, x: T) -> Int?` | **No, for owners.** `x: T` takes ownership of the probe value. | — | **Yes.** Change to `x: ?T`, or better a second parameter (`[T, K](xs: []T, x: K)`, using `<` and `==` between `T` and `K`). The second form lets `Vec[Text]` be searched with a String literal. Wait for sentence 1 ("a read lend may go unwritten"): today `search(?a, 2)` against `x: ?T` is a type mismatch (g01). |
| `slices.reverse[T](xs: ![]T)` | Yes | `!v[..]` | Doc only |
| `slices.contains/index_of[T](xs: []T, x: T)` | **No, for owners** (same as `search`) | `?v[..]` | **Yes**, same change as `search` |
| `slices` and `sort` header comments ("pass a Vec as `!v[..]`") | — | §4 | Doc only |
| `text.*` (branch): `contains`, `starts_with`, `trim*`, `strip_*`, `cut`, `find*`, `count`, `parse_*`, `compare`, byte helpers | Yes. String is the view, and sentence 7 gives every returned view the right loans. String-only signatures are right under §4: a Text caller writes `?t`, and bare `t` after sentence 1. | — | No |
| `text.Split/Lines/Words.next(!self) -> String?` | Yes. Views in a struct carry loans. | `find(…) ?? -1` followed by `if at < 0` is an avoidable sentinel; `if text.find(…) as at` already works on the branch (x10) | Style only |
| `text.parse_bool(s) -> Bool!` | **No, under decision 3.** Its last line is the bare `ParseError.invalid`. | — | **Yes:** `return ParseError.invalid` |
| `text` externs | Yes. They return scalars, so nothing needs the program-lived fact. | — | No |
| `extern zig` in general | Results follow sentence 7: a view result borrows every view argument. That is conservative and sound. | — | One std-only marker, for program-lived results (design D) |

Element methods and Cell forwarding (task item 4):

| Member | Is it a case of the Core's containers rule? |
|---|---|
| `!xs.swap(i, j)` | **Subsumed.** It is the only way to write two elements of one collection: `swap(!v[i], !v[j])` is rejected on purpose (`src/ownership.zig:2704-2710`), because indexes may alias. §5 removes its element restriction, which already exempts swap (`op != .swap`). Keep it as the method form. |
| `!xs.copy(src)`, `!xs.fill(v)`, `[n of x]` | **Not subsumed. They stay plain-only.** They duplicate values. For owners that would be a hidden `+` per element, which sentences 1–2 forbid. State this in the Core as a consequence: "a form that duplicates takes only copyable elements". |
| `xs.read[T, e](at)`, `!xs.write[T, e](at, v)` | Not about ownership; byte encoding. Out of scope. |
| `v.get(i)`, `xs.get(i)`, Cell `c.get(i)` | **Partly subsumed.** For copyable elements, `get` is `v[i]` returned as an optional. For other elements the lend table's `X? → View?` row gives `?T?`. Merge the three implementations into one, keyed on the copyable fact. |
| Cell[Vec] `push`, `pop`, `clear`, `len`, `c[i]`, `c[i] = x`, `c.get(i)` | **Not subsumed.** This is a Cell rule (sentence 9), not a containers rule. A Cell's value can never be lent, so §5's "element is a place" does not reach into a Cell. These members are exactly the Vec operations that lend nothing out and run no user code while the Vec is in use. The Core should say it in one line under sentence 9: "Through a Cell, a Vec offers the operations that lend nothing and run no user code while it is in use." Then `c[i] = x` of an owner (store, then drop the old value, as `Cell.set` does) follows too, and today it is rejected. |

---

## 3. Corrections to the Core

1. **§6 status.** "branch (safety-net, PR #31)" is now **built**: merged on main as `dd36c78`. Every target shape probed follows it (gap row 15).
2. **§5 understates today's restriction.** Arrays and `[]T` reject *every* owner, including handles and boxes, so they are stricter than Vec. Vec rejects views (`?T`, `[]T`), while arrays accept them, write views included (a07–a09). The `Vec[Box[Text]]` workaround cannot be indexed, sliced or sorted, and the box reaches no Text methods. "Today `Vec[Text]` is rejected" should read: "today containers hold owners only in a Vec, only as handles or boxes, and only walked with `for`."
3. **§5 should state the consequences it implies.**
   - A form that duplicates (`copy`, `fill`, `[n of x]`, `get`'s copy-out) takes only copyable elements.
   - `v.get(i)` gives `?T?` for a non-copyable element.
   - `sort` needs `<`, and `sort_by` works for any type. So "sorting works for any element type" means `sort_by`. Either add `<` to Text, or say so.
   - `for x in ?a` over an array or slice binds a view, not a copy (c02 today).
4. **§5 depends on §4 in both directions.** `?v` → `[]T` for `Vec[Text]` needs slices of owners (§5), and `sort.sort(!v)` needs the §4 Vec row. Land them together. Add a row to the lend table: an element place `v[i]` lends as its type does, so `?v[i]` of a `Vec[Text]` lends a String.
5. **§6 must define "a borrow" versus "a value" by sentences 1 and 4**, or decision 4 stays ambiguous for bare names. Proposed wording is in design B. In short: on a `!T` place, `!e` and `<w` re-point, and a bare name (sentence 1: it only reads) writes through. On a `?T` place every assignment re-points, because there is nothing to write through.
6. **§6 "locals and fields alike"** should add: **parameters stay immutable** (SPEC §4). Only writing through a `!T` parameter is allowed, so a parameter is never re-pointed.
7. **§6 "`new` … accepts every binding form"** is not true today (gap row 22), and `new x =! e` depends on decision 5. Suggest "`new` only shadows; it takes `new x = e` and `new x: T = e`". Add the fixed form once decision 5 settles the spelling.
8. **§8 "lives for the whole program (literals, `os.args`)"** should also list `os.env`. The Core should say how a Zig-backed declaration states the fact (design D). Today sentence 7 alone decides it, which over-borrows for `env` (x01).
9. **Admission predicates should be stated in the §8 facts, not "drop glue".** Vec, array and slice: any type (a borrowed callable aside). Cell: "may hold a borrow" is false. Signal: copyable, and no borrow. Box: no borrow. `Cell.get`, `get` and copy: copyable. Otherwise decision 1 (`unique`) silently changes what Cell, Vec and arrays accept: today `Cell[Rng]` is accepted only because of the fake `drop`.
10. **Sentence 1 versus `if t as d`.** A bare optional owner in an `if … as` header is rejected ("would alias an owning value", seen while writing f03); sentence 1 says it should read. This is outside this dimension and is passed to the §2/§3 auditor.

---

## 4. Designs

### A. Making §5 true: every element is a place

**Main observation.** Fields already behave exactly as §5 wants elements
to (f03). `h.d.n` reads in place, `?h.d` lends, `h.d = D(…)` drops the old
value, `<h.o` takes an optional, and `x = h.d` is rejected with "a field
cannot be moved out of its parent". The ownership checker already treats
`index` like `member` (`Place.indexed`, `movePath`, `walkTake`,
`movedTail`), and loans are per root variable. The emitter already
emits Vec element places (`slot`, `constSlot`) and owning-place
assignment. The runtime `Vec` is generic and drops elements. Most of §5
is therefore **removing type-check rejections that run before this
machinery**.

**Loans per element path: not needed for soundness.** A loan on `v[i]`
is recorded on the root `v`, as `?h.d` is on `h`. That is sound and
also necessary. Any element loan must conflict with every write of `v`:
`push` reallocates, `v[j] = x` may hit `i`, and `clear` frees. Indexes are
dynamic, so two element paths of one collection can never be proved
disjoint. Recording the path is only useful for diagnostics ("`v[…]` is
borrowed here"). It is not worth a loan-model change. The ownership
checker would gain nothing from per-path loans for elements. Per-path
loans for *fields* (disjoint `?p.a` / `!p.b`) are a separate
precision improvement, not part of §5.

**Steps (the "step" column in §1):**

1. **Admission, and the element as a place** (rows 1, 2, 4–8, 12, 24). S–M.
   - `resolve.zig:2114-2121`: Vec accepts any `T` except a borrowed callable, which `heldCallable` already reports.
   - `resolve.zig:639-642` and `typecheck.zig:4325-4328`: arrays accept owners.
   - `typecheck.zig:4194-4198`: drop the rejection and return `elem`. The consuming-position check in ownership (`src/ownership.zig:2244-2254`, "bare use … would alias an owning value") already covers index places, as it does fields.
   - `typecheck.zig:884-887`: allow assigning an owning element. `emitPlaceAssign` already drops, then stores.
   - Emit: read an owning, or Cell-holding, element through `constSlot(i).*` rather than `at(i)`, so a read never makes a bit-copy that a `?self` method could mutate. Read and write lends already go through `emitBorrowOf` with `read_place`.
   - Arrays of owners: `kindOf` gives `.value`, so scope exit calls `rig.drop(&a)`, and `dropElement`'s `.array` case drops each element. An array literal of owners takes each element (`walkConsumed(e, .element)` already exists). `for x in <a` needs an array into-iterator in the runtime (small).
2. **Slices of owners, plus the §4 Vec lend** (rows 3, 9, 10). S. Covers `resolve.zig:656-659` and `typecheck.zig:4211-4218` (`vecSliceElem`), then `?v` → `[]T` and `!v` → `![]T`. Generic bodies over `[]T` (`sort`, `slices`) already register a `.plain` requirement wherever they copy a `T` (`ownsResource` → `generic_requirements`; ownership `requirePlain`). `sort_by` and `reverse` only lend and swap, so they instantiate with owners unchanged. Then delete `[..]` from the std docs and comments.
3. **Views in a Vec** (row 1: `Vec[?T]`, `Vec[[]T]`, and `Vec[!T]`). S–M. Generalize the branch's Vec[String] loan carriage: the Vec variable's flow holds the union of the loans of everything pushed (`mayCarryBorrow(Vec[?T])` becomes true). Write views are unique: each `!x` pushed keeps `x` write-loaned until the Vec's last use, which is the same model arrays of write views already use (a09).
4. **Loops and `get`** (rows 11, 13). M. A `for x in ?a` / `?xs` over an array or slice binds a view of the slot, as the Vec owner loop does (`loop_borrow` / `elem_view` in the for-spec, `src/ownership.zig:3364-3380`), instead of a copy. This retires the three "loop binding is a copy" diagnostics for Cell-holding elements (`typecheck.zig:3214`, `6092`, `7741`). Unify `Vec.get`, `sequenceGet` and Cell `vecGet` into one rule: a copyable `T` returns `T?`, anything else returns `?T?`.

**Runtime:** no new Vec code is needed. `insert`, `remove` and `pop` move bits, and no user code runs inside them. An array into-iterator is the only addition.

**Size and risk.** Overall **M**: roughly 150–300 lines of compiler change, plus about 15 reject tests to flip and 20–30 new behavior tests under the sanitizer. **Risk: medium.** This is the centre of the language, but the machinery is reused rather than new. The specific hazards to test:
- (a) generic bodies instantiated with owning `T`, where every copy of `xs[i]` must hit a `.plain` requirement;
- (b) an emitted `at(i)` copy that reaches a consuming position;
- (c) element assignment whose RHS reallocates the Vec. PR #31's order makes it safe; add an owner-element case;
- (d) `Vec[!T]` uniqueness.

**What Map and Set need from it.**
- Map and Set can be written in Rig in std, per AGENTS rule 5, over `Vec[Slot[K, V]?]`. That needs §5's `<v[i]` take-out of an optional owning element, `!v[i]` for in-place update, and owner admission. A root loan on the map makes `insert` (rehash) conflict with every outstanding value view, which is exactly right.
- **Lookup by view.** `Map[Text, V].get("lit")` and `Set[Text].contains(?s)` need the lookup parameter to be the key's read view, which is String for Text. `?K` with `K = Text` is `?Text`, and a literal String is not one. Use the two-parameter generic form (`get[Q](k: Q)` with `==` and `hash` on `K`/`Q`), which Rig's per-instantiation generic checking already supports. Or add a type-level "read view of T" to the lend table. Decide this before std grows `Map`: the same decision fixes `slices.contains` and `sort.search` (§2).
- A hash for any key type: a builtin `hash` over plain values, Strings and Texts, giving equal hashes for equal bytes.

**What `Vec[Text]` needs:** steps 1 and 2, plus `<` on Text (for `sort`) and Box/Text method forwarding (§4 composition). The forwarding matters only while the `Box` workaround is still in use.

### B. Decision 4: one `=` on borrow places (exact change)

**Rule (proposed SPEC §4 text):** "`p = e` where `p` holds a view of type
`V`:
- If `e` is a view of type `V` (written `?x`, `!x` or `<w`; a call
  returning a view; a bare read view, which copies), `p` is pointed at
  what `e` views.
- If `V` is `!T` and `e` is a `T` (a bare name or place of a `!T`
  included, which only reads by sentence 1), the `T` is written through
  `p`. A compound assignment always writes through.
- On a `?T` place a bare `T` place is an unwritten read lend, so it
  re-points. A fresh `T` there is a borrow of a temporary, which §3
  rejects.
- Locals and fields follow this one rule; parameters are immutable and
  only write through."

Changes:
1. **`sema.zig`:** add `AssignMode = enum { store, write_through, repoint }` and `pub fn assignMode(ctx, place_ty, rhs, rhs_ty, compound) AssignMode`. Record it per `set` node, replacing `facts.through_writes` (`sema.zig:630, 1307-1312`) with `facts.assign_modes`. `assignWritesThrough` (`sema.zig:2856`) becomes a call to it.
2. **`typecheck.zig` `checkSet`:**
   - Delete the `w = !m` rejection at 720-726.
   - At 713-718, keep the `![]T` rejection for parameters only, worded as immutability; a `![]T` local may re-point.
   - At 733-735, record `facts.writes` for a re-point, so the emitter makes the local `var`. Set a new symbol flag `repointed`.
   - At 753-756, unwrap `declared` only in `write_through` mode. In `repoint` mode, check the RHS against the borrow type itself.
3. **`typecheck.zig` `checkPlaceAssign` 870-874:** replace the inline `through` computation (which keys on the RHS *type* being `borrow_write`) with `assignMode`. A bare `!T` place on the RHS now writes through, instead of the current re-point attempt that ownership then rejects with "use `<to`" (b13).
4. **`ownership.zig` `reassign` 2373-2389:** branch on the recorded mode, not on `v.ref == .write`. `repoint` → `setFlow(id, .{ .loans = value.loans })`; the old loan ends at its last use, and scope-exit checks keep the new loan in bounds. `write_through` → the existing `storeThroughLocal` path. Also `2152`: in `write_through` mode a bare write borrow on the RHS is a read, not a duplication.
5. **`emit.zig`:**
   - `emitBind` 1117: `rebound = s.flags.repointed` instead of `!assignWritesThrough(ty)`, so the pointer local becomes `var`.
   - `emitRebind`: `repoint` → `w = <emitBorrowValue(rhs)>;`, `write_through` → `w.* = …` (today's behavior).
   - `emitPlaceAssign` 1244 already reads the fact.
6. **Diagnostics and tests.**
   - `test/reject/ownership/repoint_local_write_borrow.rig` becomes an accept test.
   - Add accept tests for b01, b17, b13 and b15 shapes, and reject tests for `r = 5` on `?Int`, for `xs = !b` on a `![]T` parameter, and for `<w` on a `?T` place.
   - Today's silent `w = <w2` write-through (b17) is a standing AGENTS rule 2 bug. Give it a failing test now, whatever the decision.
7. **Docs:** SPEC §4 paragraph 1 and §7 "write borrows"; SYNTAX §9; the `new` hint text.

Size **S–M** (about 80–150 lines). Risk **low–medium**: the emitter's `const`/`var` choice and the ownership loan swap are the parts to test.

### C. The admission facts (prerequisite for decision 1)

Restate `builtinElementError` (`resolve.zig:2104-2129`), the array and slice checks, and `isCopyElement` (`sema.zig:3101`) in the §8 facts: *copyable*, *needs cleanup*, *may hold a borrow*. After A, the only remaining predicates are:
- Cell: no borrow;
- Signal: copyable, and no borrow;
- Box: no borrow;
- copy-out (`get`, `Cell.get`, `copy`, `fill`, `[n of x]`): copyable.

`struct Rng unique` is then not copyable, needs no cleanup and holds no borrow. It is accepted everywhere it should be, and `std/random.rig:8-12` loses its fake `drop`. Size S.

### D. Program-lived results of `extern zig` (the §8 fact)

`extern zig` is std-only, so it can carry one std-only marker without
growing the user language. Proposal: in an `extern zig` block, a result
type may be written `static String?` (or the chosen word). It means "the
view lives for the whole program": the result carries no loans, whatever
its arguments carry. The emitter's `expectShim` already pins the Zig
type. The marker is a promise the Zig file makes, like the rest of the
signature. Apply it to `os.env` and, for clarity, to `os.args`. Size S. The
alternative, `env -> Text?`, copies on every call and needs no new syntax.
