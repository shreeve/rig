# Proposal: share std.json's general routines through std

From Trig (owner-approved to write up), coordinated with the json.rig
session, which owns std.json. 2026-10-12.

## Principle

No `std.simd`: `Simd[T, n]` is already the language's vector type. A fast
routine that is general moves to the module named for what it does. The
condition on every move: **std.json does not get slower** (the JSON
benchmark guard unchanged, plus one interleaved Mac window and one pup
run).

## What moves, and when

| std.json routine (std/json.rig) | What it is | Home | When |
|---|---|---|---|
| `utf8_end`, `utf8_end3` (:729, :761) | RFC 3629 validation, 3-byte fast path | new `std.utf8` | now |
| `push_utf8`, `push_utf8_two3` (:771, :784) | UTF-8 encoding into a String | `std.utf8` | now |
| `take_digits`, `take_last_digits`, `eight_digits` (:625-:661) | 8 digits per multiply | `std.text` radix parse (already approved) | later: keeps `m: !U64` (or multiple results, RIG-NOTES 9) and the split that keeps it inlinable |
| `skip_plain_ascii` (:681) | find the first byte in a class: SWAR, then 16 lanes, then an overlapping tail | `std.text.find_any` | after json.rig settles it (bitmap after inlinect; lookup after simd2) |
| `skip_space` (:600) | skip a byte class, 8 spaces per U64 compare | the same search | same |

The scan and space routines stay private for now: their tiers are tuned
to JSON (TIER = 16 from JSON's string lengths) and both are about to
change; a hot loop's layout moves time 5-7% (RIG-NOTES 21), so they move
once settled. json.rig moves them itself.

## std.utf8 (the first step)

Encoding only; properties stay in `std.unicode` (#161). Contents:
- `end(s, at) -> Int`: the end of the valid sequence at `at`, or -1
  (std.json's `utf8_end`, with its fast path).
- `utf8.push(!out, c)` (std.json's `push_utf8`), and the two-rune form.
- The approved runes helpers (`proposal-small-spellings.md` item 22:
  `rune_at`, `rune_before`, `runes`, `Rune(code, size)`), here rather
  than in std.text.
- Later, from the owner's utf8-index library (ideas, not code): `count`
  and `is_ascii` with SIMD fast paths, and a sparse index from a unit
  (code point, or UTF-16 for JS positions) to a byte offset.

All inline. std.json then calls `utf8.end` and `utf8.push`; its emitted
Zig for those call sites should be byte-identical (checked by `rig emit`
diff), and the guard confirms it.

## The general search's shape (for the later step)

`find_any[class: ByteSet, swar: Int, lanes: Int](s, at) -> Int`: `class`
a compile-time value folded into compares (LLVM must still fuse
`< 0x20 | >= 0x80` into one signed compare), always instanced and
inlined (needs #154 inlinect's per-instance inlining), with the
overlapping tail kept. Users: std.json, Trig's lexer (identifier runs,
whitespace, string/comment/template bodies; already 1.66x tsc's Go
scanner), any Rig parser.

## Owner questions

1. Approve `std.utf8` now, built by the foreman, reviewed and timed by
   json.rig? Recommend yes.
2. Should the runes helpers (item 22) live in `std.utf8` rather than
   `std.text`? Recommend yes: encoding in one place, properties in
   `std.unicode`.
3. Spellings: `utf8.end(s, at)`, `utf8.push(!out, c)`, `utf8.count(s)`,
   `utf8.is_ascii(s)`. Alternatives: `utf8.valid_end`, `utf8.add(!out, c)`.
4. Approve the later steps in principle (digits into std.text, the
   byte-class search), each gated by the guard and json.rig's sign-off?
