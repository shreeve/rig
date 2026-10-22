# concurrency

## Parity means
Accepted programs are free of data races, as Rust's are. GPUI-class engines and parallel checkers need no `raw`.

## Must build
1. **Two thread facts: "moves" (to another thread) and "shares" (read from two)** (small). A Rig object's facts come from its parts, as its kind does (CORE §1). Each Zig-backed type *declares* both, with no default. #41622 came from deriving these facts for a library type. Fixed cases: `*T`, `~T`, `*fun`, Cell, and Signal do neither; `?T` moves if T shares; `!T` moves if T moves.
2. **`scope`, which checks a spawned closure capture by capture** (medium). A `?x` capture needs `x` to share; `!x`, `<x`, and `+x` need it to move. Threads join when the scope's closure returns, never in a drop (#24292). Spawned closures are stack closures lent to the scope (CORE §7); loans end at the join.
3. **`Shared[T]`** (small): an atomically counted handle. Its name keeps the cost visible.
4. **`Mutex[T]` locked only by `m.lock(|!v| ...)`, plus `Channel[T]` and `Atomic[T]`** (medium). With no guard type, #41622 has nowhere to occur. A panic aborts, so no poisoning and no `UnwindSafe`.

## Leave out, and it dissolves
- **Detached spawn.** No orphan threads and no `'static` bound. Cope: open a scope in `main`.
- **`AtomicPtr` and `Consume`.** An `Atomic` holds only plain data, so an ordering changes which value a read sees, never safety. Users get `Relaxed`, `Acquire`, `Release`, and `SeqCst`; only std's Zig code needs a weak-memory logic (iRC11).
- **Thread-locals and global mutable state.** Cope: pass a context.
- **`Pin`, `poll`, `Waker`.** A task is a spawned closure whose frame the scope boxes and never moves. A loan may last across an `await` because the scope joins inside the loan.

## Proof obligations
- Stage 3: λRig with `scope`: accepted programs have no data race, under SC.
- Stage 4: specs for Shared, Mutex, Channel, and Atomic in iRC11. Each declared fact is proved.
- Stage 2: the interpreter records the thread on each loan tag.

## Disagreements
- RUST-TRIAGE's "no Send/Sync" and rust-soundness's "declare both" are each half right. Derive the facts for Rig objects; declare them for Zig-backed types.
- Threads cannot share a read-only tree of `*T` nodes, because `+h` would race. Trig's parallel checker needs arenas with IDs, or `Shared`.
- GPUI's foreground tasks hold `*T`. Plan a same-thread task scope whose captures need not move.
