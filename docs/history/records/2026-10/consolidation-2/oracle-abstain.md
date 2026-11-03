# Why the oracle abstains (measured 2026-10-23, Rig main c7b047ca1, Trig main 0bac3fa)

Measurement only. Worktree `oracle-abstain-measure`, temp instrumentation (a `[[detail]]` per
abstention: the type, callee, or name at the abstain site) discarded. `bin/rig-oracle -v --stats`
over the suite's own lists (`.zig-cache/rig-tests/oracle/{tests,docs}.list` written by
`swarm test/rig.rip oracle`), the matrix (`test/matrix.py --oracle --keep`), and Trig: one root
program that `use`s all 34 `src/` modules (a superset of `tools/trig/main.rig`'s closure, 9705 of
its functions).

## Headline

| set | functions | decided | abstained | abstained % |
|---|---:|---:|---:|---:|
| tests (`test/rig/*.rig.test` + examples/) | 23185 | 22304 | 881 | 3.8% |
| docs (doc examples) | 1202 | 1031 | 171 | 14.2% |
| matrix | 73370 | 71930 | 1440 | 2.0% |
| **Trig** (all src modules) | 9853 | 5171 | **4682** | **47.5%** |

Trig's abstentions are one cause: 4443 of 4682 (95%) are "a function or closure value".
`vfs.Host` holds five plain `fun(...)` fields (src/vfs/vfs.rig:115-127); every type that reaches
one (`Checker` through `?compiler.Program`, `vfs.FS`, `Program`, `System`, `CheckerPool`) is
"unsupported" in kinds.zig:205, so every function that has `!Checker`/`?Checker` (or a local of
those types) abstains. CORE §7 already settles this case: "A function value is an address ...
holds nothing, so it moves and shares as an `Int` does". Map/Set are the second cause in Trig, but
a much smaller one.

## Reasons × counts (classified)

Class | tests | docs | matrix | Trig
---|---:|---:|---:|---:
Function-typed value or field (`fun` inside a type) | 34 | 4 | 0 | **4443**
Map/Set (std `__rig_builtin` generics) | 61 | 21 | 0 | 95 (169 once the row above is fixed)
Generic instance, not Map/Set (user or std: `sort`, `iter`, `OrderedMap`, ...) | 157 | 11 | 682 | 52
Tasks/actors (`>t` on `Task`/`Tasks`, `Actor[X].m`, `Chan.on_recv`) | 126 | 41 | 0 | 0
Compile-time (ct params unbound, ct args, constants) | 117 | 15 | 5 | 7
Write views / lends (receiver without `!`, index lending root to write, ...) | 115 | 18 | 475 | 14
Untyped / unusual IR (`block` without type, `for` without binding, `<<%`) | 100 | 39 | 47 | 59
`raw` | 67 | 12 | 99 | 2
Closures (drop-carrying capture, stack closure stored, bare fn value) | 40 | 3 | 0 | 3
Other handle/iterator methods (`^List.push`, `It.f`, `Hold.f`) | 31 | 4 | 114 | 6
Other | 33 | 3 | 18 | 1
**Total** | 881 | 171 | 1440 | 4682

Raw reasons, suite (tests / docs): a method reached through a handle 157/45 (126+41 of them on
Task/Actor/Chan), a name the lowering did not bind 98/12 (ct params), a generic instance at a view
70/9, `raw` 65/12, a generic type at an owner whose methods copy a `T` 54/16 (47+16 are Map/Set),
a generic instance at an owner or a view 52/6 (14+5 Map/Set), ... at an owner whose body copies a
`T` 40/1, an expression without a type: block 39/10, a function or closure value 34/4.
Matrix: generic instance at owner-or-view 300, write receiver without `!` 253, owner whose body
copies a `T` 194, index lending its root to write 193, generic instance at a view 182.

## Examples (file:line, function)

- **Function-typed fields** (Trig): checker/expressions.rig:6244 `Checker.check_array_literal_assignment`
  (`@: !Checker`); checker/aliases.rig:1073 `create_module_not_found_chain_details`
  (`program: ?compiler.Program`); checker/store_generated.rig:2612
  `Checker.set_type_alias_links_type_parameters`. Root: src/vfs/vfs.rig:115 `pub read: fun(?String) -> String?`.
- **Map/Set**: test/behavior/std/hash_results.rig:1 `count` (`Map[String, Int]`, owner whose methods
  copy a `T`); doc/learn-06-stdlib/05e9a80ac482:9 `report` (`Map[?String, Int]`, instance at a view);
  Trig ast/ast.rig:970 `Ast.collect_identifiers_for_source_file` (`Set[String]`).
- **Generic instance, not Map/Set**: test/reject/ownership/holder_view_locks_owner.rig:7 `main`
  (`same` at `?List[Int]`, at a view); test/reject/ownership/cell_holder_generic_copy.rig:10 `main`
  (`keep` at `*Counter`, body copies a `T`); doc/STD/db17cf48140e:7 `main` (`sort.sort_by` at
  `Player`); Trig core/compileroptions.rig:192 `CompilerOptions.get_paths_base_path`
  (`collections.OrderedMap[String, List[String]]`).
- **Tasks/actors**: test/behavior/concurrency/chan_producer_and_consumer.rig:15 `main` (`Task[Void!].>`);
  test/behavior/concurrency/actor_supervised_restarts.rig:15 `main` (`Actor[Rooms].add`);
  doc/README/b27776a6efab:16 `main` (`Actor[Bank].pay`).
- **Compile-time**: test/behavior/types/comptime_param_args.rig:5 `show` (ct param `n`);
  doc/learn-07-generics/34aed4ca2d2b:5 `Recent.add` (`n`).

(Suite paths are case programs as the suite names them; docs are `doc/AREA/hash:line` keys.)

## Experiments: what each step would add (temporary changes, discarded)

**E1 — a bare `fun` type is plain data** (kinds.zig: `.function => {}`; `.callable` still marks).
Decided: Trig 5171 → **9465 (+4294; abstentions 47.5% → 3.9%)**, tests +11, docs 0, matrix 0.
Cost: Trig's prod-accepts differences go 6 → 50 (+44). 33 of the 44 are one shape: C4 "cannot write
`@` while a read loan of it is live", carried by `tree = ?@program.files[i].ast` across a `(!@)`
call (checker/contextual.rig:606). `program` is a read-view field (`?compiler.Program`,
checker/checker.rig:35), so `tree` views the Program, not `@`. Rust's NLL accepts this too: a
borrow through a shared-ref deref doesn't keep the base borrowed. The likely class is the oracle
lending `@` for a path through a read-view field, which needs a ruling. The suite has no such
case, so the suite stays green either way.

**E2 — Map/Set/Item instances pass, their methods checked by declared signatures** (on top of E1).
Decided: tests +35, docs +7, Trig +145 (9610). Cost: **3 new suite DIFFs, which would fail the run**
(assign_through_returned_view.rig `main` C4, origin_self_path_items_held.rig `both` C4,
origin_self_path_temporary_iterator.rig `main` C5) and 9 in Trig, all C6 "a view of `key` leaves the
function, whose `from` does not name it" (e.g. symlinks/knownsymlinks.rig:45, module cache `get`s).
The cause: the oracle's sentence-7 reach is by type alone. `m.get(k)` with K = V = String looks
like it may view `k`, though CORE §5 says the result is `from @` and carries the loan on `m` only.
The two baseline Trig DIFFs `CopyOnWriteMap.get` (collections/cow.rig:64) and `MultiMap.get`
(collections/multimap.rig:14) are the same shape in user generics. E2 also passes Map instances at
views unchecked, so the real step must make a `Map[?String, V]` carry its keys' loans, as List does.

## Ranked plan (gain = newly decided functions, measured)

1. **Plain `fun` values are plain data** (CORE §7 "A function value is an address"). Change: 1
   line in kinds.zig plus tests. Then triage the 44 new Trig differences: one ruling covers ~33
   (a path through a read-view field lends what the view views, not `@`). The rest are ~10
   assorted. **Gain: Trig +4294 (to 96% decided), suite +11.** Small to medium. Highest return by far.
2. **Honor a callee's `from` in sentence 7** (a result `from @` carries only the receiver's
   loans), in instances and in generic bodies. Medium. It is the prerequisite for step 3, and it
   should clear the 2 baseline Trig C6 DIFFs plus the 9 E2 ones.
3. **Map/Set by their signatures, as a container like List** (put/insert join loans, get/edit
   carry `from @`, take hands back owned). Medium. **Gain: suite +42 (tests 35, docs 7), Trig
   +145.** Map/Set alone is small for the suite: 82 abstentions in all, and some of those then stop
   at the next reason.
4. **Tasks/actors**: `>t`/`>ts` as an owned result, `Actor[X].m` as a call through the handle
   (Core s8). Medium. Gain up to 167 suite functions (126 tests, 41 docs; docs coverage 14% → ~10%
   unknown).
5. **Compile-time params as plain constants**: small to medium. Up to 132 suite functions.
6. **General generic instances at views, or at owners whose body copies a `T`**: large
   (per-instance checking, SPEC "Generic bodies"). Up to 168 suite, 682 matrix, ~110 Trig
   (OrderedMap 60). Biggest remaining suite/matrix class, but the most work. Do it after 1–3.

`raw` (180 across sets) is by design. Write-view and untyped-IR items are scattered: each is a
small fix worth a few dozen functions.

## Also found

- **6 prod-accepts differences in Trig today**, which no suite run sees: `core.or_else` and
  `core.coalesce` (C2, core/core.rig:373 `if value as v; return v` in a generic body),
  `collections.CopyOnWriteMap.get` and `MultiMap.get` (C6, the `from @` reach above),
  `parser.Parser.parse_jsx_element_or_self_closing_element_or_fragment` (C1 "use of `lc` after
  move"), and `printer.TextWriter.write_line_raw` (C9). Each needs classifying as an oracle
  imprecision or a compiler hole.
- The `tests` floor (22298) is 6 below today's 22304.
