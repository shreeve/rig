# HashMap's count loop on small tables: the Zig ceiling

The question: knucleotide's single-threaded counts on tables of 4 to 256
keys take more time in Rig than in Rust with hashbrown
(rust-ports/reviews/bg2-speed.md, finding 5). What is the fastest Zig for
that loop on Rig's table layout, what does each of Rig's extras cost, and
what must std or the compiler change to reach it. Measuring and design only:
no change to src/ or std/ here.

Programs: `kn12.rig` and `rust-kn12.rs` from
`~/Data/Code/Claude/rig/rig/rust-ports/reviews/bg2-speed-probes/`; the
count is `(!counts).ensure(mix(code), 0) += 1`. Rust is built as
`run.sh` builds `knucleotide-fast` (hashbrown 0.15.5, opt-level 3, lto,
codegen-units 1, panic abort, target-cpu native); Rig with
`rig build --release=fast` at main 4142d6d66. Input: fasta 25,000,000
(`.run/pop/fasta25m.txt`), 125 million counts for each k. Every number is
the count loop's time inside the program, fastest of 8 runs, all arms
interleaved (`small-table-data/kt.py`), on the Mac (Apple M5, load 3 to 6,
`.mac-quiet` absent, through `tools/low`).

## Results

| ms (fastest of 8) | k = 1 | k = 2 | k = 4 |
|---|---:|---:|---:|
| Rust, hashbrown | 160.2 | 156.3 | 154.2 |
| Rig today | 168.8 | 184.1 | 182.3 |
| Rig, prototype of every change that pays (below) | 127.4 | 134.4 | 140.9 |
| Zig ceiling | 114.7 | 123.7 | 130.8 |

Rig today takes 5%, 18%, and 18% more time than hashbrown. The ceiling
takes 28%, 21%, and 15% less time than hashbrown, on the same layout:
groups of 7 slots and an 8-byte word, the overflow byte, tag 0 free and 1
the sentinel, the rotated one-multiply hash, the quadratic probe, 0.8
maximum load. Rig with the changes below, prototyped in a copy of its
emitted package, takes 20%, 14%, and 9% less time than hashbrown, and
8% to 11% more than the ceiling (see "What is left").

## The loop, read

Rig's count today, k = 1, a hit (`kn12-fast`, about 40 instructions):
four `mov xN, #0` that start `claim`'s free-lane bookkeeping, the mix
(`orr x26, x8, x8, lsl #32`), the multiply, the shift reloaded from the
stack (`ldrb w11, [sp, #0xe0]`), the tag from `reduced_table`
(`ldrb w8, [x22, x8]`, then `dup.8b`), the groups pointer and mask
reloaded (`ldr x11, [sp, #0xb8]`, `ldr x12, [sp, #0xc8]`), the group
load, `cmeq`, `fmov`, the lane mask, `pos * 7 * 16` as `lsl`/`sub`/`add`,
`ctz`, the key load and compare, then the index round trip
(`add`, `lsr #4`, `add ..., lsl #4`: `indexOf`'s exact division and
`value_mut`'s address made again, which LLVM does not fold), the store of
`len` (`str x9, [sp, #0xb0]`), and the add to the count. No `rig.turn`
tick: kn12 makes no tasks, so no tick is emitted; knucleotide-fast, which
does, has one at the top of each count.

hashbrown's count (about 33 instructions) also reloads its control
pointer, bucket mask and hash seed from the stack each count, and hashes
by foldhash's folded multiply (`mul`, `umulh`, `eor`). The ceiling's is
23 instructions.

## The ceiling, extra by extra

`small-table-data/ceil.zig` is the table with each extra behind a switch;
`mk.sh` builds one binary for each set of switches, ReleaseFast with
`-fomit-frame-pointer`, as `rig build --release=fast` builds. Its
Rig-shaped arm (every extra on) takes 173, 187, and 181 ms, as Rig's own
build does (169, 184, 182), so the model holds.

Each extra put back into the ceiling (no mix), its time against the
ceiling's, 114.0, 122.6, and 130.8 ms:

| Extra put back | k = 1 | k = 2 | k = 4 |
|---|---:|---:|---:|
| `claim` first: no peeled home-group hit before the probe that keeps the first free lane | 11% more | 16% more | 18% more |
| the mix (`code ^ code << 32`) | 15% more | 17% more | 5% more |
| the tag from `reduced_table` (arm64), not `t \| 0x80` | 6% more | 5% more | 1% more |
| a `rig.turn` tick each count | 4% more | 4% more | 0.5% more |
| the header held in a stack object whose address a noinline grow and drop take | 2% more | even | even |
| the index round trip (ensure hands back a slot index) | even | even | even |

And each taken out of the Rig-shaped arm without the mix (154.2, 170.1,
175.4 ms):

| Extra taken out | k = 1 | k = 2 | k = 4 |
|---|---:|---:|---:|
| `claim` first, by a peeled home-group hit | 19% less | 24% less | 24% less |
| the index round trip | 12% less | 15% less | 14% less |
| the tag table | 2% less | 3% less | 1% less |
| the tick | even | even | even |
| the header escape | 6% more | 7% more | 5% more |
| the `len` store | 6% more | 6% more | 6% more |

The peel and the index round trip overlap: the peeled hit hands back the
slot's address, so with the peel the round trip is gone from the hit
path. Taking out the header escape or the `len` store alone makes the
loop slower, which is layout, not work: neither pays anywhere it was
measured.

The tables are well spread at these sizes without the mix: no key of k =
1, 2, or 4 sits outside its home group with the current multiplier
(`CEIL_DIAG=1`). The ceiling's counts match the Rig-shaped arm's
(checksums of every key and count).

## Rig, prototyped

Each change made in a copy of `kn12.rig`'s emitted package
(`RIG_OUT_DIR`), built with Rig's own `zig build-exe -Ofast
-fomit-frame-pointer` (`mkpkg.sh`; `patch.py`, `patch2.py`; the whole
diff in `unordered-prototype.diff` and `prelude-prototype.diff`). Against
Rig today, 168.9, 191.9, and 182.2 ms in the same run:

| Package | k = 1 | k = 2 | k = 4 |
|---|---:|---:|---:|
| peeled home-group hit in `ensure`, the index still handed back | 2% less | 8% less | 7% less |
| and `ensure` hands back the value's address | 10% less | 17% less | 17% less |
| and the arm64 tag `t \| 0x80` | 17% less | 20% less | 19% less |
| the mix alone taken out of kn12.rig | 9% less | 12% less | 3% less |
| all of these | 25% less | 30% less | 23% less |
| all, and the header by value to grow and drop, `len` counted only on an insert | even with the line above | | |

With the last row the hit path holds everything in registers: no
reload, no `len` store, 21 instructions, against the ceiling's 23. It
takes no less time, which confirms the ceiling's reading: on the M5 the
reloads and the store cost nothing, since they hit L1 off the critical
path.

## What is left

The best prototype takes 11%, 9%, and 8% more time than the ceiling with
the same hit path, the same instructions in another order. The rest of
the two programs differ (the ceiling reads and codes its input more
simply, and its loop sits elsewhere in the binary); this record does not
attribute that gap, and on Apple cores a moved loop alone shifts a hot
loop 5% to 7%. A look with cycle counters at both loops is the next step
if it matters.

## Changes, ranked by gain per line

1. **`ensure` finds a key in its home group before it claims, and hands
   back the value's address.** std: `src/unordered.zig` (a `homeHit` that
   `locate` and `ensure` share, about 15 lines; an `ensure` that returns
   `*V`, about 15) and std/prelude.rig's `HashMap.ensure`,
   `ensure_added`, `ensure_with`, `ensure_by` (one line each), plus the
   built-in's declaration in `resolve.registerTables` (one line, its
   return `!V from @`, as `edit` already is). 10% to 17% less time on
   these counts. General: every HashMap and HashSet `ensure` that finds
   its key, in any program; the cleaner form peels `claim` itself, so
   `put`, `replace`, and `put_new` of a present key gain too. Map's
   `ensure` (src/ordered.zig) already finds first and inserts out of
   line, so this brings HashMap to Map's shape. A miss pays one more
   group compare, the group already in L1; bench/hash's insert rows must
   show it costs nothing (no slower map rows).
2. **The arm64 tag as `t | 0x80`, no table.** std: `homeOf` and
   `tagVector`, two lines. 3% to 9% less time on top of 1. The class
   stays `t & 7`, the same as the tag's. x86 keeps its broadcasting load
   from `match_word`, which unordered.zig chose there over a move and a
   shuffle that cost about a third of a hit. The tag has 7 bits, not about 8, so a lane matches a wrong
   tag twice as often (1 in 128, hashbrown's rate): a large table's
   misses may pay, so bench/hash's Mac rows decide it. General: every
   HashMap and HashSet lookup on arm64.
3. **The mix goes when the planned multiplier lands** (queue row 6).
   kn12.rig's workaround, not std's: 3% to 12% less time, knucleotide
   only. The multiplier must keep these tables as spread as today's (no
   key outside its home group at k = 1, 2, 4).
4. **The tick.** 4% on k = 1 and 2 in a program that makes tasks; emit
   and storage own it, and #782 (a bounded loop checks between strips),
   held because Trig's ts-pattern runs 2.6% slower, is the change that
   would remove it. Nothing new to propose.
5. **The header in registers, and `len` counted only on an insert:** not
   worth their lines on the Mac. The prototype (the grow and the drop take
   the header by value and hand it back, about 15 lines in
   src/unordered.zig, so no pointer to it escapes; `@len += 1 if new`)
   does put the header in registers, and gains nothing. No emit or
   storage change is needed for this loop.

x86 numbers would settle two things this record cannot: whether change 1
gains as much on pup, and whether the header reloads cost nothing there
too. A pup slot is needed for that; change 2 is arm64's alone.
