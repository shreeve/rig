# Map's hot path inlined on the dense layout (2026-10-26, interim)

Branch `map-inline`. It keeps today's layout: dense entries, stored
hashes, and the `Table` of tags and entry indexes. It changes only how
Map's and Set's code is cut into functions (std/__rig_builtin.rig).
This record is interim: the full campaign is running on pup, and the
rows below are what is measured so far.

## What is built

- **`find` is `inline`**, in Map and Set, so a lookup's probe is part of
  the method that runs it, with its state in the caller's registers.
- **`insert` is `inline`**: an insert into room the Map has is a push of
  the entry, a push of its hash, and a free slot, with no call and no
  copy of the key into one. `add_entry` (Map) and `add_new` (Set),
  marked `called`, are gone; `replace`, `put_new`, and `Set.add` call
  `insert`. `ensure`'s and `ensure_with`'s `add_new` and `add_made`
  stay `rarely`.
- **Growth stays out of line and cold:** `grow`, `rarely`, so
  `noinline` with the cold hint; `compact` and `rebuild` are reached only
  through it, `reserve`, and `retain`.
- The growth test's sums use wrapping operators (`+%`, `*%`), since a
  table's length counts bytes in memory, and the insert reads the new
  entry's index before the push, not as `es.len - 1`.
- **The probe keeps its two passes** (from the slot `h` names to the
  end, then from the start), each a loop whose test is the bounds test.
  One loop that wraps (`i = 0 if i == ts.len`) was built first
  (f4a471003) and dropped before measuring: on x86 it took 12
  instructions a step against 10, since LLVM kept both the wrap's
  compare and the loop's.
- test/cli/inline.sh now says the new shape: an inlined write holds
  only the table's probes (`find`, `Table.free_slot`), and `grow` is
  `noinline`.

## Builds measured

| Name | Rig | Note |
|---|---|---|
| base, base-pgo | main 5a79e02f2 | |
| new, new-pgo | map-inline 87c3885e0 (its std is that commit's; eaf158092 changes only a test) | |
| newb | 87c3885e0 with `find` left unmarked (LLVM decides), `insert` inlined | release only; a probe of code size |

Trig main c75127e, `tools/trig/main.rig`, built through `slot.sh`:
`rig build --release`, and `--pgo` trained by `tools/trig/bolt-train`.

## Interim numbers

**Release, a preview of 3 rounds** (pup, core 8 with 9 idle, warm, one
checker; other sessions' builds on the release slots):

| Project | Time | Cycles | Instructions | Peak RSS |
|---|---|---|---|---|
| ts-pattern | 1.7% faster | 2.1% fewer | 3.46% fewer | 297.9 to 298.2 MB, 0.1% higher |
| zod3 | 6.3% faster | 3.3% fewer | 3.12% fewer | 90.6 to 90.9 MB, 0.4% higher |

**Code size:** Trig's release text grows from 15.83 MB to 16.45 MB
(3.9%), which is where the 0.3 MB of RSS comes from.

Still to come: the full campaign (release and PGO, 1 and 4 checkers,
warm and cold, fastest of 10), spills and reloads in the PGO build's Map
code, bench/hash in safe and fast mode, std.json, and the gates.
