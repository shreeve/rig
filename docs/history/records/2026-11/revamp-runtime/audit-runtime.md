# Audit: the runtime core and the allocator

Revamp branch `revamp`, base edc481031. Scope: `src/runtime.zig`
(9,945 lines), `src/alloc.zig` (2,013), `src/table.zig`,
`src/nametable.zig`, `src/split.zig`, `src/units.zig`, and INTERNALS
"The runtime" through "The program's stack". Every file in scope was
read in full. Nothing tracked was changed; the probes below ran with
`bin/rig` of the worktree (Zig 0.17.0), their sources in the session's
scratchpad.

## Probes

| Probe | Program | Result |
|---|---|---|
| P1 | an object whose `print` method calls `warn`, inside `String(a, " ", <290 bytes of text>)` | the method runs twice (`print ran` on stderr twice); under 256 bytes, once |
| P2 | the same method printed by `print(a, >t)` in a program that makes one task (`t = sq(4)&`) | hangs (killed by `timeout 60`, status 124); the same program without the `warn` prints `x 16` |
| P3 | a `print` method looping 100,000 times over `!out.text("a")`, printed from three tasks, `RIG_SEED=1,2,3` | all three seeds hang (status 124); 500 iterations (below `tick_turns`) finish; without `RIG_SEED` (several workers) it finishes |
| P4 | a single-threaded program whose `print` method calls `print("inner")` | prints `outer inner` then `x end`: the inner line lands inside the outer one |
| P5 | `c[0] = String("b")` on a `*Cell[List[String]]` | rejected by the checker (no finding: `listSet` is reached only by plain data) |
| P6 | `--units=2` with a method of a generic object marked `called` | not cut, runs (no finding) |

## Findings, most severe first

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| R1 | runtime.zig:7807-7816, 8037-8039, 8045-8055, 7753-7759, 4650-4655 | bug (hang) | High | In a program that makes tasks, `print` and `warn` hold `output_lock` (a non-reentrant `std.Io.Mutex`) while they run a value's own `print` method (`writeValue` -> `__rig_own_print`). If that method, or anything it calls, prints, warns, writes `io.stdout()` (`writeStandard` 7971), or calls `os.exit` (`exitNow` 7500), the same task locks again and deadlocks. A safe, checked program hangs. Single-threaded, the lock is a no-op and the inner output lands inside the outer line (P4). | P2 hangs; control prints `x 16`. P4. | Render the pieces of a `print`/`warn` into a task-local buffer with no lock held (a fixed stack buffer that spills to the heap, the writer R3 needs), then take the lock only to copy bytes into stdout's buffer. Keep today's direct path when `!concurrent`. Each print also becomes atomic with respect to other tasks. | +30 | medium: `bench/print/guard.py` must hold for single-threaded programs (unchanged path); concurrent programs pay one copy per value piece |
| R2 | runtime.zig:423-431, 438-444 with 7808, 5753-5759 | bug (hang) | High | `turn` and `tickCall` may yield the fiber while it holds `output_lock` (a `print` method with a loop of more than `tick_turns` turns, or a call through a cycle-cut function). The lock is taken with `lockUncancelable(io())` on the `Threaded` I/O, which blocks the worker thread, not the fiber: another fiber on that worker that prints blocks the thread the holder needs to resume on. With one worker (`RIG_SEED`, so every `rig test --seeds` run of concurrency cases) it always deadlocks; with N workers, N blocked printers deadlock too. | P3: three seeds hang; 500 iterations finish; several workers finish. | The R1 fix: no user code runs while `output_lock` is held, so nothing can yield under it. Add a debug assertion in `turn`/`tickCall` that the task holds no runtime lock. | (in R1) +4 | low once R1 lands |
| R3 | runtime.zig:3533-3555 | bug, efficiency | Medium | `String.of` writes its pieces into a 256-byte stack buffer (`ofShort`); when they overflow it, it discards the work and writes every piece again (`t.add(pieces)`). A value's own `print` method runs twice, so its effects (a `warn`, a counter, a nested `print`) happen twice: the program does not do what the source says (North Star 1). Every value is also formatted twice for any text over 256 bytes. | P1: `print ran` twice past 256 bytes, once under. INTERNALS 5307 describes the two passes. | A writer over the stack buffer whose `drain` moves the buffered bytes into a heap block of the String and continues there: each piece written once; the short case keeps its one exact-size allocation. Share the writer with R1. | +15 | low: `bench/text/guard.py`, std.json guard |
| R4 | runtime.zig:7514-7534 (7521 then 7523-7525) | latent use of deinitialized state | Medium | `finish` calls `threaded.deinit()`, which ends with `t.* = undefined` (std/Io/Threaded.zig:1716-1727), and then `lockOutput()`, `flush()`, and `unlockOutput()`, all through `io()` = `threaded.io()` and the stdout writer whose `io` points at `threaded`. It works only because `fileWriteStreaming` discards `t` (Threaded.zig:10976-10977) and the mutex's uncontended path makes no vtable call. Any Zig change there, or a contended lock, reads undefined memory. | Lines cited; Threaded.zig 1716-1727, 10969-10977. | Move `threaded.deinit()` after the final flush and the reports, as the last step before `reportLeaks` (whose output goes through `std.debug.print`'s own I/O). | 0 | low |
| R5 | runtime.zig:2817-2828 | correctness | Low | An atomic `Cell.add`/`sub` (`Cell[Int]` in a program that makes tasks) stores the wrapped sum with `@atomicRmw(.Add)` and checks overflow only afterwards (`+ n`, panicking in safe builds). Where `task.isolate` stops that panic, the program goes on with the wrapped value stored, which no Rig `+` can produce. | Lines cited. | In safe builds, a `cmpxchg` loop that checks `@addWithOverflow` before storing; `--release=fast` keeps the plain `atomicRmw`. | +8 | low |
| R6 | runtime.zig:3208-3213 | efficiency (hot path) | Low | `List.clone` reserves exactly, then `push`es each clone, a capacity test per element; for a plain-data `T` (`!needsDrop(T)`), `+xs` of a `List[Int]` is a loop of pushes, not one `@memcpy`. | Lines cited. | `allocSlice(T, len)`; `@memcpy` when `!needsDrop(T)`, else write `cloneValue(e)` into each slot; set `len` once. Inline Lists copy into `inline_buf` when they fit. | +6 | low |
| R7 | runtime.zig:1257-1267, 2436-2447, 2718-2729 | duplication | Low | The nested-release guard (test `drop_depth`, queue past `max_drop_depth`, count the depth, drain at the outermost) is written three times: `ApiBox.__rig_drop`, `Counted.dropLast`, `Box.__rig_drop`. | Lines cited. | One `releaseNested(box: *anyopaque, release: *const fn (*anyopaque) void)` that each calls. | -14 | low |
| R8 | runtime.zig:1260, 2440, 2505, 2722; header 17-18 | inconsistency | Low | The drop queue grows through `std.heap.smp_allocator`, not `defaultAllocator()`, though the header says every allocation goes through it: the leak checker and the sanitizer never see it, and every release binary that drops a nested box carries Zig's `smp_allocator` beside `alloc.zig`. | Lines cited. | Allocate the queue through `defaultAllocator()` (it is freed at the drain), or say in the header why it may not. | 0 | low (leak checker counts it while queued only) |
| R9 | runtime.zig:1077-1084, 1923-1928 | duplication | Low | `isShared` and `isCountedPointer` are the same predicate (a one-pointer to a struct that declares `__rig_shared`). | Lines cited. | Keep one. | -8 | none |
| R10 | runtime.zig:5089-5091, 5394-5396, 5404-5406 | needless indirection | Low | `lookupInstructions()`, `neonIntrinsics()`, `wasmSimd()` are functions that return a constant (`lookup_instructions`, `neon_intrinsics`, `wasm_simd`), called as `comptime f()`. | Lines cited. | Read the constants. | -12 | none |
| R11 | runtime.zig:5271, 5357-5358, 5371-5372; tests 8921, 8943 | dead code | Low | A lane count is a power of two from 2 to 64 (resolve.zig:4702). `maskAny`/`maskAll` keep a branch for a non-power-of-two count over 16 on WASM, and `maskFirst` tests `isPowerOfTwo(n)`; the tests exercise `Mask(48)`, a count no program can name. | resolve.zig:4702; lines cited. | Drop the branches and the 48 cases; a `comptime assert` of the rule in `Mask`. | -8 | none |
| R12 | runtime.zig:6-7, 1982-1983, 9933; INTERNALS 5526, 5704-5705, 5300, 5320 | stale docs, history narration | Low | Header: `*T` is "single-threaded reference counting" (it is atomic for synchronized `T`, 2391). "as before" (1983), "as R3's emit will call them" (9933; emit.zig:1902 calls them now), INTERNALS "a build before the trace existed" (5526), "`rig.discardAt` now passes it" (5705). INTERNALS 5320 omits `swapProven` (4533); 5300 omits `listKeep`, `compare_swap`, `add`, `sub`. | Lines cited. | Rewrite as what is; add the missing names. | 0 | none |
| R13 | alloc.zig:616-649 | latent efficiency bug | Low | `kept_reading` holds the clock (ns >> 16) shifted left 24 bits: past 2^56 ns of uptime (2.3 years) the shift drops its top bits, `now -% (k >> 24)` is never under `reading_life_ns`, and every Table of a burst reads /proc/buddyinfo again (43 per checker). | Lines cited; comment at 617-618 states the limit. | Compare the low 40 bits of `now` (`(now -% (k >> 24)) & mask40`). | +1 | none |
| R14 | runtime.zig:6719-6744 | race (diagnostic path) | Low | `Sanitizer.onFault`, a signal handler, walks `leak_checker.live` (`blockBefore`) without `alloc_lock`; in a sanitized program that makes tasks another thread may be rehashing the map, and the handler can fault while it reports. | Lines cited. | `tryLock` the alloc lock in the handler and skip the "past the end" naming when it is held. | +3 | none |
| R15 | alloc.zig:860-886, 954-960, 1181-1226 | duplication | Low | Three hand-rolled spin locks (`region_lock`, `tables_lock`, `spare_lock`), each `cmpxchgWeak` + `spinLoopHint`; `tables_lock` is held across `mmap` and `madvise` of a 256 GiB region (`newTableRegion`, 1031-1046). | Lines cited. | One `SpinLock` struct with `lock`/`unlock`; map the region outside the lock and install it under it. | -6 | low |
| R16 | alloc.zig:1289-1309; runtime.zig:4232, 4306 | idiom inconsistency | Low | alloc.zig repeats `proven_checks` and asserts with `if (builtin.mode == .debug) std.debug.assert` where runtime.zig uses `invariant`; `provenOffset` and `addProven` use `@setRuntimeSafety(false)`, not `proven_checks`, so a debug build drops Zig's own checks there too (the stated rule keeps them; `verify_proofs` still asserts the proof). | Lines cited; INTERNALS 5276-5291. | One spelling: `@setRuntimeSafety(proven_checks)` and an `invariant` in both files (alloc.zig may define its own two-line copy, named the same). | 0 | none |
| R17 | runtime.zig:408-411 | needless code | Low | `TestErrorGlue.eql` casts a `*const ErrData` to `*const ErrData`. | Line cited. | `std.mem.eql(u8, &a.bytes, &b.bytes)`. | 0 | none |
| R18 | runtime.zig:668 | layout | Low | `pub const httpServe = net.serve;` sits in the block of the hash tables' imports. | Line cited. | Move beside `net` (649). | 0 | none |

No unproven omitted check was found: every `@setRuntimeSafety(proven_checks)`,
wrapping op, and pointer read in scope names an invariant the runtime
keeps (List `len <= buf.len`, String `items.len <= capacity`,
`FnRef.ctxAs`, `heldBytes`, `segmentOf`, `blockOf`, Table `len < n`),
and every test of a program value (`index`, `byteOffset`, `bounds`,
`indexBelow`, `offsetBelow`, `through`, `copy`) is made in every mode.
The allocator's small and large paths (classes, alignment by class
size, remote frees by push and swap-all with no ABA, kept-block split,
`mremap` growth, trimming to `keepBound`) and the Tables' ranges were
checked line by line with no memory-safety finding. `split.zig` and
`units.zig` had none either (P6).

## Restrictions and rules

| Rule (where) | Restriction or safeguard | Judgment |
|---|---|---|
| Allocation failure panics (runtime.zig:17, `oom` 5653) | restriction | Keep: Rust's default, no hidden error paths; a program cannot recover OOM. |
| A length is at most `max_len`, 2^62 - 1 (5593) | safeguard | Keep: it is what lets the compiler prove `i + c` fits; no target reaches it. |
| Releases past 256 nested are queued, run later in recursive order (2474-2506) | safeguard | Keep: bounds the stack; the order a recursion would take is kept. |
| Values nested more than 64 deep print as `...` (8406-8408) | safeguard with a cost | Keep, but a legitimately deep value (a 100-node `*T` list) prints truncated; cycle detection by address would print acyclic data whole. Owner's call. |
| `print` output under one process-wide lock (7745-7759) | safeguard | Keep the atomic line, change the mechanism (R1, R2): the lock must never be held across user code. |
| 64 MiB stack over a 64 GiB (or 1 GiB) guard; frame reach held to 512 MiB, measured (6855-6864) | safeguard | Keep; INTERNALS says plainly the frame bound is measured, not proven. |
| Proven checks omitted only in optimized builds, with the invariant named (3097-3110) | safeguard | Keep; unify the spelling (R16). |
| Lane counts are powers of two 2..64 (resolve.zig:4702), relied on by the mask helpers | restriction | Keep; remove the code that pretends otherwise (R11). |
| A Cell is atomic only as one word in a program that makes tasks (2756-2762) | restriction | Keep: atomics where needed, plain memory elsewhere. |
| Subscribing to a Signal from its subscriber panics (3083) | restriction | Keep; rare, and a checker rule would cost more than it saves. |
| `blockingStop` refuses arguments it could write through (122-148) | safeguard | Keep: a canceled waiter must not leave a writer behind. |
| The sanitizer stops guarding past the mapping limit, saying so once (6560-6564) | restriction on checking | Keep; it degrades instead of failing the run. |
| A leak in a debug build exits 1 (7514-7534) | safeguard | Keep. |
| Small-block memory never leaves its class and segments are never returned (alloc.zig:24-25, 84-89) | restriction | Revisit: a program that frees a phase's blocks of one size and allocates another size holds both peaks. Large blocks are bounded (`keepBound`); small ones are not. |
| A large block aligned past the system page is refused, so it panics as OOM (alloc.zig:1326) | restriction | Keep: no Rig type asks for it. |
| Huge pages asked for only with free 2 MiB blocks to spare (alloc.zig:548-609) | safeguard | Keep; each threshold is measured and recorded. |
| A Table is never smaller than `n`; a refused reservation panics (table.zig:27-31) | safeguard | Keep. |
| `os.exit` runs no drop, defer, or leak check (7494-7503) | restriction | Keep: as documented, an exit is immediate. |
| Split builds cut only C-passable or thunked functions; units must number errors alike, checked at start (split.zig:241-283) | safeguard | Keep. |

## The biggest simplification

The output path holds `output_lock` while it runs program code: a
value's own `print` method, through `writeValue`, inside `print` and
`warn`. That one choice is behind both hangs (R1, R2) and the
interleaved nested line (P4), and `String.of`'s two passes (R3) come
from the same lack: no writer that starts on the stack and spills to
the heap. One such writer, used to render every `print`, `warn`, and
`String(...)` before any lock is taken or any byte is committed, makes
each print atomic, makes the lock a short copy that no code can yield
or reenter under, and lets `ofShort` and its retry go; the
single-threaded fast path (`outFixed`, `outValueOf` straight into the
buffer) stays as it is, so `bench/print` should not move.
