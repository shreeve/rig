# too-many-lists: speed review

Rig at main `1b2f4b59d`, Apple M5. **Every timing here is rough.** The Mac was shared
(load 3 to 4.7), and I took the fastest of 5 to 7 interleaved runs. The final timing is
for later. Probes and logs are in `reviews/tml-speed-probes/`: `runtime-fixes.diff`,
`dead-drops.diff`, `m.c` (the malloc probe), `iter.rig`, and `times*.txt`. Each variant
was built from `rig build`'s emitted package with
`zig build-exe -O{safe,fast} -fomit-frame-pointer`, the same flags rig passes.

Already routed, so not reported again: M1 (`^T?` is 16 bytes), M2 (pages stay in their
size class), and the weak count every `*T` carries.

## Verdict on the emitted Zig

The hot methods lower almost as a Zig programmer would write them. There are no bounds
checks. The `?` tests that remain are all needed. `Cell.set` is a load, a store, and a
none test of the old value; `Cell.swap` is a load and a store. A `--release=fast` stack
push is an `alloc` call and three stores, and a pop is two loads, a `free` call, and an
add.

Second's `Iter.next` takes 6 instructions per step, with one dependent load per step, the
same chain as Rust's `Option<&Node>`. The one extra is the tag byte, which is M1. In my
probe, 10 walks of 10M nodes took 134 ms. **Nothing to fix there.**

The cost is in three runtime helpers and in one kind of drop that emit should not write.

## Costs, ranked

### 1. A drop of a place the program has just emptied (safe builds, and fragile in fast)

Rig source and the drop it leaves:
- second `push`, `@head = ^Node(elem: <elem, next: <@head)`: the emitted Zig calls
  `rig.drop(&self.head)` right after `takeOut(&self.head)` has stored none there.
- second `pop`, `@head = <node.next`: the same, and `dropParts(&node, {"elem"})` still
  drops `node.next`, which was taken.
- fourth `push_back` (`@tail = <node` after `<@tail`) and `pop_front` (`@head = <next`
  after `<@head`).
- fifth `pop` (`@head = ... ` after `<@head`).

`dropElement` of `?Box(Node)` is recursive, so LLVM does not always inline it. When it
doesn't, each of these is an out-of-line call that does nothing: a prologue, a
stack-protector load, a tag test, and the epilogue. In `--release`, the stack pays 3 calls
per element.

In `--release=fast` this bench happens to fold them away, but that is fragile:
- An unrelated one-line runtime change (the drain guard in item 2) un-inlined them, and
  the fast stack went from 60 to 97 ms.
- My `iter.rig` probe keeps the call in the fast push loop.

Measured, stack in ms (`--release` / `--release=fast`):

| | stack | deque | queue |
|---|---:|---:|---:|
| base, safe | 112 | 123 | 114 |
| emitted drops removed by hand, safe | 89 | 120 | 109 |
| runtime: `rig.drop` tests none inline, safe | 87 | 122 | 105 |

**Fix, now, in `src/runtime.zig`:** make `drop` inline, so that it tests an optional for
none before it calls `dropElement`, and have `dropPartsAt`'s leaf call go through it.
LLVM then always folds the test after a store of none. This takes 21 to 22% off the
safe stack.

**Fix, properly, in `src/storage.zig` `dropsOld`, fed by `src/ownership.zig`:** today
`dropsOld` is decided by type alone. It should be false when the ownership checker knows
the place holds none, that is, after `<p`, `p = none`, or `swap(none)` with no write to `p`
in between. The same fact should list a taken field among `dropParts`' paths, or skip it.
This also removes the source of the fragility rather than relying on LLVM.

### 2. `drainDropQueue` runs on every last drop (fourth's and fifth's `pop`)

`Counted.dropStrong` (and `Box.__rig_drop`, and the API box's drop) end with
`if (t.drop_depth == 0) drainDropQueue()`. That is true on every pop. It calls a
function that saves 10 registers, reverses an empty list, pops nothing, and
`clearAndFree`s an empty buffer.

**Fix, in `src/runtime.zig`, 3 sites:** `if (t.drop_depth == 0 and t.drop_queue.items.len != 0)`.
This keeps the same semantics.

Measured, fast: deque from 116 to 104 ms, queue from 97 to 87 ms (about 10% each). Safe:
deque from 126 to 117 ms, queue from 110 to 103 ms.

### 3. `dropStrong` is out of line even when the count stays above zero

Every push in fourth and fifth drops the old tail's handle (2 to 1) through a full call.

**Fix, in `src/runtime.zig`:** split `dropStrong` the way Rust splits `Rc::drop` and
`drop_slow`. Make it `inline` for the decrement and test, with a `noinline dropLast` for
the release.

Measured, fast, on top of item 2: deque from 104 to 101 ms, queue from 87 to 82 ms.

### All three runtime fixes together (`runtime-fixes.diff`, no emit change)

| ms | stack | deque | queue |
|---|---:|---:|---:|
| Rig safe, base → fixed | 112 → 88 | 127 → 115 | 110 → 96 |
| Rig fast, base → fixed | 60 → 59 | 117 → 98 | 94 → 86 |
| Rust | 109 | 183 | 107 |

That is 21%, 9%, and 13% less time in safe, and 16% and 9% less on fast's deque and queue.
Unverified: whether the rig suite passes with the diff. The semantics are unchanged by
construction, but it needs the suite and the json and hash guards before it lands.

### 4. Lower, noted only

- **M1's fix should cover `~T?` too.** fourth's `prev: Cell[~Node[T]?]` is emitted as
  `?rig.Weak(..)`, 16 bytes; the assembly shows a tag byte at offset 0x30. `rig.Opt`
  routes only types with `__rig_name` or `__rig_niche`, and `Box` and `Weak` have neither.
- **A 16-byte optional costs instructions as well as bytes.** In the fast push, the
  `?Box`'s 7 padding bytes are copied through the stack on every iteration. In safe
  builds, the head stays in a stack slot and makes a 16-byte store and load round trip
  each step. This is M1; it explains most of the 88 vs 59 ms left between safe and fast
  on the stack, with the `sum +=` overflow check.
- **The allocator's fast path.** `alloc` and `free` are `noinline`, with a TLV lookup
  and a run-time size-class lookup on each call; the reason is documented (fiber safety).
  It is about 13 instructions plus `tlv_get_addr` per call. Not a port issue, and not
  measured here.
- **G4 has a speed cost as well as memory.** fourth and fifth `pop` store none into
  `elem` just before the node is freed. That is one dead store per pop, because there is
  no `try_unwrap`.
- **G15 has a speed cost in fifth's `Iter.next` and `each_mut`.** `next_of` swaps the
  link out and puts back a clone: a count up and a count down per step. It is not in the
  bench.

The port itself needs no change for speed. Each method already does the least its
ownership allows; the remaining count traffic, such as fifth's tail handle, is inherent to
a safe queue.

## Is the benchmark fair?

- **Same work, same output:** yes. It is the same operations in the same order, with the
  same timing scope, and both print `149999985000000`. `n` is a run-time value in both.
- **Allocator (the big one):** Rust uses macOS's `malloc`; Rig uses its own heap per
  thread. `m.c` measures 10M `malloc(16)` and `free` (LIFO) at 114 ms, which is all of
  Rust's stack time (109 to 112). 10M `malloc(48)` and `free` (FIFO) take 142 ms of
  Rust's 182 ms deque. **The comparison measures the allocators, not the code.**
- **CPU target:** Zig builds for the native CPU (M5); cargo builds for the default
  `aarch64-apple-darwin` baseline. It is minor for pointer chasing, but equal care is
  `RUSTFLAGS="-C target-cpu=native"`.
- **Checks:** Rig `--release` keeps overflow checks (`sum +=`), and Rust's release
  doesn't. This favors Rust and is fine as is.

## Are the README's explanations right?

- **"Rig's safe build matches Rust on the stack and the queue":** true as numbers. It is
  matching allocator against allocator, and the README should say that Rust uses the
  system `malloc`. Better, add a Rust row with mimalloc or jemalloc. That needs a crate
  download, which is the owner's call; I did not fetch one.
- **"takes 32% less time on the deque, where Rust pays for RefCell's borrow flags":
  wrong attribution.** About 142 of Rust's 182 ms is `malloc`. The rest, at most 40 ms,
  is `Rc` counts, `RefCell` flags, and out-of-line `drop_slow` calls and the `pop_front`
  closure. The flags are the cheapest part. Suggested wording: "Rust's time is mostly the
  system allocator".
- **Memory, stack:** right. 24 bytes against 16 is M1.
- **Memory, "each queue node carries more: Cells, an optional element, and a weak
  count": the Cells are wrong.** `Cell(T)` is `struct { value: T }` and adds no bytes.
  - A fifth node is 40 bytes against Rust's 16: 16 for the strong and weak counts, 16 for
    the `Int?` element, and 8 for `next`. The element's flag and padding are G4: with
    `try_unwrap` it would be `T`.
  - A fourth node is 56 bytes against Rust's 48: 8 more for `Int?` (G4) and 8 more for
    `~Node?` (M1 class), less Rust's 8-byte borrow flag.
- **Peak in one process (1,151 MB, M2):** not rechecked; already routed.
