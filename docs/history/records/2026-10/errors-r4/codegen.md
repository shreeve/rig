# R4: where `JsonError`'s time went (2026-10-22)

The owner, relayed by Rig: "investigate the codegen cost first,
time-boxed to about half a day; if nothing simple turns up, keep parse
returning Bool for the hot path and add a fallible wrapper beside it."
timing-1.md is the run that started it.

## What the code is

The emitted Zig of the two parsers differs only in `parse`: its
signature (`__out: rig.ErrSlot`, `JsonError!void` for `bool`), its
failing tail (`rig.failWith` of the fields), the two reset stores it no
longer makes, and `Error`'s values, one fewer without `ok`. Every
function keeps its inline marker. In the disassembly (arm64, both
`rig-safe` and `rig-fast`), the parser's hot functions are the same
instructions: `skip_plain_ascii`, `utf8_text` and `escaped` are
identical once addresses are masked, and `document` differs by one
instruction, a store of the renumbered `Error`. So there is no codegen
cost:

- The error union does not widen a hot return. Only `parse` returns one,
  once per document, and the bench inlines it.
- Inlining does not change.
- `__out` reaches no inlined frame but `parse`'s own.
- The failure tail is outside the loop, as before.

## What moved

1. **The bench itself (most of it).** The new bench's `main` printed the
   error whole (`print("error", e)`), the old one its name and offset.
   Printing an error value pulls in its glue's print, about 2.4 KB
   (`rig.runtime.outValueOf`), placed before the parser, so every hot
   function started 2,156 bytes later. That alone made `rig-fast` 2.2%
   to 3.1% slower on twitter and citm_catalog on the Mac. With the
   bench printing the same in both, `rig-fast` is within 0.4% on every
   file on the Mac, and within 1.4% (or faster) on pup.
2. **Placement (the rest).** With equal benches, `rig-safe` puts the
   hot functions 4 to 8 bytes earlier (`escaped` from 0x43600, a
   512-byte boundary, to 0x435fc), and twitter is 2.0% to 2.4% slower
   on both machines. The old parser shifted 24 bytes the other way, by
   a cold-path-only change, is not slower (3,647 against 3,641 MB/s).
   So the cost is where the code lands, not what it is, and no simple
   change controls that.

## For Trig's `T!` frames

Nothing here is a general cost of a fallible function: a hot `T!E`
call pays no register or inlining price that this could see. Two
things are worth knowing:

- Printing an error with fields (`print(e)`) brings in its glue's print,
  a few KB of cold code. That moves hot code that follows, the same
  5-7% lottery any code motion on Apple cores is ([RIG-NOTES](../../../rig-notes.md)).
- A benchmark that compares API shapes must give both sides the same
  cold paths, or it measures the cold paths' size.

## The route taken

`rig-safe` twitter stays past the 2% gate, so the owner's fallback
applies: `parse` keeps answering a `Bool`, with `doc.error` and
`doc.error_pos`, and a fallible wrapper beside it fails with
`JsonError.bad(kind:, at:)`. The benchmark, and every caller that keeps
`parse`, compile to the same code as before. The spec's
`error_pos and fail go` is not taken.

The §7.1 fact R4 built first stays: `error` carries fields only where
a member's can reach it.
