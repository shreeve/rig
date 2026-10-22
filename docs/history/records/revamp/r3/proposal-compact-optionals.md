# Proposal: compact optionals ("this object's none is id 0")

Design study, 2026-10-15, for Trig NEEDS 39: *"A 4-byte `Node?`. ... an
object can name the value that is its none, so its optional is the same
size and `if n as x` is a compare."* Trig's checker design lists it as its
biggest layout ask (trig `docs/checker/DESIGN.md` §10).

Six reviewers answered independently:
- a language designer (Swift Evolution, Rust RFCs);
- a Rust veteran on niches;
- a performance engineer on data layout;
- a reader of the ownership checker and typecheck;
- a compiler engineer on Zig 0.17 lowering;
- a Go/TypeScript-port pragmatist, from Trig's side.

Their reports and probes are in the session scratchpad
(`scratchpad/reports/{designer,rust,perf,ownership,zig,trig}.md` and
`scratchpad/probes/<role>/`). Every probe was run against `e8310cc27`
with Zig 0.17.0 on the Mac. Nothing in the repo or in Trig was changed.

Nothing here is decided. Every spelling is the owner's to choose. Any
change to `docs/CORE.md` goes through the owner's expert process.

---

## 1. Recommendation

**Build it, as one paragraph of SPEC and a representation fact, in two
rounds.** All six reviewers agree on the shape:

- **A header marker names the none:** `obj Node none(id: 0)`, written
  where `unique` already goes. It was the first choice of all six.
- **The meaning is a type invariant: no `Node` has `id` 0.**
  - A constant `Node(id: 0)` is rejected.
  - A `Node(id: w)` computed at run time panics when `w` is 0, as
    `U8(n)` does.
  - The none field is read-only everywhere. It is a part of the value,
    not a place, as a vector's lane is (CORE §1).
  - Then `Node?` can use id 0 for none. Every form of SPEC §12 keeps its
    meaning, and removing the marker from an accepted program changes
    nothing but `@size(Node?)`.
- **The lowering is `T?` → `rig.Opt(T)`**, a comptime type function:
  - it returns Zig's `?T` for every ordinary type;
  - it returns `Niche(T)` (`struct { raw: T }`, the size of `T`) for an
    object that names its none.

  Generic code then uses the same representation as concrete code. The
  Zig expert showed this is the only correct lowering. Spelling
  `Node?` as the Zig `Node` itself silently turns a none into
  `some(id 0)` at a generic boundary, and collapses `Node??` to two
  states.
- **The shape for round 1:** a plain object (it copies and needs no
  cleanup) with exactly one integer field, not generic. Every Trig id
  type qualifies.
- **The measured gain:**
  - `Node?` takes 4 bytes instead of 8;
  - checker records are 25–42% smaller;
  - lookups that follow optional links are 11–28% faster;
  - Trig's word → `Node?` conversion is 5–8× faster.

  The test is one load and a compare with 0, instead of a tag-byte load,
  a branch, and an id load.

It answers a real program's line (CORE §10). Trig keeps five raw `U32`
aliases where 0 means nil (`SymbolId`, `TableId`, `FlowId`, `FlowListId`,
and `first_declaration: Node` with id 0). Its checker design already
plans `TypeRec.symbol: SymbolRef  # 0 for none`. Each exists only because
`T?` costs 8 bytes, and each gives up the type checking Rig exists to
give. Go's checker has 106 pointer fields that may be nil, across 45 of
the 62 structs in `checker/types.go`, and almost every one is an id of
about 10 kinds.

## 2. The owner's decisions

Each decision has a recommendation. The spellings are the owner's.

**D1. The spelling.** Recommended: **the header marker
`obj Node none(id: 0)`**. A one-field object may also write `none(0)`,
since `Node(0)` already means `Node(id: 0)`.

| Rank | Spelling | Reviewers' verdict |
|---|---|---|
| 1 | `obj Node none(id: 0)`, a header marker | First for all six. It sits where `unique` sits, and the header shows that `Node?` changes. It writes the value as a constructor would. `none` is already a keyword. |
| 2 | `id: U32 none 0`, a field marker | Second for four reviewers. It puts the fact on the field the read-only rule lands on. But it is easily read as a default (`= 0`), and the header no longer shows it. |
| 3 | `id: U32 in 1..`, a range on the field | Principled, but it is Rust's pattern types, unfinished after years: arithmetic, conversions and inference over ranges. It leaves the none's bits implicit. It is a family of features, not one paragraph. |
| 4 | a dedicated `id`/`index`/`handle` declaration | rustc's `newtype_index!`. It duplicates the object, and the ownership reader notes it would add a fifth kind of value. Trig's ids also carry methods. |
| 5 | `none = Node(id: 0)` in the body | Last or rejected by five reviewers. It writes the very construction the feature forbids, and a Go reader takes it for a real sentinel value. |
| — | NonZero integer types (`U32nz`) | Rust's answer, and the bar Rig must clear: `.get()` everywhere, a new numeric family whose arithmetic is not closed, and 0 as the only none. |

The designer warns against `none[id: 0]`: square brackets after a name
mean a compile-time argument, and this clause applies nothing.

**D2. Which value may be the none.** Recommended: **any constant that
fits the field.** The docs should recommend 0.
- All six want 0 for Trig:
  - eight of Trig's arenas keep a nil entry at index 0;
  - the `words` arena stores 0 for both "no node" and `false`;
  - Go's ids start at 1;
  - zeroed memory is all-none, so `List.filled(n, none)` stays a
    zeroed allocation;
  - `cbz`/`cbnz` fuse the compare with the branch.
- Leave the choice to the declaration. NonZero's fixed 0 pushed Rust
  users to `nonmax`, which XORs on every read. A file descriptor's none is
  `-1`, and rustc-style indexes reserve the top value.
- The perf engineer's caution: with a top-value none, zero-filled tables
  silently hold live ids.

**D3. Which objects may name a none in round 1.** Recommended: **exactly
one field, of an integer type, in a non-generic object that is plain
(copies, needs no cleanup, holds no view, holds no Cell, not unique).**
- With this shape, no CORE §9 fact changes. The ownership reader checked
  each fact against `sema.zig`, and none moves for `Node` or `Node?`.
- Owning objects are out: the drop glue of `T?` would have to test the
  field, and a none would carry undefined owner bytes.
- Views are out, so no loan reasoning ever involves a none.

The reviewers split on two widenings, which are listed in §3:
- `unique`;
- more fields.

Recommendation: leave both for a real program to ask for. Every Trig id
type has one `U32` field. Its packed `(file, node)` key is one `U64`.

**D4. How a raw word becomes a `Node?`.** Recommended: **no new built-in
in round 1.** Trig's own `as_node` is written as
`return none if w == 0` / `Node(id: w)`:
- the guard proves the constructor's check;
- ReleaseFast folds the guard and the check to `mov w0, w0` (designer,
  measured);
- `node_word` folds to the identity.

So add a "nonzero" check kind to `proofs.zig`, beside index, byte and
add. It removes the check where a guard made the same test, which
matters in debug builds and keeps the rule visible.

The alternative is `Node.from_int(w) -> Node?`, built into every
none-declaring object, as `Status.from_int` is into every plain enum. The
Rust veteran, the ownership reader and Trig (as a fallback, `from_id`)
favor it. The designer's case against it:
- the program can write the test itself;
- a built-in that exists only when the marker does breaks the property
  that removing the marker changes nothing.

Revisit it if Trig's 472 `as_node`/`as_list` calls ask for sugar.

**D5. Where the rule is written.** Recommended: **SPEC "Objects" and SPEC
§12, one row in the INTERNALS type-facts table, and one `facts.zig`
query. No CORE change.** This is the main split (§3):
- CORE's scope line says "ownership only"; types, numbers and their
  conversions are in SPEC;
- this feature is a value range (a checked conversion) plus a
  representation;
- the ownership checker, `storage.zig` and the oracle change by 0 lines.

If the owner prefers the designer's framing, the CORE §9 bullet gains
one fact: "how its optional is represented: a flag beside the value, or
the value the type declares as its none". That is a sibling of "how a
read view is represented", and is emitted as `rig.Opt(T)` just as that
one is emitted as `rig.ReadView(T)`. Either way it goes through the
owner's expert process.

**D6. Emitted Zig for programs that don't use it.** Recommended (Zig
expert): **emit the helpers only where a type's optional is niche, or
depends on a type argument.** That is one per-type fact. Every other
optional keeps today's direct `?T`, `orelse` and `if (x) |v|`, so
today's programs emit what they emit now.

**D7. A strict test mode.** Recommended: **yes.** One switch makes
`rig.Opt(T)` a tagged wrapper struct for every object and every type
variable. The full suite, the corpus and the matrix then compile only
if every optional site in the emitter and runtime goes through the
helpers. That turns "a missed site is a Zig error" into "a missed site
fails the suite", which "accept means correct" needs.

## 3. Where the experts disagree

| Question | Side A | Side B | Recommendation |
|---|---|---|---|
| A CORE §9 representation fact | **Yes:** designer, perf, and the Zig expert (who asks for a per-type fact in `facts.zig`) | **No, SPEC only:** Rust veteran and ownership reader. CORE is ownership only, and no ownership fact moves. | No CORE change (D5). Both sides agree no ownership fact changes. The dispute is only whether a representation fact belongs on the Core page. |
| A total conversion built in | **`Node.from_int(w) -> Node?`:** Rust veteran, ownership reader (as a mitigation), Trig (as a fallback), perf ("a free conversion both ways") | **None:** designer. A guard plus a proven check does it, and a built-in breaks erasure. | None in round 1, with a `proofs.zig` nonzero kind (D4) |
| `unique` objects | **Allowed:** designer, Rust veteran (neither changes cleanup) | **Excluded:** ownership reader (a none written by `<p.f` is a value no constructor made, and it complicates the unique fact); perf and Zig ("plain, copies") | Exclude in round 1 |
| More than one field | **One named field, other fields allowed:** designer (`obj Span none(start: -1)`), ownership reader (the others are undefined in a none; equality reads only the none field) | **Exactly one field:** Rust veteran, perf, Trig; Zig expert (only if the none fixes every field, so `eql` and `hash` of two nones agree) | Exactly one field in round 1 |
| Where the fact lives | **sema** `Symbol.none` → `sema.compactNone`, read as `Facts.compactNone` (ownership reader) | **`storage.zig`** (Rust veteran) | sema. It is a type fact decided once from the declaration, not a storage plan. |
| `@bitCast` into a none-declaring type in `raw` | Optionally reject it (Rust veteran) | `raw`'s contract allows it (Zig expert, ownership reader) | Allow it. `raw` is the stated limit, as with every invariant. |
| Debug-build cost | Accept it (Zig expert: helpers cost about 1.7× today's instructions for `if as` and about 2.8× for `??`, in Debug only) | Special-case a known niche type to a direct field compare | Accept it in round 1; measure later. A third path is a later choice. |
| Lowering in perf's hand edit | perf spelled `Node?` as Zig `Node` plus `rig_some` | the Zig expert showed that lowering is wrong for generics | Use `Niche(T)`. It has the same bytes, and LLVM folds the helpers the same way, so perf's numbers hold. |

Agreed by all six:
- the header marker;
- the type invariant;
- the read-only field;
- a run-time check that panics like `U8(n)`;
- compact `T?` in generic code (rejecting it there would be an
  exception list, and Trig needs `List[Node?]` and Map values);
- only one layer is compact, so `Node??` is an ordinary 8-byte optional
  around the compact one;
- printing is unchanged.

## 4. The desugaring

`T?` keeps SPEC §12's meaning exactly. Only the representation changes.
With `obj Node none(id: 0)`:

| Rig | Means | Zig (`rig.Opt(Node)` = `Niche(Node)`) |
|---|---|---|
| `Node(id: e)` | `e != 0` or panic; then `Node{e}`. A constant 0 is a compile error. A guard-proven `e` has no check. | `rig.made(Node{ .id = e })`: one `cbz` to a cold panic |
| `none` where a `Node?` goes | the `Node?` whose id is 0 | `rig.pack(O, null)`; `O` is recorded by typecheck |
| a `Node` where a `Node?` goes | some | `rig.pack(O, v)`. Zig gives a wrapper no implicit lift, so typecheck records the lift (`recordAdapted`). |
| `if m as x` | `if m.id != 0`, with `x = m` | `if (rig.some(m)) \|x\|` → `ldr; cmp; csel` |
| `if !m as x` | `x` is a write view of `m`'s value | `if (rig.somePtr(&m)) \|x\|` |
| `m ?? d`, `m ?? return`, `m?` | as §12 | `rig.some(m) orelse ...` → one `cbnz` |
| `m == none` | `m.id == 0` | `rig.isNone(m)` |
| `m == v` (`v: Node`) | one integer compare, since `v.id != 0` | as `eql` |
| `<p.f` | takes the value and leaves id 0 | `takeOut` writes `O.none` |
| `Node??` | an optional of a `Node?` | `?Niche(Node)`: 8 bytes, three states |
| `(?Node)?` | an optional read view | `?*const Node`, as today; Zig's pointer niche is unaffected |
| `?(Node?)` | a read view of the optional | `*const Niche(Node)`, a pointer as today; `lendByValue` is unchanged |

**Rules.** All of these follow from "no `Node` has id 0" and "the field
is a value, not a place". Each is a test.

- **Rejected at compile time:**
  - a constant construction anywhere (`Node(id: 0)`, `[4 of Node(id: 0)]`,
    a module constant, a parameter or field default);
  - a field default equal to the none (`id: U32 = 0`, which would make
    `Node()` the none);
  - every write to the none field, through any root:
    - `n.id = k`, `n.id += 1`, `self.id = 0` in `!self`;
    - `r.id = 0` after `if !m as r`;
    - `!n.id`, `replace(!n.id, v)`, `swap(!a.id, !b.id)`;
    - a `defer` or `while` step that writes it;
  - a shape outside D3.
- **One classifier.** `typecheck.zig` `Checker.requireAccess` is the one
  decider every write passes through: assign, lend to write, write
  iteration, take. `placeOf` gains a positive fact, `Place.none_field`,
  and `requireAccess` refuses it before its `indirect` exit, so no root
  escapes. There is precedent: `Block.read_only` for `pub ?f`.
- **The only construction sites** are `checkFieldArgs` and
  `checkDefaultValue`. Everything else in `handsOver`'s made-value list
  copies or moves values that already hold the rule.
- **Allowed, with no check:**
  - whole-value writes: `x = Node(id: k)` through `!m`, `swap`/`replace`
    of whole Nodes, `<p.f`;
  - `[n of x]`, `fill`, `copy`, `List.filled`, `resize`;
  - `Cell.set`;
  - generic code. A generic body cannot touch a `T`'s fields (probed:
    "generic bodies can only move, copy, and compare `T` values").
- **The hazard is real today.** The ownership reader's probe `b3.rig`
  shows four forms that run now and leave `Node(id: 0)`:
  - `x.id -= 1` through `if !o as x`;
  - `zero(!x.id)`;
  - `self.id = 0` in a `!self` method;
  - `replace(!q.id, 0)`.

  Under a compact layout each would silently turn into `none`.
- **No zero-fill invariant is at risk.** Neither `emit.zig` nor
  `runtime.zig` zero-initializes any value: there is no `std.mem.zeroes`,
  and List growth leaves its unused slots `undefined`. Keep it that way,
  with a grep test.

The proposed SPEC paragraph (ownership reader's draft, with CORE §10's
bar applied):

> **An object may name its none.** `obj Node none(id: 0)` says that no
> `Node` has `id` 0, so a `Node?` is `none` exactly when its `id` is 0 and
> takes a `Node`'s size. Only plain data with one integer field names a
> none. The field is set only by a constructor, which rejects the none
> value where it is constant and checks it where it is not, as `U8(n)`
> does; it is never assigned, lent to write, or taken, through any view.
> Every form of §12 means what it means for any optional: `a == none` is
> `a.id == 0`, `if a as x` is `if a.id != 0` with `x = a`, and `<p.f`
> leaves `id` 0.

## 5. Core impact

- **No ownership fact changes.** The ownership reader checked each fact
  against `sema.zig`, for `Node` and `Node?`, and each gives today's
  answer:
  - `copies`;
  - `isUnique`;
  - `typeHasDropGlue`;
  - `mayHoldView`;
  - `cloneable` (copy);
  - `lendByValue` (a pointer);
  - `isPlainData`;
  - `readsAsValue`.

  D3's shape is what keeps all of them unchanged.
- **The ownership checker changes by 0 lines.** A path stops at an
  optional's value, so a loan on `r.sym` already covers what is inside
  it. Putting the payload and its none in the same bytes adds no alias
  the checker does not already model. `storage.zig` and the oracle are
  unchanged too.
- **Rules follow the type.** The rule is not "writes into a compact
  optional are rejected", which would depend on where a value came from
  and so break CORE §10. It is "this field of this type is never
  written".
- **The one new fact is representation.** `sema.compactNone(ty)` is
  decided once from the declaration and read by emit through `facts.zig`.
  Whether CORE §9 lists it is D5.
- **A future form that sets fields or makes objects** must route through
  `placeOf`/`requireAccess` and `checkFieldArgs`, or it bypasses the
  rule. Examples: update syntax `Node(..n, id: k)`, `read[Node]` from
  bytes, a derived decoder, NEEDS 41's zero value of a generic `T`. A
  comment belongs beside both deciders.

## 6. The measured gain

Measured on an Apple M5 with Zig 0.17.0, single-threaded under `cpuq`,
interleaved, fastest of N. The machine was loaded at times, so the
ranges are wide. Probes and raw results are in `scratchpad/probes/perf/`.

**Sizes** (bytes):

| Record | today | compact | raw `U32` (Trig's workaround) |
|---|---|---|---|
| `Node?` | 8 | 4 | 4 |
| a record with 4 `Node?` | 32 | 16 | 16 |
| Trig `SymbolRec` (binder, measured in Rig) | 88 | 64 | 64 |
| `TypeRec` (checker DESIGN §3) | 32 | 24 | 24 |
| `ValueSymbolLinks` | 32 | 16 | 16 |
| `Signature` | 60 | 40 | 40 |
| binder per-node lists on checker.ts (302,587 nodes) | 9.7 MB | 4.8 MB | 4.8 MB |

**Speed** (sentinel against today):

| Workload | Result |
|---|---|
| random lookups following optional links, at 1×, 4× and 32× L2 | 11% to 28% faster. On the quietest run: 17%, 22–25% and 19–26%. Most of it is footprint. |
| raw word → `Node?` (`as_node`) | 2.6 ns → 0.3–0.5 ns, 5 to 8 times faster |
| a checked construction and store (`Node(id: w)`, one `cbz`) | 32% to 75% faster than today's unchecked `?Node` store |
| sequential scan, cheap bodies | 3 to 6 times faster in ReleaseFast. Equal in ReleaseSafe, because Rig's checked `+=` keeps its branches. Do not promise it. |
| scan whose bodies call functions | within 7% either way |
| a Rig program's emitted Zig, hand-edited to the sentinel | lookups 7% faster in `--release`, 24% faster in `--release=fast` |

**Code.** In ReleaseSafe and ReleaseFast assembly:
- today `if n as x` is `ldrb` of the tag, `tbz`, then `ldr` of the id;
- compact, it is `ldr`, then `cmp`/`csel` or `cbz`;
- `??` is one `cbnz`, and `?` is `cmp`/`csinc`;
- each is one instruction shorter than today's.

**What to quote:**
- records 25–42% smaller;
- lookups 11–28% faster;
- the word conversion 5–8 times faster.

Trig's own probe shows that LLVM already removes the tag of a local
`?Node` in a parent walk. The gain is in stored records, per-node lists
and call boundaries, where the checker's data lives.

## 7. Size

The reviewers' estimates agree: about **600 to 1,200 lines over two
rounds**, most of them in emit and the runtime.

| File | Work | Lines |
|---|---|---|
| `rig.grammar` | `none(...)` in the object header (the grammar already reads a word after the name, `unique`), and its schema role | 10–20 |
| `src/resolve.zig`, `src/sema.zig` | `Symbol.none`, shape validation (D3), the constant fits, no default equals it; `compactNone` | 80–120 |
| `src/typecheck.zig` | `Place.none_field` and a `requireAccess` branch (about 30 lines); constructor and default checks (about 40); record the target of `none` and of each `T` → `T?` lift in `recordAdapted` (about 30–80) | 100–250 |
| `src/proofs.zig` | a nonzero check kind (D4) | 40–100 |
| `src/facts.zig` | `compactNone` and the lift fact | ~20 |
| `src/emit.zig` | about 25–30 sites: the type (1), `none` (4), `??` (2), `?` (2), the `if`/`while as` heads (~8), the iterator loop, the lend chain, `== none`, object declaration, construction, and the central lift | 300–500 |
| `src/runtime.zig` | `Opt`, `Niche`, `some`, `somePtr`, `pack`, `isNone`, `made` (~70 lines, already written in `probes/zig/niche_rt.zig`); `Niche` arms in `eql`, `writeValue`, `suffixedName`, `takeOut`, `noneAt`, `cloneOptional`, `copiedOut`; `List.get`/`pop`, `IntoIter.next`, `listGet`/`listPop` and `elementAt` return `rig.Opt(T)` | ~150 |
| `ownership.zig`, `storage.zig`, oracle | — | 0 |
| tests and docs | about 25 run and reject programs; a compact-none object on `test/matrix.py`'s type axis (the "fix the class" test: every optional form × every context × generic and concrete); the strict mode (D7); SPEC Objects and §12, SYNTAX, the INTERNALS facts row and desugaring | ~300 |

**Rounds** (Rust veteran's plan, which the Zig expert's helper design
fits):
1. **Route every optional operation through the emitter and runtime
   helpers, with output unchanged.** Check it by emit equivalence on the
   suite and corpus, and add the strict mode. This round touches no
   classifier.
2. **Add the marker, the rules and `Niche(T)`, and flip the helpers.**
   This round touches typecheck's place classification, so it runs the
   full matrix (AGENTS.md, "Land fast, release deep").

**Risks, with their mitigations:**
- **A missed emit site.** It is loud: Zig rejects `orelse` or `null` on
  `Niche(T)`, and a `Niche(T)` where `?T` is expected. But it still
  breaks "accept means correct". The strict mode (D7) and the matrix
  axis close it.
- **The runtime's reflective functions** (`eql`, `writeValue`, hash,
  type names). This is the one silent risk: a missed arm prints
  `Node(id: 0)` where it should print `none`. Mitigations:
  - `Niche` declares its own `__rig_print` and a marker;
  - the strict wrapper exercises the same arms;
  - the grid covers print, hash, clone, and the List and Map methods
    that return optionals.
- **A new panic site in hot loops.** It is one predictable `cbz`, folded
  after a guard or a checked `+ 1`. The nonzero proof drops it in debug.
- **Scope creep.** Multi-field, owning, `unique`, enums, and `T??`
  niches. Hold to D3.
- **Layout.** Zig does not promise the layout of an auto-layout
  one-field struct, but it holds today. A `comptime` assertion in
  `Niche` checks `@sizeOf(Niche(T)) == @sizeOf(T)` on every build.

## 8. What it unblocks for Trig

- **Typed ids for the checker from its first line.** `Symbol`, `Table`,
  `Flow`, `FlowList`, `Type`, `Signature`, `Mapper`, `Alias` and
  `IndexInfo` become objects that name their none:
  - `TypeRec.symbol: Symbol?` instead of `SymbolRef  # 0 for none`;
  - passing a `TableId` where a `SymbolId` goes becomes a type error
    (today all of them are `U32`).
- **Records at raw sizes with types kept:**
  - `SymbolRec` 88 → 64 bytes;
  - `TypeRec` 32 → 24;
  - `ValueSymbolLinks` 32 → 16;
  - `Signature` 60 → 40;
  - the binder's per-node lists 9.7 → 4.8 MB on checker.ts.
- **The binder's raw aliases go:**
  - 173 mentions;
  - about 70 `== 0`/`!= 0` nil tests, many of which collapse into `??`
    or `as`;
  - 50 `[Int(sym)]` conversions.

  `lookup_name` goes from 12 lines to 9, and Go's
  `core.OrElse(local.ExportSymbol(), local)` is `??` again. Trig
  estimates half a day of mechanical work, gated by the binder dump
  (18,631/18,631).
- **`as_node`/`node_word` and the list pair (894 calls)** keep their
  source, and in release builds become the identity.
- **Fake nodes become errors.** The nine `Node(id: 0)` stand-ins become
  compile errors, which is the type checking NEEDS 39 asks to win back:
  - `first_declaration` (binder.rig:275, binding.rig:32);
  - the ancestor padding (utilities.rig:2035);
  - the containers (binder.rig:175);
  - `empty_file`'s root (binder.rig:167);
  - the four `deref` fallbacks (utilities.rig:48,55; binder.rig:2891,2898).
- **It makes NEEDS 15 (a panic that never returns) more urgent.** The
  four `deref`/`deref_list` fallbacks after `go_panic` have no honest
  value left to return. Schedule it with this, or just before.
- **Trig gives up nothing.** It never writes `.id` (539 reads, 0
  writes), and all its id types are plain one-`U32` objects. So the
  read-only field and D3's shape cost it nothing.

## 9. Follow-ups the study surfaced (each its own item)

- **`(^T)?` is 16 bytes today** (designer). `rig.Box(T)` is
  `struct { value: *T }`, which loses Zig's pointer niche (`*T?` is 8).
  Under `rig.Opt(T)`, a box's none can be the null pointer, so optional
  boxes become pointer-sized and trees half the size, with nothing
  written in Rig. It belongs to the same class: "a type whose optional
  can use a value the type never holds".
- **Plain enums with an unused value** (`Kind?` is 8 bytes today) could
  take an unused tag automatically. No program can build an enum value
  outside its variants, so nothing changes meaning. Later, through the
  same mechanism.
- **An existing quirk, to triage separately** (Rust veteran): a
  `(Node?)?` holding an inner none prints `none` while `== none` is
  `false`. Rust prints `Some(None)`.
- **Trig migration notes:**
  - `empty_file`'s root needs a placeholder or `File.root: Node?`, which
    adds `deref` to 42 uses;
  - `add_node`, `add_list` and `new_symbol` build from `recs.len - 1`
    and pay one never-taken compare each, unless `proofs.zig` learns
    that `len - 1 >= 1` after the nil entry is pushed.

## The governing rule (owner, 2026-10-16: "a REAL RULE with ENORMOUS BENEFIT")
The compact form is used everywhere a compact type's optional appears, generic code included, with no conversions between forms and no hidden checks on reads, tests, copies, compares or stores. The only check is when a value of the type is built from a number known only at run time. Every test and review of this feature measures against this rule.
