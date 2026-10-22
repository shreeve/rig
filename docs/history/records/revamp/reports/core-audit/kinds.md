# Core audit: value kinds and type facts

Scope: Core §1 (the four kinds), sentence 2's `+x`, §8 (type facts), and open
decisions 1–2. Main is at `dd36c78`; the branch is `text-core` in
`/Users/shreeve/Data/Code/rig-text`.

Probes are in `probes/kinds/` (main) and `probes/kinds/branch/` (text-core).
Each `NAME.rig` has a `NAME.out` beside it that holds the output and exit
code. To rerun them, use `probes/kinds/run.sh FILE...` (set `RIG=` to pick a
binary).

## The short version

1. **The compiler has no "copyable" fact. Five predicates each answer the
   question differently, and they disagree.**
   - `ownership.isCopy` admits only numbers, Bool, String and errors.
   - `owningKind` and `typecheck.ownsResource` treat any type without drop
     glue as copyable.
   - `isPlainData` treats a type as copyable when it has no glue, no Cell
     and no borrow.
   - `readValue` copies only scalars out of a borrow.
   - The generic `.plain` requirement only checks that the type has no glue.

   Because of this, a plain struct or plain enum is copied in some places
   and treated as an owner in others. That causes false rejections
   (k19, k21, k22, k54).
2. **"Needs cleanup" stands in for "moves".** A type moves only if it has
   drop glue. That is why `Rng` fakes an empty `drop`. It is also why a
   struct holding a Cell (and a bare `Cell`) silently copies and forks its
   state (k10, k11, k36, k45). Four typecheck diagnostics and two emitter
   special cases exist only to patch the forks.
3. **`+x` is a hand-written list of cases, not a structural fact.** It works
   for plain values, `*T`, `~T`, an optional handle, owned closures, and
   (on the branch) `Text`. Everything else that owns is rejected, including
   a struct of handles, `Text?` and `Box[Text]`. The Core marks only
   `Vec`/`Box` as not built.

---

## 1. Every site that decides kind or ownership properties

Legend for the "question" column:
- **COPY**: may this value be copied implicitly?
- **CLEAN**: must it be released?
- **UDROP**: does releasing it run a user `drop` body?
- **BORROW** / **WBORROW**: may it hold a borrow / a write borrow?
- **CLONE**: may `+x` make a new owner?
- **CELL**: does it hold a Cell inline (interior mutability)?
- **LEND**: is a `?T` represented by value or by pointer?
- **SCALAR**: is it a small value that reads through a borrow, crosses the
  owned-closure ABI, or can be a compile-time value?
- **ELEM**: may it be an element of a container?

**PROXY** marks a site that answers one question with a predicate built for
another.

### sema.zig (definitions)

| Helper | What it computes | Question it is used for |
|---|---|---|
| `TypeInfo.glue` / `typeHasDropGlue` | has a `drop` body, or holds `*T`, `~T`, Vec, Box (Text on the branch) | CLEAN, but most consumers use it as COPY (**PROXY**) |
| `maybeDropGlue` | holds a type parameter by value | the "depends on T" value of CLEAN, also used as COPY |
| `TypeInfo.plain` / `isPlainData` | no glue, no Cell, no borrow, no type variable | ELEM (Vec, Signal, Cell element); also COPY in the capture-clone rule (**PROXY**) |
| `isCopyElement` | a Copy primitive or `isPlainData` | ELEM |
| `holdsCellByValue` (`TypeInfo.cell`) | holds a Cell inline | CELL; in typecheck it patches copy forks |
| `Borrows` / `holdsBorrow` / `mayHoldBorrow` / `holdsWriteBorrow` | holds `?T`, `!T` or a slice; `mayHoldBorrow` adds "holds a type variable" | BORROW, WBORROW |
| `isHeapBuiltin` | Vec or Box | a mask in `reachOf`: a Cell behind a Vec or Box is not inline. Structural, not a kind |
| `isBuiltinGeneric` | Cell, Vec, Box or Signal | naming and boxing; not a kind |
| `readBorrowCopies` / `copiedByBorrow` | no glue, no maybe-glue, no Cell, and a scalar, slice, function or optional of one | LEND |
| `isCopyPrimitive` | Bool, Int, Float, String and literals | SCALAR |
| `isPlainEnum` | an enum with no payloads | SCALAR (also `==`) |
| `isClosureValue` / `isClosureResult` | a primitive, a plain enum, or an optional of one | SCALAR (owned-closure ABI) |
| branch `Borrows.view` / `mayHoldView` / `holdsViewOnly` | holds a String | BORROW, with String now counted as a view |
| branch `Borrows.text` / `reachesText` | reaches a Text a String could view | "may be the target of a view" (a new fact) |

### ownership.zig

| Line | Helper | Real question | Notes |
|---|---|---|---|
| 3841 | `isCopy` (definition) | SCALAR-ish: primitives plus `any_error` | Named "Copy", but it is narrower than every other Copy rule. Excludes plain structs, plain enums and optionals. **PROXY** |
| 1909 | `isCopy` in `moveVar` (match payload) | COPY | **PROXY bug**: `<p` of a plain-struct or plain-enum payload is rejected (k19, k54) |
| 1959 | `isCopy` in `movePath` | COPY | **PROXY bug**: `<s.p` where `p` is a plain struct is rejected as a "partial move" (k21) |
| 2122 | `isCopy` (captured value copied out) | COPY | **PROXY bug**: `\|+p\| take(p)` with a plain struct is rejected as "smuggling a handle" (k22) |
| 2136 | `isCopy(pointee)` | SCALAR (a write borrow read as its value) | Differs from `readValue`: includes errors, excludes plain enums |
| 2350, 2351, 2372 | `isCopy` (reassign) | COPY | 2351: a plain-struct payload counts as an alias |
| 2531 | `isCopy` (receiver reservation) | COPY | Too strict for plain structs; harmless |
| 2982 | `isCopy` (`cap_clone` makes a "resource" capture) | COPY | Root of the k22 bug |
| 3075 | `isCopy` / `owningKind` in `returnMoves` | COPY | Two different predicates on adjacent lines |
| 3294 | `isCopy` in `bindPayload` | COPY | **Root cause** of the k19 and k54 bugs: a plain-struct payload becomes an alias, not a copy |
| 3867 | `owningKind` (definition) | COPY, plus a diagnostic label | Built from `glue \|\| maybeGlue`. **PROXY** |
| 1469, 1872, 2132, 2148, 2178 | `owningKind` | COPY (and the label) | |
| 1990 | `owningKind == .generic` | COPY, depends on T | |
| 2644 | `owningKind` in `holdArgRead` | Is this argument read in place? (equivalently, not COPY) | **PROXY**. Its comment says "shares storage", but what it needs is "not copyable". A Cell-holder is let through (it is copied, which is fine today). Rng is held (a needless loan) |
| 538 | `typeHasDropGlue` in `checkCopies` | COPY (a generic body copies T) | **PROXY**: a Cell-holder `T` passes |
| 1086 | glue or maybe-glue in `holderLive` | CLEAN | correct |
| 2309 | `envDrops` | CLEAN | correct |
| 3713 | glue in the drop-order check | CLEAN | correct |
| 3739 | `runsDropBody` on an imported nominal uses glue | UDROP | **PROXY**: any imported type with a Vec counts as running a drop body. `runsDropBody` is its own walk over fields (3732–3760) |
| 3384, 3856 | `isResourceVec` (element glue) | COPY of the element (elements walked by borrowed slot) | **PROXY** |
| 3883 + 21 sites | `mayCarryBorrow` = `holdsBorrow` | BORROW | correct (branch: `mayHoldView`) |
| 3890 + 7 sites | `carriesWriteBorrow` | WBORROW | correct |
| 2669 | `holdsBorrow(elem)` | BORROW | correct |
| 2678 | `isPlainData` in `readsPlainValue` | COPY and no BORROW | **PROXY**: a Cell-holder is treated as not plain |

### typecheck.zig

| Line | Helper | Real question |
|---|---|---|
| 3458 | `ownsResource` (definition: glue, or maybe-glue plus a generic requirement) | COPY. **PROXY**: named after CLEAN, used for COPY |
| 2993, 3120, 4195, 4201, 4373, 6105, 6115, 6167, 6331, 6361, 1371, 1475 | `ownsResource` | COPY |
| 640, 893, 3471 | `ownsResource` | CLEAN (a discarded or overwritten value, or a temporary nobody drops) |
| 4221, 4325 | `ownsResource` | ELEM (slicing a Vec, an array literal) |
| 3407 | `ownsResource` in `synthClone` | CLONE (**PROXY**). The cases are hand-listed: `.shared`, `.weak`, an optional handle; on the branch `.text` |
| 7801 | `isPlainData` for `\|+x\|` | COPY. **PROXY**: rejects a Cell-holder that `+x` accepts (k42 vs k11) |
| 1232, 1238, 1242, 1399, 1721 | `typeHasDropGlue` | COPY: whether a pattern binding is a copy or a view; joined-binding loop steps; whether loop elements are a borrowed slot |
| 8603 | `.plain` requirement = `!typeHasDropGlue` | COPY. **PROXY**: a Cell-holder instance passes |
| 1475, 3212, 6089, 7740 | `holdsCellByValue` | CELL, used only to patch copy forks: reject borrowing, `?self` calls or capture on a loop/match copy of a Cell-holder, or on a temporary |
| 7840 `readValue` | `isCopyPrimitive \|\| isPlainEnum` | SCALAR (auto-copy through a borrow) |
| 4377, 4697, 5459, 6172 | `holdsBorrow` | BORROW |
| 1751, 2164, 6691 | `holdsWriteBorrow` | WBORROW |
| 4916, 4928 | `mayHoldBorrow` | BORROW, including "depends on T" |
| 7893, 3986, etc. | `isBorrow`, `isBorrowType` | structural (is the type `?T` or `!T`); not a kind fact |

### emit.zig

| Line | Helper | Real question |
|---|---|---|
| 5062 | `kindOf` (glue or maybe-glue → shared, weak, optional or value) | CLEAN, plus the drop call's shape |
| 721, 1124 | `holdsCellByValue` (mutable copy of a parameter, mutable storage) | CELL (representation) |
| 2938, 2954 | `readBorrowCopies`, `genericReadBorrow` | LEND |
| 3121 | `.clone` reports unsupported for a glue value | CLONE (relies on typecheck) |
| 1157, 5111 | `isPlainTy` | Not a kind: "the binding needs a Zig type annotation". The name is misleading |
| 5185 | `isPlainEnum` | SCALAR |

### resolve.zig

| Line | Helper | Real question |
|---|---|---|
| 640, 657 | glue on an array or slice element | ELEM (CLEAN stands in for "may be in an array") |
| 2109 | Cell element: `isCopyElement \|\| glue` | ELEM. Rejects a Cell-holder and a borrow-holder (k34) |
| 2113 | Vec element: `isCopyElement`, a handle, or a Box | ELEM. Rejects `Rng` (k16), a Cell-holder (k12), a struct with `?T` (k51) |
| 2123 | Box: `!holdsBorrow` | BORROW |
| 2127 | Signal: `isCopyElement` | ELEM |
| 2370 | `isCtValueType` | SCALAR |

### runtime.zig (comptime mirrors for generic code)

- `needsDrop`: CLEAN.
- `holdsCell`: CELL.
- `ReadBorrow`/`copiedBorrow`: LEND.

These must stay in step with sema. Right now they are kept in step by hand.

### Branch (text-core) additions

| Site | Question |
|---|---|
| `ownership.mayOwnText` → `sema.reachesText` | "may own or reach storage a String views": whether a loan stands for itself or is forwarded to what it views |
| `holdsViewOnly` (ownership 1425, 1738, 2805) | holds a view and no other borrow |
| `mayCarryBorrow` → `mayHoldView` | BORROW, with String counted |
| `synthClone` `.text` case | CLONE (another hand-written case) |
| `ownership.isText` | structural |

**Count.** About 130 call sites of about 25 helpers answer 9 questions.
Roughly 40 of those sites (COPY answered by glue, `isCopy` or
`isPlainData`) are proxies.

---

## 2. Gap table

The "step" column refers to the consolidation steps in §5.

| Core rule | Status the Core claims | Actual behavior (probe) | Gap | Code location | Fix | Step |
|---|---|---|---|---|---|---|
| §1 plain: a struct of plain fields copies | built | Bare bind copies (k01). `+p` copies (k05). | Several places refuse to copy it. `<p` of a plain-struct or plain-enum match payload is rejected (k19, k54). `<s.p` of a plain field is rejected as a "partial move" (k21). `\|+p\| take(p)` is rejected as "smuggling a handle" (k22). | `ownership.isCopy` (3841) and its 11 call sites; `bindPayload` 3294 | M | C1 |
| §1 plain, sentence 1 ("copies plain data") through a borrow | built | `fun get(r: ?P) -> P  r` is rejected; only scalars copy out of a borrow, so you must write `+r` (k46, k47) | The Core doesn't state this rule. Either the Core should say "only scalars copy out of a borrow", or `readValue` should accept any copyable type | `typecheck.readValue` 7837 | S (policy) | C4 |
| §1 owning: moves, one owner | built | Vec, Box, Text, structs with glue and enums with an owning payload all move (k02, k33, t02) | none | — | — | — |
| §1 handle: moves; `+h` bumps | built | `*T`, `~T`, `*T?`, `?*T` and owned closures behave as stated (k03, k06, k29, k31, k50) | none | — | — | — |
| §1 view: a read view copies, a write view moves | built | `?T`, `[]T` and a struct with `?T` copy; `!T`, `![]T` and a struct with `!T` move (k04, k25, k26, k55) | Stack closures are a fifth behavior: they cannot be copied, moved or stored at all (k48) | — | — | add to Core |
| §1 exception: a type marks itself move-only; no fake `drop` | open (decision 1) | `std/random.rig:11` has an empty `drop(!self) pass`. Results: an `Rng` gets a runtime drop guard (`defer rig.drop(&r)`); `[N]Rng` is rejected as "own resources" (k17); `Vec[Rng]` is rejected (k16); the copy error says "two bindings would each run the destructor", which is false (k14) | The hack is visible to users | `std/random.rig`; the copy rule is glue-based (`owningKind`, `ownsResource`) | S–M (grammar, `unique` bit) | C2 |
| §1 / decision 2: a struct holding a Cell is not plain | open | It copies and silently forks state in a bare bind (k10), `+a` (k11), a field read (k45), arrays (k35), and generic T (the `.plain` requirement passes). A bare `Cell[Int]` also copies (k36), which the Core doesn't mention. Other places reject it instead: `\|+a\|` (k42), `Vec[Counter]` (k12), `Cell[Counter]` (k34), and setting it in a by-value parameter (k13) | It is inconsistent, not just "copies". Four typecheck checks and two emitter cases exist only to stop changes landing on a copy | typecheck 1475, 3212, 6089, 7740; emit 721, 1124; resolve 2109, 2113 | M | C2 |
| Sentence 2: `+x` is a copy, a count bump, or a deep copy, as the type says | built, except Vec/Box | It works for plain values, handles, optional handles, owned closures, and Text (branch, t01). It is rejected for Vec (k07), Box (k08), a struct of handles (k09; you must write `Pair(a: +p.a, b: +p.b)`, k41), `Text?` (k40), `Box[Text]` (t07), a struct with a Text (t09), and `?Vec` (k28). For a Cell-holder it is a silent fork (k11) | Clone is a hand-written case list, not a fact that follows from a type's parts | `typecheck.synthClone` 3385; `emit` 3109–3125; runtime clone helpers | L | C3 |
| Sentence 2: `-x` drops now | built | `-n` and `-p` on plain values are accepted and only end the name (k23) | none (worth one line in the Core) | — | — | add to Core |
| Sentence 9: a Cell accepts only values that carry no loan | built; per value: decided | Branch: `c.set(?t[..])` is rejected (t03), as is the Signal case (t08). A literal or a loan-free String is accepted (t11, t10). A `String` parameter is rejected even when the caller passed a literal (t04) | It is already per value (loans), and conservative for parameters | branch ownership `viewLoans` and the Cell store check | — | — |
| §8: "lives for the whole program" as a type fact | decided | Branch: a String with no loans (a literal, the result of a function with no parameters, `os.args`) is already treated as program-lifetime by loan flow (t05, t10, t11) | This is a **value** fact (an empty loan set), not a type fact | — | — | correct the Core |
| §8: "shares memory when copied" | decided | No site really needs it as a separate fact. `holdArgRead` needs "not copyable" (read in place). The emitter needs LEND (by value or by pointer) | The fact as written has no consumer | ownership 2644; sema `readBorrowCopies` | — | correct the Core |
| §8: "copyable" as one fact | decided | Five definitions (see the short version) | The core gap | see §1 | M | C1 |
| §8: "may be cloned" | decided | A hand-written switch | see sentence 2 | `synthClone` | L | C3 |

---

## 3. Corrections to the Core's status markings

1. **§1 plain row, "built".** It is built for bare bindings and `+x`, but
   about 11 ownership sites treat a plain struct, plain enum or optional
   as non-copyable (k19, k21, k22, k54). Mark it: *built, with false
   rejections where `ownership.isCopy` admits only primitives.*
2. **Sentence 2, "`+` on a Vec or Box is not built yet".** The list is
   incomplete. `+` is also not built for:
   - any struct or enum that holds an owner (a struct of `*T` handles, k09);
   - `Text?` and `Box[Text]` (branch);
   - a borrow of a Vec.

   Also, `+` on a Cell-holder is built, but it is a silent fork.
   Suggested marking: *built for plain values, handles, optional handles,
   owned closures and Text (branch); not built for Vec, Box, or any
   aggregate holding an owner.*
3. **§1 decision 2, "open".** True, but the Core describes today as "a
   struct holding a Cell copies". Today is actually inconsistent:
   - it copies in a bare bind, `+a`, a field read, an array and generic T;
   - it is rejected in `|+a|`, as a Vec or Cell element, and when set
     through a by-value parameter.

   A bare `Cell[T]` also copies (k36). The decision should cover `Cell[T]`
   itself, not just structs holding one.
4. **§1 decision 1, "It does not fake a `drop` body".** Today it does
   (`std/random.rig:11`). The status line should say: *today: an empty
   `drop`, which costs a runtime drop guard, bars `[N]Rng` and `Vec[Rng]`,
   and gives a wrong diagnostic.*
5. **§8 "lives for the whole program" belongs with the per-value
   classification, not the type facts.** On the branch it already holds
   as "a String carrying no loan".
6. **§8 "shares memory when copied" has no consumer.** Replace it with the
   two facts that do: "read in place" (that is, not copyable) and the
   emitter's LEND representation.

---

## 4. Behavior the Core does not cover (add or cut)

| Behavior | Today | Recommendation |
|---|---|---|
| Stack closures (`\|?n\| ...`) cannot be copied, moved, returned or stored (k48) | a fifth kind, "pinned" | **Add** to the view row: a stack closure is a view that only its scope may use |
| `Signal[T]` exists only behind `*`; a stack `Signal` is rejected (k32) | a handle-only type | **Add** one sentence |
| A bare `Cell[T]` copies (k36) | — | **Add** to decision 2 (a Cell is move-only) |
| Only scalars copy out of a borrow; anything else needs `+r` (k46, k47) | `readValue` | **Add** as a rule, or widen to "copyable" (C4) |
| A copy of T in a generic body becomes an implicit requirement that each instance is "plain" (k30). Generic T may not hold a borrow | `checkCopies`, `.plain` requirement | **Add**: a type parameter's kind is inferred from how the body uses it |
| By-value parameters are immutable; a Cell-holder parameter cannot be set (k13) | typecheck | **Cut** with decision 2 (a Cell-holder would be moved in, and own its Cell) |
| Owned-closure parameters and results are limited to scalars | `isClosureValue` | **Add** (ABI rule) or lift later; it is outside the kind model |
| Element rules: Vec takes plain values, handles and Box; arrays and slices take anything without glue; Cell takes plain or glue values; Signal takes plain values (k12, k16, k17, k34, k51) | resolve 640–2130 | **Cut** under §5 ("containers hold anything"). What survives is the Cell/Signal rule "carries no loan", which is per value |
| A user `drop` on a struct of plain fields makes it owning (k56) | glue | Keep. It follows from "needs cleanup ⇒ moves" |
| `drop` bodies only on non-generic structs | SPEC §8 | **Add** to the Core or keep in SPEC |

---

## 5. Type-facts design

### The facts

Each fact is computed once per interned type in `TypeInfo`. Each type fact
can be **yes**, **no**, or **depends on T**. "Depends on T" replaces today's
separate `maybeDropGlue` and `holds_type_var` checks: a generic body treats
"depends" conservatively and records a requirement on the instance, as
`ownsResource` does now.

| Fact | Definition | Replaces |
|---|---|---|
| `cleanup` | has a user `drop`, or holds `*T`, `~T`, Vec, Box, Text or an owned closure | `glue`, `typeHasDropGlue`, `maybeDropGlue`, emit `kindOf`'s test, runtime `needsDrop` (mirror) |
| `user_drop` | dropping it may run a user `drop` body | `runsDropBody` and `fieldsRunDropBody` (about 30 lines); fixes the imported-type over-approximation |
| `unique` | declared `unique` (decision 1), or holds a Cell inline (decision 2) | the empty `drop` in `Rng`; the copy-fork patches |
| `borrows.any`, `borrows.write`, `borrows.view` (branch) | as now | `holdsBorrow`, `holdsWriteBorrow`, `mayHoldView` (unchanged) |
| `view_target` (branch `text`) | owns or reaches storage a view may point into | `reachesText` |
| **`copyable`** (derived) | not `cleanup`, not `unique`, not `borrows.write`, and not a stack closure | `ownership.isCopy`, `owningKind != null`, `ownsResource` (COPY uses), `isPlainData` (COPY uses), `isResourceVec`, `.plain` requirement, `checkCopies` |
| `plain` (derived) | `copyable` and not `borrows.any` | `isPlainData`, `isCopyElement`. After §5 it is needed only for the Cell/Signal "no loan" rule and the owned-closure ABI |
| **`cloneable`** (derived) | `copyable` (copies); `*T` or `~T` (bump); Text (deep copy); Vec, Box, optional, array, struct or enum whose parts are all cloneable and with no `user_drop` and no `unique` | the `synthClone` switch and emit's `.clone` |
| `cell` (representation) | holds a Cell inline | `holdsCellByValue` (emitter only, once `unique` covers the checks) |
| `lend_by_value` (representation) | `?T` is a value, not a pointer: `scalar` or a view, and not `cleanup` or `cell` | `readBorrowCopies`, `genericReadBorrow`, runtime `ReadBorrow` (mirror) |
| `scalar` | a number, Bool, String, plain enum, error, or an optional of one | `isCopyPrimitive` (as a kind test), `readValue`, `isClosureValue`, `isCtValueType`, emit `isPlainEnum` uses, ownership 2136, `copiedByBorrow` (core part) |

Two things are kept outside the facts:
- **`kindLabel(T)`**, for diagnostics only ("Vec", "shared handle",
  "`Rng` value"). This is today's `Owning` enum, which should never again
  be used to decide anything.
- **Lifetime** (whole program or not), which is a value fact: an empty
  loan set.

Emit's `isPlainTy` should be renamed `needsAnnotation`. It is not a kind.

### Mapping every current site to a fact

| Fact | Sites |
|---|---|
| copyable | ownership 538, 1469, 1872, 1909, 1959, 1990, 2122, 2132, 2148, 2178, 2350–2372, 2531, 2644 (`holdArgRead`), 2982, 3075, 3294, 3384; typecheck 1232–1242, 1371, 1399, 1475, 1721, 2993, 3120, 4195, 4201, 4373, 6105, 6115, 6167, 6331, 6361, 7801, 8603 |
| cleanup | ownership 1086, 2309, 3713; typecheck 640, 893, 3471; emit 5063; runtime `needsDrop` |
| user_drop | ownership 3732–3760 (`runsDropBody`) |
| cloneable | typecheck 3385–3412 (`synthClone`); emit 3109–3125 |
| borrows.* | ownership `mayCarryBorrow` (21 sites), `carriesWriteBorrow` (7), 2669; typecheck 1751, 2164, 4377, 4697, 4916, 4928, 5459, 6172, 6691; resolve 2123 |
| plain | ownership 2678; resolve 2109, 2113, 2127 (until §5) |
| ELEM (an element rule, until §5) | resolve 640, 657; typecheck 4221, 4325 |
| cell | emit 721, 1124 (typecheck 3212, 6089, 7740 go away with `unique`) |
| lend_by_value | sema `readBorrowCopies`; emit 2938, 2954; runtime `ReadBorrow` |
| scalar | typecheck `readValue` 7837; sema `isClosureValue`; resolve 2370; ownership 2136; emit 5185 |
| view_target | branch ownership `mayOwnText` |

### Consolidation steps, in order

| Step | Change | Lines (approx.) | Risk |
|---|---|---|---|
| **C1** copyable | Add a derived `copyable` bit. Delete `ownership.isCopy`. Reduce `owningKind` to a label. Rename `ownsResource` to `requireCopyable`, which keeps recording generic requirements. Point the `.plain` requirement and `checkCopies` at `copyable`. Fixes k19, k21, k22, k54. | −40 / +15 | **Medium.** `bindPayload` turns a copyable payload into a copy with no loans. A copyable payload that holds a read borrow must still carry the scrutinee's loans, so the condition is `copyable && !borrows.any`, or the loans must be kept. Add the four probes as `test/behavior` tests first |
| **C2** unique | Add a `unique` modifier on struct declarations (grammar, `@schema`, resolve). Infer `unique` for a Cell held inline (decision 2), including bare `Cell[T]`. Remove `Rng`'s empty `drop`. Delete typecheck 1475's Cell branch, 3212, 6089, 7740 and emit's `mutable_copy`. Loop and match bindings of a unique type become views, not copies | −60 / +30 | **Medium–high.** About 150 test files hold a `Cell` by value. Those that copy one implicitly must write `<a` or `+a`. `+a` needs C3 for a Cell (clone = a new Cell with a cloned value) |
| **C3** cloneable | Compute `cloneable` structurally. Emit a generic `rig.clone` (comptime walk, like `needsDrop`) for Vec, Box, structs and enums. Delete the `synthClone` case list | −25 / +150–250 | **Medium.** It needs runtime clone glue and leak tests for each shape. A user `drop` type stays not cloneable unless it declares a clone, which the Core doesn't cover yet |
| **C4** scalar | One `isScalar` in sema. `readValue`, `isClosureValue`, `isCtValueType` and `copiedByBorrow` call it, and each documents its one extension. Then decide (policy) whether reading a copyable non-scalar through a borrow copies (k46) | −30 / +10 | Low |
| **C5** user_drop | Compute a `user_drop` bit in `Contents`. Delete the `runsDropBody` walk | −30 / +8 | Low |
| **C6** names | Rename `isPlainTy` → `needsAnnotation`, `holdsCellByValue` → `cell` (representation), `readBorrowCopies` → `lendByValue`. Document the runtime mirrors as mirrors of these facts | ±0 | Low |

**Net.** About −180 / +70 lines without structural clone (C1, C2, C4, C5,
C6), or about +150 net with C3.

C1 is the step with the best ratio of correctness to risk. It is small, it
fixes four false rejections, and it gives C2 and C3 one bit to build on.

C2 should land after decision 1's spelling (`unique`) is settled. The
inferred case (Cell) and the declared case (Rng) are the same bit, so one
change resolves both open decisions.
