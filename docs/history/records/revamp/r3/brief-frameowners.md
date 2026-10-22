# Round brief: frameowners

Approved by the owner after #229 (`inline`) stopped on its second
soundness round. Start only after #230 (own-stack thread over a huge guard)
merges: both touch frame counting, and one branch at a time owns a fact.
Built without `inline`; `inline` returns on top afterwards as a small
change (step 3 below).

## The problem, as a class

Three review rounds of #224/#229 each found an accepted program that ran off
its stack, each through a different kind of frame some pass had missed:
a generic or aliased callee, a wrapper the automatic rule inlined, a
closure. The cause is the same every time. The set of things that own a
Zig frame is re-derived by each pass (`inlining.Pass.visit`'s `cur` and
`closures` counter, `typecheck.FrameWalker`'s walk of functions, tests,
and lambdas, `frameBytesOfFunction`), and each pass misses a different
member.

It is on main today, without `inline`. `decide` gives a test block's calls
no current function, so the automatic rule's inlining in a test block is
unbounded: a test that calls a 56 KB helper the rule inlines 300 times
keeps about 16.8 MB, and nothing counts it.

## Design

1. **Frame owners, decided once.** Typecheck records one positive list of
   frame owners, `frame_owners`, each with its root node and its parent
   owner:
   - every function and method, each instance of a generic one included;
   - every closure;
   - every test block;
   - `main`.

   `defer` and `errdefer` bodies, iterator `next` calls, match arms, and
   blocks are not owners; their values and calls belong to the owner around
   them. Every call node is assigned to exactly one owner, the innermost
   one around it (`ownerOf(call)`). `decide`, `checkFrames`, and the frame
   facts iterate this list and read `ownerOf`. None of them threads "the
   current function", and none keeps a closure counter.
2. **One frame account per owner,** computed once and read everywhere,
   with three parts:
   - **own:** its own values, as `checkFrames` counts them, or unknown;
   - **marked:** empty in this round; in step 3, the bytes of each
     `inline` call at its instance;
   - **auto:** the frames of the functions the automatic rule inlines into
     it, held to 64 KiB. The cap applies through any callee whose body
     lands in it (in step 3, a marked `inline` one).

   Unknown is unbounded, and fails every limit. `checkFrames` compares
   own + marked + auto with `sema.max_frame_bytes`. `decide` fills `auto`
   and never inlines into an owner whose account is unknown.
3. **The test-block hole closes by construction.** A test block is an
   owner, so its calls have an account and the 64 KiB cap applies.
4. **What it replaces:**
   - `inlining.Pass.visit`'s `cur` threading, its `closures` counter, and
     per-function `calls` attribution;
   - the `frame`/`added` recursion, which reads accounts instead;
   - `FrameWalker`'s separate walks of `fun`/`sub`, `test`, `drop`, and
     `lambda` (one pass over `frame_owners`);
   - `frameBytesOfFunction`, which becomes the owner's own count.

   The facts are `frame_owners` and `ownerOf` in `SemContext`, and
   `account(owner)` is the one reader. `--facts=frames` prints accounts.

## Tests (failing first)

The reviewer's helper, which the rule inlines (56 KB of values):

```rig
fun w(i: Int) -> Int
  t = [7000 of 0]
  for k in 0..7000
    t[k] = k + i
  t[i % 7000]
```

- **First: the test-block pile, main's hole today.** A `test` block that
  calls `w` 300 times. It crashes under `rig test` on main. Afterwards the
  rule must stop inlining `w` there, and the test runs sanitizer-clean.
- **`rev229-closure-pile`,** reworked without `inline`: a closure
  `f = |+i| w(i + 0) + w(i + 1) + … + w(i + 299)` (300 calls, as 30 lines
  of 10), called from `near`. Rejected or sanitizer-clean.
  - The reviewer's original crashes on `794943cbc`, with the closure
    calling `inline fun g(i) -> Int  w(i) + 1`. It is step 3's test.
- **`rev229-chain-pile`** (step 3, once `inline` is back): `a`
  (auto-inlined) calls `g` (`inline`), which calls `w` (auto-inlined);
  `near` sums `a(i + k)` for k in 0..299. It is sanitizer-clean on
  `794943cbc` and prints `91200`.
- **Siblings:** a pile in a `defer` body, an `errdefer` body, an iterator
  `next`, a match arm, a nested closure, `main`, and an instance of a
  generic function. Each must land in its owner's account.
- **Estimate vs real:** extend `test/cli/inline_frames.sh` (renamed
  `frames.sh`; aarch64 Mac only) with these owners. Each owner's account
  must be at least the stack Zig's prologue reserves, within 4 KiB, in
  debug. `--release` only for owners with no unmarked callee, since LLVM
  inlines those of its own accord.
- **Unit:** `frame_owners` lists exactly the owners of a program with one
  of each kind; `ownerOf` of a call in each kind of body.
- **Reviewer probes** are kept in `test/corpus/`.

## Gates

- Mac (`-j 2`, `# cpuq: skip`): build, unit, vocab, style, and
  `cli/inline_frames.sh` / `frames.sh`.
- burst (`--note "#<PR> frameowners"`, `--ship test/json/data`, per
  `burst-brief.md`), one at a time: suite `--delta`, corpus `--delta`,
  full matrix. Classifier work runs the full matrix.
- equiv against the main it merges: only the new tests may change
  `check`/`facts`. Any existing program whose `emit` changes must be one
  whose automatic inlining the account now bounds, listed with the reason.
- One adversarial review, aimed at frame owners a pass could miss.

## Step 3, after this lands

`inline` returns from branch `inline` (#229, closed). Marked calls fill
each owner's `marked` part from `InlineCall.bytes`. The recorded-fact
design of #229 (`inline_calls` by `FnRef`, `inlineFrame` per declaring
module, fail closed) carries over; its own owner walks are deleted in
favor of `frame_owners`.

## Added 2026-10-15: resolve method calls by receiver type

The binder committee's codegen review found that `src/inlining.zig` resolves a method call by its NAME alone. A wrapper such as `Binder.kind` (`self.file.ast.kind(n)`) therefore looks self-recursive and is never inlined: `Binder.kind`, `flags`, `parent`, `get_locals`, `get_exports` and `get_members` all stay out of line, with 11 calls per node for `kind`.

Trig measured that renaming the wrappers gains nothing in --release (LLVM inlines them anyway): this is correctness hygiene, not a speed win. This round's single "call target" fact (by symbol, from typecheck) fixes it: `decide` reads the resolved callee, never a name.

Test: a wrapper method calling a same-named method on another type is inlined, and a real self-recursion is not.

## Withdrawn 2026-10-15: `rarely` calls cold and never inlined (Trig NEEDS 38)

Trig measured that `rarely` already emits `@branchHint(.cold)` and marking the binder's helpers changed neither instructions nor cycles; NEEDS 38 is withdrawn. The text below is kept only for the record.

A call to a `rarely fun` gets a cold hint at the call site and is never inlined by the automatic rule. Today the binder's diagnostic helpers are inlined into 2.6–4 KB frames.

Test: a hot function calling a large `rarely` helper keeps a small frame (frame facts), and the helper is emitted as a separate function.

## Added 2026-10-15 for step 3: small generic members inline (owner-approved)

Rig never emits a generic type's methods `inline`, and LLVM leaves some out of line. `Map.ensure` (39% slower) and `ensure_with` (31% slower) lose to edit-then-put on hits only because each hit pays a call (frame, stack check, the hash constants set up again), while `edit` happens to be inlined. Step 3 lets the automatic rule (and `inline`) apply to members of generic types, per instance, under the same frame accounting. Gate: #240's bench rows `ensure`/`ensure_with` against edit-then-put on hits within 2%, and no row of bench/hash or the JSON guard slower.
When this gate passes, tell Trig: its `ensure` change (declare_symbol_ex, get_locals; a five-line change) was 0.5% slower at a597b1792 and is waiting to be rerun.
