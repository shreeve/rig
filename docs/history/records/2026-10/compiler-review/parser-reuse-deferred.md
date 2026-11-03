# Row 37: Nexus's parser reuse, closed for `rig check` (2026-11-01)

Nexus #72 (e089a34) lets a parser parse input after input with `reset(source)`, keeping the
memory it already touched: Nexus measured Rig's parsing 18% faster that way, most of it page
faults avoided. Rig - Swiss closed row 37 for `rig check` (option 1), on Rig language analysis's
reading at 928b44bf2.

## Why it does not fit today's compiler

A reset ends every tree the parser made before it (Nexus docs/SEMANTICS.md, "reset": "A reset
ends everything of the parses before it: their trees and lists, node ids, ... and whatever was
allocated with `allocator()`"). Rig keeps every module's tree for the whole pipeline: modules.zig
holds each module's `Parser`, sema keeps `ctx.parser`, and ownership, storage, and emit read each
module's tree, imported ones included, until the package is written. One parser reset across
modules would overwrite trees still in use.

The prize, even where it applies, is small: `rig check --time` on Trig spent 146 ms lexing and
parsing of 3.49 s before 33A (#834), about 7% of today's 2.14 s, so 18% of it is about 1.2% of a
check, and a long check amortizes the page faults anyway.

## For the rewrite

A pipeline that lowers each module and lets its tree go (or copies what it keeps out of the
parser's arena) can parse every module with one parser and `reset`.

## Idea row (not now)

The language server re-parses the open document on each edit and drops the old tree once the new
one is checked: there a `reset` is safe, and would cut editor latency, not Trig's time.
