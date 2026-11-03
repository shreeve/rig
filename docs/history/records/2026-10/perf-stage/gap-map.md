# Trig against tsrs, a top-down gap map (2026-11-02)

**Status:** its family table groups by machine function and overstates
instantiation; [gap-map-v2.md](gap-map-v2.md) replaces it, by source
function, and the correction below fixes `fam.py`'s tsrs rule. The
scripts and the fixed-rule tables are in [gap-map-data/](gap-map-data/).

pup E-core 13, one checker. Trig is main 07e4447 plus #244 (lexer pass 4), built by Rig 43e1f65 (/tmp/lp4/n). tsrs runs with TSRS_LAZY_DTS=0, --checkerAssignment go and --noLazyMembers, and both give the same output.
- Self cycles come from perf record (prof-item1/run.sh 13, out-gap), scaled to perf stat's user cycles per run.
- Kernel cycles are perf stat medians of 9 runs (kern.sh).
- Families are named the same on both sides: by module (Trig's `lexer.`/`parser.`/`binder.`/`ast.`/`checker.`; tsrs's crates), and inside the checker by keywords in the method name (fam.py).

## User cycles by family

ts-pattern: user Mcycles a run, Trig 4956.9, tsrs 4618.4 (gap 338.6, 6.8% of Trig)
| family | Trig | tsrs | gap | gap, % of Trig |
|---|---|---|---|---|
| check: instantiate/mappers | 1344.3 | 894.6 | +449.7 | +9.1% |
| check: members/properties | 583.0 | 331.8 | +251.2 | +5.1% |
| runtime/std (maps, hash, interner) | 262.1 | 17.1 | +245.1 | +4.9% |
| check: relations | 506.8 | 287.7 | +219.1 | +4.4% |
| check: unions/intersections | 260.8 | 198.7 | +62.2 | +1.3% |
| check: types from nodes | 256.2 | 203.9 | +52.3 | +1.1% |
| check: checking/diagnostics | 82.3 | 54.4 | +27.9 | +0.6% |
| check: inference | 152.9 | 127.8 | +25.1 | +0.5% |
| lex | 23.8 | 13.5 | +10.3 | +0.2% |
| program, paths, output | 45.1 | 40.9 | +4.3 | +0.1% |
| parse | 27.1 | 23.4 | +3.7 | +0.1% |
| other | 4.8 | 6.7 | -1.9 | -0.0% |
| bind | 25.6 | 29.6 | -4.0 | -0.1% |
| check: flow/narrowing | 99.9 | 111.1 | -11.2 | -0.2% |
| alloc + memcpy | 113.9 | 242.7 | -128.8 | -2.6% |
| check: other | 1114.5 | 1449.6 | -335.1 | -6.8% |
| ast (tree access, parents) | 53.7 | 584.8 | -531.1 | -10.7% |

zod3: user Mcycles a run, Trig 927.8, tsrs 828.9 (gap 98.8, 10.7% of Trig)
| family | Trig | tsrs | gap | gap, % of Trig |
|---|---|---|---|---|
| runtime/std (maps, hash, interner) | 58.7 | 8.3 | +50.5 | +5.4% |
| check: members/properties | 113.0 | 64.9 | +48.0 | +5.2% |
| check: relations | 87.9 | 59.8 | +28.1 | +3.0% |
| check: other | 256.8 | 231.2 | +25.6 | +2.8% |
| check: instantiate/mappers | 104.9 | 85.6 | +19.4 | +2.1% |
| check: checking/diagnostics | 47.2 | 28.2 | +19.0 | +2.0% |
| check: types from nodes | 43.6 | 29.4 | +14.2 | +1.5% |
| lex | 24.8 | 13.5 | +11.3 | +1.2% |
| program, paths, output | 19.9 | 13.4 | +6.5 | +0.7% |
| check: unions/intersections | 28.4 | 24.1 | +4.4 | +0.5% |
| parse | 27.1 | 23.4 | +3.7 | +0.4% |
| check: flow/narrowing | 22.9 | 20.3 | +2.6 | +0.3% |
| other | 1.3 | 0.9 | +0.5 | +0.1% |
| bind | 25.4 | 26.6 | -1.2 | -0.1% |
| check: inference | 11.5 | 20.6 | -9.0 | -1.0% |
| alloc + memcpy | 23.1 | 51.7 | -28.6 | -3.1% |
| ast (tree access, parents) | 31.3 | 127.2 | -96.0 | -10.3% |

## Kernel and total cycles (median of 9, Mcycles a run)

| project | Trig user | Trig kernel | Trig total | tsrs user | tsrs kernel | tsrs total | gap, % of Trig total |
|---|---|---|---|---|---|---|---|
| ts-pattern | 5015.4 | 433.3 | 5448.7 | 4704.4 | 1510.5 | 6214.9 | Trig 14% fewer |
| zod3 | 918.1 | 115.6 | 1033.7 | 803.0 | 109.3 | 912.3 | Trig 11.7% more |

## Reading

- **The comparison is inexact within the checker.** tsrs inlines much of its work, and its `tsrs_ast` crate holds type and symbol accessors, so tsrs's "ast" family absorbs checker work: 585 Mcycles against Trig's 54 on ts-pattern.
- **Grouped**, the checker side (all check families, ast, runtime/std, alloc) is 4830 against 4504 Mcycles on ts-pattern, 6.6% of Trig's cycles; and 829 against 751 on zod3, 8.4%.
- **The front end** (lex, parse, bind, program) is 0.3% behind on ts-pattern and 2.2% on zod3.
- **Lex** is still 1.2% behind on zod3.
- **Kernel** cycles favor Trig on ts-pattern by 1077 Mcycles a run. tsrs's kernel work there is mostly memory (mimalloc), not traced here. On zod3 they are level.

## Correction (2026-11-02, item 22): fam.py's tsrs rule

`fam.py` (now fixed; the first version is `fam-v1.py`) put a tsrs
symbol in a checker family whenever `tsrs_checker` appeared anywhere in
it, generic arguments included, so hashbrown code monomorphized for
checker types counted as checker work. Classified by the function's own
crate, runtime/std is Trig 262.1 against tsrs 227.0 on ts-pattern
(0.7% of Trig) and 58.7 against 49.2 on zod3 (1.0%). The per-family
tables from the fixed rule are in [instantiation-members-data/](instantiation-members-data/) (`fam-v2.*.txt`).

Self cycles by machine function still mislead within the checker: each
build inlines differently. [instantiation-members.md](instantiation-members.md) compares families by
source function, through inline frames and call stacks. There,
instantiation is level or better (ts-pattern 0.7% ahead, zod3 2.6%
ahead), and members/properties is 3.1% / 3.9% behind.
