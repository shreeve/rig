# Rig feature census, 2026-10-31

Counts of each Rig feature in eight Rig programs (Trig, loco, and the six Rust ports in
`~/Data/Code/rig/compare/rig/`), with Rig's std as a reference column. The counts are pattern
matches over code with comments and string contents removed, not parses. Doubtful patterns
were spot-checked against real lines; two were fixed (module-qualified API objects, and a
compile-time-call row that was really indexing, dropped). The script was not kept.

"programs" counts the eight programs (std excluded) that use the feature at least once.

| group | feature | programs | trig | loco | coreutils | sanstun | mini-redis | bench-game | ray-trace | lists | std |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| | code lines | | 147,129 | 2,109 | 12,516 | 3,601 | 763 | 1,168 | 237 | 523 | 6,041 |
| ownership | move <x | 7/8 | 1,553 | 63 | 199 | 193 | 87 | 5 | · | 48 | 61 |
| ownership | clone +x | 7/8 | 749 | 23 | 3 | 9 | 24 | 7 | · | 11 | 7 |
| ownership | write lend !x | 8/8 | 46,119 | 275 | 2,404 | 1,017 | 259 | 141 | 34 | 257 | 1,004 |
| ownership | explicit read lend ?x | 8/8 | 17,021 | 87 | 543 | 487 | 30 | 39 | 16 | 38 | 209 |
| ownership | fixed binding =! | 1/8 | 3 | · | · | · | · | · | · | · | · |
| ownership | drop(!@) body | 1/8 | · | · | · | 2 | · | · | · | · | 9 |
| ownership | keeps clause | 1/8 | 9 | · | · | · | · | · | · | · | 8 |
| ownership | from (result view) | 7/8 | 142 | 8 | 11 | 15 | 5 | · | 4 | 7 | 34 |
| ownership | from @field | 5/8 | · | 1 | 1 | 1 | 2 | · | · | 4 | 8 |
| ownership | write-view result -> !T | 2/8 | 4 | · | · | 1 | · | · | · | · | 6 |
| ownership | once closure param | 2/8 | · | · | 9 | · | · | · | · | 1 | 1 |
| holding | box ^T / ^x | 4/8 | · | · | · | 2 | · | 4 | 2 | 13 | · |
| holding | counted *T (type) | 5/8 | 4 | 12 | · | 5 | 34 | · | · | 21 | · |
| holding | weak ~T / ~x | 2/8 | · | · | · | 2 | · | · | · | 3 | · |
| holding | Cell | 3/8 | 2 | 5 | · | · | · | · | · | 14 | · |
| holding | *Frozen | 1/8 | · | · | · | · | 8 | · | · | · | · |
| closures | closure literal |..| | 8/8 | 570 | 12 | 62 | 16 | 6 | 10 | 1 | 9 | 60 |
| closures | capture mode |+x ?x !x <x ~x | 8/8 | 281 | 4 | 26 | 21 | 10 | 9 | 2 | 1 | 1 |
| closures | field capture |?@f| | 2/8 | 3 | · | 2 | · | · | · | · | · | · |
| closures | owned closure *fun / *| | 1/8 | 16 | · | · | · | · | · | · | · | · |
| closures | closure view ?fun / ?sub | 2/8 | 160 | · | · | · | · | · | · | 9 | 17 |
| types | generic fun/sub [T] | 5/8 | 108 | · | · | 1 | 1 | · | 3 | 9 | 21 |
| types | generic obj/enum [T] | 3/8 | 23 | · | · | 1 | · | · | · | 19 | 13 |
| types | api declaration | 1/8 | · | · | · | · | · | · | 1 | · | · |
| types | add X: Api | 0/8 | · | · | · | · | · | · | · | · | · |
| types | obj X: API (incl. Eq/Ord/Print) | 3/8 | · | · | · | 12 | 1 | · | 1 | · | 6 |
| types | bound [T: Api] | 4/8 | 47 | · | · | 1 | · | · | 3 | 8 | 15 |
| types | API object ?{A} ^{A} *{A} | 1/8 | · | · | · | · | · | · | 1 | · | · |
| types | compile-time fun f[n] (no parens) | 2/8 | · | 1 | · | · | · | 4 | · | · | · |
| types | Table / Slot | 1/8 | 55 | · | · | · | · | · | · | · | · |
| types | Simd | 4/8 | 1 | · | 2 | · | · | 8 | 1 | · | 23 |
| types | symbol :name | 1/8 | · | · | 446 | · | · | · | · | · | · |
| types | several results -> (A, B) | 6/8 | 109 | 10 | 36 | 16 | 6 | · | · | 12 | 28 |
| types | $builtin ($size $name ...) | 1/8 | 11 | · | · | · | · | · | · | · | · |
| errors | error set declaration | 5/8 | 23 | 1 | 3 | 2 | 5 | · | · | · | 8 |
| errors | named set T!E | 6/8 | 7 | 3 | 12 | 34 | 10 | · | · | 4 | 11 |
| errors | catch | 6/8 | 37 | 14 | 175 | 44 | 11 | 8 | · | · | 1 |
| errors | catch |e| | 5/8 | 18 | 8 | 124 | 28 | 6 | · | · | · | · |
| concurrency | dispatch f(x)& | 5/8 | 2 | 3 | · | 2 | 8 | 7 | · | · | · |
| concurrency | wait >t | 5/8 | 2 | 3 | · | 2 | 4 | 8 | · | · | · |
| concurrency | Tasks / par | 4/8 | · | 3 | · | · | 1 | 14 | 1 | · | · |
| concurrency | Actor | 1/8 | · | · | · | · | 11 | · | · | · | · |
| concurrency | channel / select | 0/8 | · | · | · | · | · | · | · | · | 8 |
| control | match | 6/8 | 840 | 17 | 110 | 46 | 21 | · | 1 | · | 21 |
| control | defer | 3/8 | 1 | 2 | · | · | 3 | · | · | · | 4 |
| control | label $l: | 1/8 | 3 | · | · | · | · | · | · | · | · |
| control | if x as y / while as | 8/8 | 2,056 | 40 | 199 | 32 | 18 | 3 | 2 | 26 | 27 |
| escape | raw block | 4/8 | 16 | 1 | 4 | 21 | · | · | · | · | 2 |
| escape | extern | 2/8 | · | 1 | 4 | · | · | · | · | · | 21 |
| speed | inline fun | 2/8 | 8 | · | · | · | · | · | 1 | · | 85 |
| speed | called fun | 4/8 | 24 | 3 | 43 | 2 | · | · | · | · | · |
| speed | rarely | 3/8 | 7 | · | 7 | 1 | · | · | · | · | 2 |

## By breadth

- **In 5 to 8 programs (the core):** move, clone, read and write lends, `from` result views
  (7/8), `from @field` (5/8), `*T`, closures with capture modes (8/8), generic functions,
  several results (6/8), error sets with `catch |e|`, tasks `f(x)&`/`>t` (5/8), `match`,
  `if x as y` (8/8).
- **In 1 to 4 programs:** boxes `^T` (4), weak `~` (2, 5 sites), `Cell` (3), `*Frozen` and
  `Actor` (mini-redis only), `keeps` (Trig only, 9 sites), `once` (2), owned closures `*fun`
  (Trig only), user `api` declarations (1: ray-tracing's `Hittable`), API objects (1 line,
  `ray-dyn.rig`, a variant written to show them), `Table`/`Slot` (Trig only), `Simd` (4),
  symbols `:name` (coreutils only, 446 sites in its argument parser), compile-time functions
  (2), `=!` (3 sites), labels (3), `raw` (4).
- **In no program:** `add X: Api`, channels and `select` (std only).

## The SPEC's cost of the rarely used features (lines)

API objects 513, APIs 379, Bounds 185 (built-in bounds `[E: Copy]`, `[K: Hash]` are used
widely), Several results 278, Cell 226, Declared sets 227, Vectors 173, Boxes 166, Owned
closures 158, Compile-time functions 137, Actors 119, Function markers 117, Table 102,
Symbols 101, Weak handles 72, Channels 64, Frozen values 63, Closures called once 43.

## Against the 2026-10-28 panel

That census (std, the examples, Trig) and its three-expert panel recommended cutting nothing
and freezing `*{A}`, `~{A}`, `once ?fun`, and user `api`/`add`; the owner approved it
([feature-cut/verdict.md](../feature-cut/verdict.md)). The six ports, written since, are new
evidence, and they mostly confirm the panel: each rare feature found the use it predicted,
weak handles for sanstun's lease map and the lists' back links, `*Frozen` as mini-redis's
`Bytes`, boxes in four programs, an API object for the mixed-type scene. They also confirm the
volume picture: one user `api` and no `add` in about 18,800 code lines of ports, where Rust code is full
of traits.
