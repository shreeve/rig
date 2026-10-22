# Emit views of Cell holders as mutable pointers, and drop `@constCast`

## Summary

A `?self` method or a `?T` parameter was emitted as a Zig `*const T`,
and a Cell change through it was written `@constCast(&self.c).set(...)`.
Writing through a const pointer is undefined behaviour in Zig: LLVM
marks `*const` parameters `readonly`, and a `const` may live in
read-only memory. Debug builds happened to work. `--release` builds
lost changes, read stale Vec headers, freed buffers twice, and crashed,
in ordinary programs on main.

This PR adds one fact, `sema.interiorMutable`: a type that holds a Cell
by value. Every pointer type and storage decision for such a value
follows it:

- every view of it is a mutable Zig pointer (`*T`, `[]T`);
- its storage is a `var`;
- `@constCast` is gone from the emitter and the runtime, and a unit test
  keeps it out.

The fact is decided only in sema. Emit writes the answer into every type
it emits, and the runtime only reads it. In Rig, `?x` is still a read
lend; only the mutability of the emitted pointer changes.

## The hole

`test/behavior/emit/cell_view_counter_loop.rig` is the reviewer's z07,
a plain counter on a named local:

```rig
struct C
  c: Cell[Int]
  log: Cell[Vec[Int]]

  sub hit(?self)
    self.c.set(self.c.get() + 1)
    self.log.push(self.c.get())

fun total(x: ?C) -> Int
  x.hit()
  x.c.get() + x.log.len

sub main()
  k = C(c: Cell(0), log: Cell(Vec()))
  s = 0
  for i in 0..10
    k.hit()
    s += total(?k) + (maybe(i) ?? continue)
  print(k.c.get(), k.log.len, s)
```

On main it emits:

```zig
pub fn hit(self: *const C) void {
    @constCast(&self.c).set(self.c.get() + 1);
    @constCast(&self.log).vecPush(self.c.get());
}
pub fn total(x: *const C) i64 { ... }
```

Results on main:

- **debug:** prints `20 20 159`, as expected.
- **`--release`, macOS:** bus error in `Cell.set`.
- **`--release`, pup (x86_64):** segmentation fault in `Cell.set`.
- **z01, z03, z04, z06:** pushes are lost, or a `drop` sees a stale
  header.
- **z04:** the stale header frees a buffer twice, and two live Vecs then
  share it (`0 1 0 -6148914691236517206`).

Six existing behavior tests also failed when built with `--release`. The
suite only ran debug builds.

## The fix

**The class:** emitted Zig never writes through a const pointer or into
const storage.

**The fact:** `sema.interiorMutable(ty)` answers:

- `.yes` when the type holds a Cell inline;
- `.depends` when it holds a type parameter by value;
- `.no` otherwise.

"Inline" means by value. A generic instance holds its argument's Cell
inline only where the generic holds that parameter by value
(`Contents.held`, the rule `holdsIn` follows for glue). `sema.reachOf`
now masks the Cell of any other argument. So `G[C]` is not
interior-mutable when `G` holds `T` only as `h: *T` or `items: Vec[T]`.
A Cell behind a handle, in a Vec's or Box's heap memory, or behind a
view is writable through every pointer to it. A stack `Signal` is
rejected, so a Signal lives on the heap too.

**One classifier.**

- Emit writes the fact into every struct and union it emits:
  `pub const __rig_interior_mutable = ...;`. The value is `true` when a
  field or payload holds a Cell inline. When a field's answer depends
  on the type arguments, the value is `rig.interiorMutable(F)` of that
  field's type, evaluated per instance. The runtime's Cell type declares
  `true`.
- `rig.interiorMutable` only reads that declaration, through optionals,
  arrays, and error-union payloads (so `T!` agrees with sema's
  `.fallible` too). `rig.ReadPtr`, `ReadSlice`, `ReadView`,
  `Vec.constSlot`, and `rig.slice` all use it. The runtime no longer
  walks Zig fields to decide anything.

**The desugaring** (docs/INTERNALS.md, "Interior mutability"): a view of
a value whose type holds a Cell by value is emitted as a mutable
pointer, and its storage is a `var`.

**Sites routed through the fact:**

- **emit's type printer** (`emitTypeTy`, and `emitPointerTy` through
  `emitViewPtrTy`):
  - `?T` becomes `*T`. This covers `?self`, parameters, stored `?T`
    fields, `|?x|` captures, `?T` parameters of callable views and
    function types, and returned and optional views.
  - `[]T` becomes a Zig `[]T`.
  - When the answer is `.depends`, the type is `rig.ReadPtr(T)` or
    `rig.ReadSlice(T)`.
- **runtime:** `ReadPtr`, `ReadSlice`, `ReadView`, `viewedPtr`,
  `constSlot`, and `slice`.
- **emit's Cell paths:** `set`, `replace`, `push`, `pop`, `clear`, and
  `c[i] = x` call the method on the Cell's address, `(&x.c).set(v)`,
  with no cast.
- **bindings:** a binding is a `var` when the fact is not `.no`. Hidden
  storage that holds such a value is either a `var`, or is only read.
  Zig rejects a write into a `const` at compile time.
- **lint:** a unit test checks that `emit.zig` contains no `@constCast`.
  It also checks that `runtime.zig` contains exactly one, in
  `FnRef.ofFn`, which erases a function pointer that is only called.

**Accept→reject changes**, which keep "accept means correct":

1. **A `?self` method on a part of a branching value whose made leaf has
   no slot**, for example `(w if k else mk(5)).t.hit()`.
   - **On main:** emit wrote through `@constCast(&@as(W, mk(5)))`, a Zig
     rvalue, which is undefined behaviour. With `mkf(5)!` or nested
     leaves, main also printed the wrong value in debug (review H1).
   - **On this branch:** `storage.constLeaf` walks the leaves as
     `emitLeafPtr` does. Typecheck then rejects the call, as `Cell.set`
     on the same part is already rejected.
   - **Still accepted:** branches whose made leaves are slotted (types
     with drop glue, leaves reached directly) and branches whose leaves
     are all names. These run correctly.
   - **Read-only methods are rejected too** (`.t.score()`, review L1;
     main accepted it, and it was safe). Whether a method reaches a Cell
     write is not decided, and every `?self` method of an
     interior-mutable type takes `*T`. The cell-temp redesign can lift
     this by giving the made leaf a slot.
2. **In a generic body, a `?self` method that may change a Cell, on a
   value with no place**: a temporary, or a part of a branch with an
   unslotted made leaf (review M1, r02/r04/r04a).
   - **On main:** these compiled to a write through a const temporary,
     which is undefined behaviour.
   - **On this branch:** when the receiver's answer `.depends`, the body
     records a new requirement, `.cell_place`. Each instantiation checks
     it, as `no_cell` is already checked: "`temp[T]` cannot use `X = T`:
     the generic body calls `run` on a temporary that holds a `X`, and
     `T` holds a Cell, which the method may change there with no place
     to change it". Plain instances are still accepted.
   - **A part of a temporary** (r04b) gets a mutable copy, as concrete
     code does (`recordCellTemp` for `.depends` too), so it runs at a
     Cell holder.

## Verification

**Release mode in the runner.** A `# release` line makes
`check_behavior` also run `rig run --release` and compare its output.

**New behavior tests,** all marked `# release`:

- `test/behavior/emit/cell_view_*.rig` (6): z07, z01/z03/z04, z02/z06,
  places, forms, and branch places.
- `test/behavior/emit/cell_holder_generic_*.rig` (6): the review's
  x01–x06. These cover a generic holding a Cell holder behind a handle
  or in a Vec, viewed through:
  - a generic `?T`;
  - std.sort's comparator;
  - an element of a `?Vec`;
  - a stored `?T`;
  - a subslice;
  - generic and concrete code at once.
- `test/behavior/types/generic_cell_method_part_of_temp.rig`: r04b.

Ten existing Cell tests are also marked `# release`, including the six
that failed in release on main.

**New reject tests:**

- `test/reject/ownership/cell_method_part_of_made_leaf.rig`
- `test/reject/types/generic_cell_method_no_place.rig`

The review's 26 probes are kept as `test/corpus/review-cell-mut-*`,
with `# oracle:` verdicts for every function the oracle decides.

**Release grid.** The matrix family `cellmut.<type>.<access>`
(test/README.md):

- **Types (9):**
  - a `drop`;
  - no `drop`;
  - constant fields;
  - a nested Cell part;
  - generic `G[Int]`;
  - a bare `Cell[Int]` and a bare `Cell[Vec[Int]]`;
  - generics holding a Cell holder behind a handle (`P[C]`) and in a
    Vec (`Q[C]`).
- **Accesses (15):**
  - a local, a field, a Vec element, an array element;
  - a `?T` parameter, a slice, a `?self` method;
  - a stored `?T`, a `|?x|` capture;
  - `if … as`, `for` over a view, a `*T`;
  - a view a generic function returns, an element of a `?Vec`
    parameter, a subslice.
- **Operations (8):** `set`, `replace`, `get`, `push`, `pop`, `clear`,
  `c[i] = e`, a `?self` method.
- **Positions (5):** a statement, a loop with `?? continue`, a loop
  with `break`, a `defer`, a loop with `return`.

Each of the 131 programs runs every operation that applies. Each program
must be accepted, which the matrix now enforces (review L2). It is built
in debug (sanitized) and with `--release`, and must print the trace a
Python model computes.

| | Branch fbae7c5c, debug + release | Main 0cd9f3e3, release |
|---|---|---|
| Mac, matrix family (131) | 131/131 | 84/131 (47 fail: wrong output, 2 bus errors) |
| pup, matrix family (131) | 131/131 (in the gate) | 84/131: the same 47 fail, 2 with a segmentation fault |
| Mac, per-operation grid (509, at 4c521b6a) | 509/509 | 445/509 |

**Review probes on the branch, debug and release:**

- x01–x06, the m-, f-, g-, and v-probes, mod01, r03, r04b, r04c, and r05
  run correctly.
- r02, r04, r04a, and r07 are rejected.
- z01, z03, z04, z06, and z07 run correctly.
- b04 (an internal error) and l01 (a leak) are unchanged from main.

**Gates on pup** (`pup-gates.sh`, PUP_CORES=12, at fbae7c5c), logs in
`logs/cell-mut/pup2.*`:

- suite: 2818 passed, 4 pending
- corpus: 6930 passed
- matrix: 5230 programs, 0 failed, 548 s
- `zig build test`: 127/129, 2 skipped
- oracle, doc, vocab: 337 passed

On the Mac, the suite, the full corpus (6930), the full matrix, the
oracle, and the unit, classify, vocab, and style checks are green.

**Equivalence against main 0cd9f3e3** (`test/equiv.py`; Mac and pup
agree exactly): 9312 programs, 4351 differ.

- **check / facts (7):**
  - the two new reject tests;
  - the review probes r02, r04, r04a (change 2) and r07 (change 1).

  No other program's accept/reject, diagnostics, or facts change.
- **sema / storage (3):** r04b, r04c, and the r04b behavior test. Their
  `.depends` receiver gets a cell-temp copy.
- **pkg only (1732):** the embedded runtime changed.
- **emit (2613 programs).** Every changed line falls in one of these
  categories:
  1. an added `pub const __rig_interior_mutable = ...;` in each struct
     and union: 4431 `false`, 383 `true`, and 237 in generic types that
     combine `rig.interiorMutable(F)` terms;
  2. `@constCast(&p).m(...)` → `(&p).m(...)` on Cell paths (531 lines);
  3. `*const T` → `*T` for interior-mutable `T` (388 lines, plus 15
     where the change sits next to an added declaration or a
     `*const` that stays);
  4. `[]const T` → `[]T` (27 lines);
  5. generic `*const`/`[]const` → `rig.ReadPtr`/`rig.ReadSlice` (53
     lines), including std/slices.rig and std/sort.rig;
  6. the cell-temp copy in generic code above;
  7. a binding of `R[G[C]]` (a struct holding a view of a `G[C]` that
     holds `C` behind a handle) is now a plain `const` with no drop
     guard. It holds no Cell by value, so it is plain data. This changes
     no program's acceptance.

**Performance** (Mac, `--release`): `__TEXT` sizes of examples/ are
identical, except `tree` (+8 bytes). A Cell-heavy benchmark runs in
0.66 s for 20 runs on main, at 4c521b6a, and at fbae7c5c.

**Matrix cost.** The `cellmut.` family takes about 5 minutes of the pup
matrix gate, nearly all of it release builds.
