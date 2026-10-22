# Follow-up: `check --facts=sema` panics on SPEC.md block at L5516

Found by test/equiv.py (section `sema(failed)`), identical in the old
and new compiler, so unrelated to PR #120.

Command (the block extracted by equiv as `.equiv-docs/SPEC/L5516/main.rig`,
the ```rig block at SPEC.md line 5516):

    bin/rig check --facts=sema .equiv-docs/SPEC/L5516/main.rig

Panic:

    panic: index out of bounds: index 208, len 205
    src/sema.zig:1231:32 in writeFactsDump
        for (ctx.source[span.start..@min(span.end, span.start + 40)]) |c|
    src/main.zig:189:48 in main

A fact's span starts past the end of the source (208 > 205), probably a
span from another module's or a rewritten node's source. A compiler
panic is a bug even in a dump mode: clamp or diagnose, and find why the
span is out of range. Saved outputs: the equiv `--keep` files
`.equiv-docs__SPEC__L5516__main.rig.sema.{old,new}`.
