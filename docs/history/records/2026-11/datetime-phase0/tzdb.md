# The zone tables: generator, layout, size and build time (datetime Phase 0)

The Mac, Apple M5. Rig `datetime-p0` from main 901544ab0, Zig 0.17.0.
The generator is `tools/gen-tzdb.py`; the measuring programs, the shim and
the check are in [tzdb/](tzdb/). Nothing here is in `std/`: the tables are
committed in Phase 4.

## The generator

`tools/gen-tzdb.py [--cache DIR] [--check] [OUT]` writes three files to OUT
(default `zig-out/tzdb`, which git ignores):

| File | Holds | Bytes of Zig |
|---|---|---|
| `tzdb_data.zig` | the zones, the types, the rules, and per name its zone, its primary identifier and where it starts in the names | 318 KB |
| `tzdb_names.zig` | the 598 names, one a line (`\\Africa/Abidjan`), for the compiler's literal check | 13 KB |
| `tzdb_test_data.zig` | the test table: Europe/Dublin in the standard form, and Test/Morocco | 5.5 KB |

- **Inputs**, pinned by exact version and sha256, fetched into
  `$RIG_TZDB` or `~/.cache/rig-tzdb` when absent, as `tools/gen-unicode.py`
  fetches its own:
  - `jiff-1.0.0.crate` and `jiff-tzdb-1.0.0.crate` from crates.io; the sums
    are the crates.io index's `cksum`. Each crate is read as an archive in
    memory and never unpacked or built.
  - `europe-dublin.tzif`, Jiff's test file of Dublin in the standard form
    (footer `IST-1GMT0,M10.5.0,M3.5.0/1`), from Jiff's repository at
    3b1bdf9d7, the commit both crates were published from. The crates'
    `.cargo_vcs_info.json` must name that commit, so the test file and the
    crates are one version of Jiff. The crate itself leaves its test files
    out.
  - The made-up Morocco rule, `XXX-2<+01>-1,0/0,J365/23` (permanent
    daylight saving, Jiff's issue 386), is written in the generator, which
    fails unless jiff's `src/tz/posix.rs` still holds it.
- **What it reads:** jiff-tzdb's `concatenated-zoneinfo.dat` (207,040
  bytes: one slim TZif file per distinct zone) and `tzname.rs` (598 names,
  version 2026f); jiff's `src/tz/db/metadata.rs` for the primary
  identifiers (598, of which 148 differ from their name; every primary is a
  name and its own primary).
- **As Jiff reads a zone** (jiff-core `tz/tzif/parser.rs`, `query.rs`,
  `tz/posix.rs`): type 0 before the first transition; a transition's type
  until the next; the footer's POSIX rule from the last transition on, and
  for all time in a zone with no transitions (29 of them). Every zone in
  2026f has a footer. The POSIX parser takes Jiff's grammar for footers
  (IANA v3+: rule times -167 to 167 hours). The daylight-saving flag is
  dropped, since Rig decides by offsets: 589 TZif types become 557.
- **It refuses**, with the zone and what is wrong: a file not version 2+,
  leap seconds, bytes after the footer, transitions out of order, a type
  index out of range, a footer Jiff's grammar rejects, names out of
  caseless order, metadata naming other zones, and a transition outside
  the layout's range (below).
- `--check` writes nothing and exits 1 when a file in OUT is missing or
  differs. A run takes 0.8 s (0.1 s of CPU) with the inputs cached.

## The layout

| Table | Entries | Bytes |
|---|---|---|
| `times` (u32) | 17,084 transitions | 68,336 |
| `transition_types` (u8, a zone-local type) | 17,084 | 17,084 |
| `zones` (first, count, early, types: u16; rule: u8) | 345 | 3,450 |
| `zone_types` (u16, into the shared types) | 1,500 | 3,000 |
| `type_offsets` (i32 s) and `type_abbrs` (u8) | 557 | 2,785 |
| `abbr_text` and `abbr_starts` (u16) | 178 abbreviations | 1,001 |
| `rules` (28 bytes each) | 94 | 2,632 |
| `name_starts`, `name_zones`, `name_primaries` (u16) | 598 | 3,590 |
| names text (`tzdb_names.zig`) | 598 | 9,101 |
| **All** | | **110,979** |

Why:

- **Transitions are a u32 each, in two sorted halves.** A zone's first
  `early` transitions, those before 1970, are held as t + 2^32, the rest as
  t. Each half is a plain sorted array that a binary search reads with no
  decoding, and four bytes cover 1833-11-24 to 2106-02-07; the data spans
  1844-12-31 to 2086-10-25. An i64 would take 68 KB more (179 KB in all),
  and i32 seconds cannot hold 1845 or 2086. Minutes do not work: 384
  transitions fall off the minute in UTC, and 55 even in the wall time
  before them. The generator refuses a transition outside the range, so a
  future tzdb that needs more says so.
- **Types are shared, indexed per zone.** A transition's type is a u8 into
  its zone's run of `zone_types` (at most 11 in a zone), so 17,084
  transitions take one byte each rather than two.
- **Zones are deduplicated:** the 598 names share 345 zones, as
  jiff-tzdb's byte ranges do.
- **Names are sorted caselessly** (Jiff's order), so `named` is a binary
  search with no hashing and no table of its own; `name_starts` cuts the
  names file, so no slice table of 16-byte pointers is needed.
- **The rule is parsed**, so nothing is read from text at run time: each
  end is a kind (`Jn`, `n`, `Mm.w.d`), its numbers, and a local time in
  seconds.
- Against the bundle: 110,979 bytes of tables for 207,040 bytes of TZif,
  and the design's estimate of about 210 KB.

## Size in a program

`tzdb/measure.py` copies std to a work directory and adds the shim
(`tzdb/tzdbx.rig`, `tzdb/tzdbx.zig`) and the generated tables there, then
builds with `bin/rig build --release` and `RIG_STD` set to that copy. The two
programs read the same arguments: `tzdb/zone.rig` prints a zone's offset at
an instant, found by name through the shim (it links the names, the zones
and the rule code); `tzdb/none.rig` prints the instant plus the length of the
name and does not use the module.

| Program | Executable | `__TEXT,__const` | `__TEXT,__cstring` | `__TEXT,__text` |
|---|---|---|---|---|
| none.rig | 460,888 | 17,296 | 4,460 | 261,868 |
| zone.rig | 576,664 | 116,432 | 13,579 | 265,072 |
| **difference** | **115,776** | 99,136 | 9,119 | 3,204 |

- The tables are 108 KB of the 113 KB a program grows by: the arrays in
  `__const`, the names and abbreviations in `__cstring`. The search, the
  caseless name match and the rule's calendar code are 3.2 KB of code.
- The design estimated about 210 KB of data with the layout unsettled; this
  layout is about half that. With i64 transitions it would be 68 KB more.
- `zone` prints -18000 for New York at 1,700,000,000 (2023-11-14, EST).

## Build time

The same two builds under `tools/mac-claim`, after a plain `tools/heavy zig
build` (bin/rig was current), interleaved none, zone, none, zone, 7 rounds,
each from an empty package directory (`RIG_OUT_DIR` removed), so Zig
compiles the program and the tables every time; Zig's global cache, shared
by both, stays warm.

| Build | Fastest of 7 | All rounds (s) |
|---|---|---|
| none.rig | 3.318 s | 3.634 3.318 3.337 3.353 3.349 3.832 3.469 |
| zone.rig | 3.388 s | 3.388 3.482 3.399 3.446 3.448 4.266 3.448 |
| **difference** | **0.070 s (2.1%)** | |

The 0.07 s includes the shim's code, which is small. none.rig does not
import the module; whether a `use` with no call costs anything was not
measured here (the builder review found unused tables dropped).

## The check

`tzdb/check.py TABLES CACHE [ZONE]` reads the generated Zig back and checks
it against the zone files in the jiff-tzdb crate, read by its own TZif
reader and by Python 3.14's `zoneinfo` (`ZoneInfo.from_file` on the crate's
bytes), never the machine's zone files:

- **The six sample zones** (America/New_York, Australia/Lord_Howe,
  Pacific/Apia, Antarctica/Casey, Africa/Monrovia, Europe/Dublin): every
  transition's instant, offset and abbreviation, and the type before the
  first, equal to the crate's file. Then the offset, from the tables with
  the rule read as Jiff reads it (a Python port of `dst_info_utc` and
  `in_dst`), against zoneinfo: at each transition and a second either
  side, every three hours from the last transition to 2200, and a second
  either side of each change of the rule.
- **All 598 names:** offsets at each transition and a second either side,
  and on January 1 and July 1 of every year 1800 to 2200; each name's
  primary identifier against metadata.rs.
- **The test table:** Dublin against the pinned file the same way;
  Test/Morocco at +01:00 at the start, the end and the middle of 1970,
  2026, 2087 and 2199 (Jiff's test: daylight saving all of 2087).
- **The shim:** the built `zone` program at the last 12 transitions (and a
  second before) of each sample zone and at 16 instants from 1900 to 2100,
  with the name in lower case: 222 runs.

Result: **OK**, 3,991,798 instants over the 598 names, 476,035 for the test
Dublin, 222 runs of `zone`, no mismatch. Monrovia's -00:44:30 is exact in
both. The check catches a change: one transition moved by a second gave 2
mismatches (Louisville), and one rule's start moved by a minute, 76.

## For Phase 4

- The shim's search: [tzdb/tzdbx.zig](tzdb/tzdbx.zig) (names, the two
  halves, the rule as Jiff evaluates it) is about 150 lines and agrees with
  zoneinfo above. It works in whole seconds: Jiff's clamp of a rule's end
  to 23:59:59.999999999 is the next year's start there, the same for every
  whole second; a Phase 4 shim given nanoseconds compares the same way.
- `test/cli` will need a freshness test running `--check` against the
  committed tables, as `unicode_tables_fresh.sh` does for gen-unicode.
