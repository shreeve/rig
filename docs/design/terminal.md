# std.terminal design

`std.terminal` is a terminal emulator as a library. A program's output
goes in through `feed`; the screen, its history, the cursor, and the
terminal's replies come out. It behaves as Ghostty does and runs faster:
on every corpus of bench/terminal it beats Ghostty with or without its
SIMD paths, history included. Its API is in
[docs/STD.md](../STD.md#stdterminal); this record holds what the API
doesn't show, which is the decisions, the data model, how a change is
checked, what speed taught, and what is left.

| File | Contents |
|---|---|
| [std/terminal.rig](../../std/terminal.rig) | the whole terminal, in three sections: Styles, The screen, The parser |
| [std/terminal.zig](../../std/terminal.zig) | `widen`, the one Zig shim (see Speed) |
| [tools/terminal_ghostty.py](../../tools/terminal_ghostty.py) | the cases, recording Ghostty's answers, and the fuzzer |
| [tools/terminal_ghostty.zig](../../tools/terminal_ghostty.zig) | Ghostty's side: feeds a case to libghostty-vt and dumps it as `Terminal.dump` does |
| [tools/terminal_dump.rig](../../tools/terminal_dump.rig) | std.terminal's side of the fuzzer |
| [test/rig/std-terminal-ghostty.rig.test](../../test/rig/std-terminal-ghostty.rig.test) | the recorded cases, Ghostty's answers as expected results (written by the tool, never by hand) |
| [bench/terminal/](../../bench/terminal/README.md) | the benchmark against Ghostty and Dispatch, and its results |

## Decisions

These are the owner's, made before the first line was written:

1. **One engine, xterm-compatible, as Ghostty implements it.** There are no
   VT52/VT100/VT102 conformance levels and no ROM quirks. Kitty
   graphics, sixel, and double-width lines are out. Mouse reporting,
   hyperlinks, OSC 52, and the rest of the kitty keyboard protocol come
   after the core.
2. **A library only.** Bytes go in; the screen, replies, and later events
   come out. There is no PTY, no keyboard, and no drawing. `std.tty`, a
   separate module, will own terminal I/O (raw mode, size, isatty,
   PTYs). The owner has put it last, after the rest.
3. **Ghostty defines correct behavior.** The pin is commit
   `31bdcd5a7963`, the one Dispatch's Swift port follows. A case
   std.terminal gets wrong is a bug, even where xterm differs.
4. **Faster than Ghostty,** measured on the same corpora, while matching
   it.
5. **Sources:** Ghostty (MIT) for behavior and tests, Dispatch (Paul
   Miller's Swift port, MIT, `~/Data/Code/rig/misc/dispatch`) for compact
   structure, and the VT100 ROM listing (Paul Flo Williams, CC BY 4.0)
   for the row map.
6. **Scrollback** counts lines, 10,000 by default
   (`Terminal.new(cols, rows, scrollback: N)`, 0 for none). It takes
   exactly the rows Ghostty sends to history.

## The model

The comment above `pub obj Terminal` and each field's comment are the
reference; this is the shape of it.

- **A cell is a `U64`:** the rune in the low 21 bits (0 for empty), BARE
  in bit 27, PROT in bit 28, EXTRA in bit 29, the kind in bits 30 and 31
  (0, WIDE, TAIL for a wide rune's spacer, HEAD for the spacer a wide
  rune leaves at the end of a row it wraps from), and the style index in
  the high 32 bits. An erased cell with no background is 0, so erasing
  is a memset of zeros.
- **Rows are physical rows of `cells`,** `cols` cells each, in any order.
  `map[rot + y]` is screen row `y`'s physical row. `map` is two screens
  long, so a full-screen scroll moves `rot` down one entry instead of
  moving rows. Each physical row has `flags` (ROW_WRAP, ROW_CONT,
  ROW_WIDE, ROW_MORE) and `ends`, past which every cell is 0, so
  erasing clears only the cells written.
- **Chars of several runes** keep their first rune in the cell and the
  rest in `extras`, keyed by the cell's index, with EXTRA set on the cell
  and ROW_MORE on its row.
- **Styles are interned** in `styles`. The first 32 are found by
  scanning, the rest through `style_ids`, keyed by `style_key`. A cell
  holds an index, never a style.
- **The alternate screen** swaps in through the `other_*` fields (cells,
  map, flags, ends, extras, saved cursor, kitty flags, protection mode).
  It is made blank the first time it is used.
- **History** lives only on the primary screen. Its rows are physical
  rows of the primary's `cells` (`other_cells` while the alternate
  screen is shown). `hist` is a ring of their numbers, oldest at
  `hist_at`. A row scrolling off the top is added to the ring. The row
  that replaces it is the evicted oldest once the ring is full, else a
  `spare` one (rows ED 3 let go), else a new one, so a scroll stays a
  few stores. The first row of history reserves room for the rest, up
  to `HIST_ROOM` rows. Ghostty's rules decide what enters: IND, LF, NEL,
  a wrap, or SU while the scroll region's top is row 0. ED 3 empties
  it, ED 22 scrolls the screen into it (Ghostty's scrollClear), and RIS
  clears it.
- **The parser** is the DEC state machine (vt100.net) as Ghostty runs
  it. The ground state has fast paths:
  - `printable_end` finds a run of printable ASCII eight bytes at a time,
    and `widen` writes it into cells.
  - `print_utf8` decodes UTF-8 runs straight into cells.
  - `csi_run` reads a common CSI sequence whole.

## Checking a change against Ghostty

Every behavior is checked against Ghostty, never against an expectation
someone wrote. `tools/terminal_ghostty.py` builds a small Zig program
against Ghostty's source at the pin (`$GHOSTTY`, a checkout with that
commit, or a clone; Ghostty builds with Zig 0.16.0, `$ZIG_GHOSTTY` or
mise's). It then works three ways:

- **Record:** `tools/terminal_ghostty.py` feeds every case in `CASES`
  (area, name, size, bytes) to Ghostty and writes the test file from its
  answers. The test file holds only the areas in `AREAS`, the ones
  std.terminal implements. A new area joins `AREAS` in the change that
  implements it. `--check` fails when the file is not what the tool
  would write.
- **Fuzz:** `--fuzz N --seed S --rig bin/rig` feeds random streams to
  both and shrinks each one whose dumps differ to a short reproducer.
  Run it with `RIG_STD=$PWD/std` when std has changed since `bin/rig`
  was built. `--all` also draws sequences std.terminal does not implement
  yet, which shows what is missing. A clean run of at least 5,000
  streams over two seeds is the bar for a change.
- **Dump:** both sides print the same text (`Terminal.dump`). History
  rows come first as `^` lines. Then the screen rows as `|` lines, the
  style runs (`~ROW FIRST-LAST STYLE`, history rows numbered from -1),
  the replies, and the cursor. A difference anywhere is a bug.

The harness found most of the behavior worth knowing, such as where
Ghostty unwraps rows, which cells count as empty, and when a wide rune's
spacer in the row above (even in the history) is cleared. When the two
disagree, read Ghostty's source at the pin: `Terminal.zig`, `Screen.zig`,
and `PageList.zig` under `.zig-cache/ghostty-31bdcd5a7963/src/terminal/`,
which the tool exports.

## Speed

`bench/terminal/bench-terminal` times rig-safe and rig-fast against
Ghostty (with and without scrollback and SIMD) and Dispatch, on seven
corpora of about 4 MB each. Every variant must end with the same screen
hash, so the benchmark is a 16 MB conformance check too. The results
table is in [bench/terminal/README.md](../../bench/terminal/README.md).

How to measure:
- Other sessions load the machine. The variants run interleaved and the
  fastest run counts, so ratios hold under load while absolute numbers
  do not. Record the load average with any table.
- Check for `~/Data/Code/mumps-compare/.mac-quiet` first, and hold off
  while it exists.
- Measure CPU cycles (`/usr/bin/time -l`) for small differences.

What speed taught:
- **Zig 0.17 turns LLVM's loop vectorizer off** (llvm#186922). A plain
  loop widening bytes into `U64` cells runs one cell at a time, so
  `widen` is a Zig shim using `@Vector`, 35% faster on text.
  [docs/internals/zig-0.17.md](../internals/zig-0.17.md) §16 and
  `tools/zig-next.py` cover it. On Zig 0.18, whose LLVM vectorizes
  again, `widen` moves back into Rig as a plain loop
  ([ROADMAP](../ROADMAP.md)).
- **Zig's `@memset` of a nonzero `U64` stores one cell at a time,** so
  an empty cell is 0, and a scroll clears only the cells written
  (`ends`).
- **Styles past 32 are found by key.** A linear search made truecolor
  output crawl.
- **History reserves its room up front.** Growing the cells one row at a
  time cost the text corpus a third of its speed in reallocations. Most
  of what history still costs (rig-fast vs the `rig-noscroll` experiment,
  about 20% on text) is the first touch of fresh memory in a new
  terminal; a terminal that runs on reuses its oldest rows.
- **Rig's checks are kept.** rig-safe, with every check, runs 4 to 15%
  behind rig-fast and still ahead of every Ghostty build; the
  `rig-nocheck` experiment sizes what bounds checks cost.

## What is not built

- **A reading API for a renderer:** cells, styles, the cursor, and which
  rows changed. Today the screen is read only through `dump` and
  `history_row`. A program that draws the screen needs this first.
- **OSC:** titles, palette and color queries (OSC 4, 10, 11),
  hyperlinks (OSC 8), the clipboard (OSC 52), semantic prompts (OSC 133,
  which change ED 2 at a prompt in Ghostty). Strings are read to their
  end and ignored.
- **DCS:** DECRQSS, XTGETTCAP. They are parsed and ignored.
- **Modes that only record:** mouse reporting (1000 to 1016), focus
  (1004), bracketed paste (2004), synchronized output (2026), and the
  other private modes are kept for DECRQM and XTSAVE but do nothing.
  Their events belong with input, which is `std.tty`'s side.
- **Side margins** (DECLRMM, DECSLRM), **resize and reflow**, and
  window operations (`CSI t`).
- **Out by decision:** kitty graphics, sixel, double-width lines.

`--fuzz --all` shows these as differences, and each becomes an area in
`AREAS` with its cases when it is built.

## Next

The order is the owner's to choose; ask before starting any of these:

1. The reading API, which any use of the library needs.
2. OSC, then mouse and focus reporting, hyperlinks, and OSC 52.
3. Resize and reflow.
4. `std.tty`, terminal I/O (raw mode, size, PTYs), last by the owner's
   plan.
5. On Zig 0.18.0's release, move `widen` back into Rig and measure the
   plain loop.
