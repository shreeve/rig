# Lazy member tables in Trig: exactness and measurement plan

Scope: microsoft/TypeScript#64475 (lazy member tables of instantiated class and interface
references) and #64526 (lazy members of `{ [P in keyof T]: X }` mapped types), ported to Trig as a
departure below the logic (AGENTS rule 7). The bar is that Trig prints what tsc prints at the pin
(`655f0268af`, which has neither PR), at one checker today and at every `--checkers C` later
(CHECKERS.md point 7).

Sources read: tsrs `notes/lazy-members.md`, `notes/mem-lazy.md`, `notes/mem-round3.md`,
`notes/open-history-dependence.md` §6, `crates/tsrs_core/src/lazymembers.rs`,
`testdata/regressions/lazy-*`; Trig AGENTS.md, HANDOFF.md, docs/TESTS.md, docs/DIVERGENCE.md,
docs/checker/DESIGN.md, docs/checker/CHECKERS.md, `src/checker/members.rig` (`get_symbol_id`),
`src/checker/symbolaccessibility.rig` (`compare_symbols`); Go at the pin: `checker.go` 19335-19800,
21174-21440, 22320, 22608, 23508; `links.go`; `utilities.go:390`.

---

## 0. Summary

1. **#64475 can be exact by construction.** In Go at the pin, resolving an instantiated reference's
   members creates *symbols* (one `instantiateSymbol` per declared member), *signatures* and the
   *types* that come from instantiating index infos, fresh signature type parameters and base types.
   The lazy table does the type-creating part at the same moment (`prepareLazyMembers`) and defers
   only the symbols. If the lazy paths themselves create no type, signature or instantiation, the
   sequence of types, and therefore every type id and every history-dependent result, is Go's at
   every checker count. tsrs's monorepo counters agree: types and instantiations are identical with
   #64475 on (9,639,962 / 44,884,281), only symbols drop (25.97M to 17.23M).
2. **#64526 as posted is not exact under Trig's rules.** It skips type creation: eager
   `resolveMappedTypeMembers` creates the key literal types (`getLiteralTypeFromProperty`), the `as`
   clause's name types, unions for duplicate keys, and index-info types (template instantiation);
   the lazy table creates only what a lookup asks for. tsrs measured 9,842 fewer types and 63,573
   fewer instantiations on the monorepo. Fewer or reordered types move type ids, and ids order unions
   (`types.go:506-510`), so a later `"b" | "a"` can print in another order; fewer instantiations move
   TS2589/TS5115 cut-offs. CHECKERS.md point 7 already says every DIVERGENCE row must keep the set of
   created types. So #64526 lands only in an **exact variant** (§1.3) or not at all without the
   owner changing the rule.
3. **Ship order:** #64475 alone, off by default, single-checker first; turned on when the gates of §2
   and §4 pass. #64526-exact is a second switch and a second PR, measured on its own.

---

## 1. Why output can stay identical, and where it cannot

### 1.1 The argument for #64475

What reaches tsc's output, and what each depends on:

| Output | Depends on | Lazy members change it? |
|---|---|---|
| Printed types (`.types`, errors) | type ids (union order), member order, symbol identity | not if types are created in Go's order and tables list members in Go's order |
| `.symbols` | each identifier's resolved symbol, printed by its declarations | no: an instantiated symbol prints through its target's declarations, eager or lazy |
| Diagnostics | relations, inference, flow; history-dependent cut-offs | not if the type sequence and caches are Go's |
| History-dependent diagnostics (CHECKERS point 2): base constraints cut short, cycle entry points, TS2589 depth 100 / count 5,000,000 (`checker.go:22608`), TS2590 first evaluation, TS5115, TS2456 | what the checker created and cached before | yes, the moment a lazy path creates, skips or reorders a type or instantiation |
| Symbol ids | Trig numbers them only in `get_es_symbol_like_type_for_node` (`members.rig:2053`, "No baseline prints such an id") | no: instantiated members never take a Trig symbol id (Go's `valueSymbolLinks.Get` does give every one an id, `links.go:49`, but Trig does not emulate that numbering) |
| `compareSymbols` last tie-break | Trig compares `Sym` handles, i.e. creation order (`symbolaccessibility.rig:295`, already a known departure from Go) | yes, in principle: a lazily made symbol gets a later `Sym` |

The invariant that makes it exact: **(I1)** the lazy table's preparation performs exactly the type,
signature and instantiation work that eager `resolveObjectTypeMembers` (`checker.go:19545`) performs,
in the same order, at the same point (first member query of that reference); **(I2)** every later lazy
operation (single member instantiation, `resolveLazyMembers`, the every-property and has-properties
queries) creates no type, no signature and no instantiation, and does not change `instantiationCount`
or the instantiation stack. (I1) and (I2) are local properties of each table, independent of what
the checker did before, so if they hold, the type sequence equals Go's under any history: any file
order, any partition, any checker count. That is what makes multi-checker exactness follow (§1.4).

### 1.2 Where #64475 could still diverge, and the check for each

| # | Risk | Mechanism | Check that catches it |
|---|---|---|---|
| R1 | Type-creation order | `prepareLazyMembers` instantiating signatures, index infos and bases in a different order from eager (eager: members table, call and construct signatures with fresh type parameters, index infos (their value types instantiated eagerly), base types and inherited signatures and index infos) | **Type trace** (§3.2): per-type `(id, flags, objectFlags, kind, symbol)` and per-signature lines; byte-compare on vs off over the checker corpus and the cli projects |
| R2 | A lazy path that creates a type | e.g. an `isSymbolUnaffectedByInstantiation` that forces a type, or a lazy lookup that instantiates a base | **Invariant counters** `lazy_types_created`, `lazy_instantiations` = 0 (§3.1), asserted in debug packs |
| R3 | The PR's shared refactors change the off path | tsrs notes `isStringIndexSignatureOnlyTypeWorker` switching from `len(getPropertiesOfType(t))` to `hasPropertiesOfStructuredType(t)`, which skips `getReducedApparentType` and so `getApparentTypeOfMappedType` for non-generic mapped types, which can create types. In tsrs this runs in both modes. | Trig's off path keeps the pin's code exactly (§2.2). The on path must keep that call too unless the trace shows it creates nothing. Test: §4, `stringIndexOnlyNonGenericMapped` |
| R4 | Member order | a lazily filled table listing members in lookup order; full resolution must list them in eager order (declared order, then inherited). Go iterates `declaredMembers` as a map in the PR; tsrs uses insertion order; Trig must use the pin's eager order (`createInstantiatedSymbolTable` iterates the declared slice) | TS2739/TS2740 missing-property lists, object types printed in `.types` after a lookup out of order (§4, `lazyMemberOrder`) |
| R5 | Symbol identity | a member instantiated twice (lookup, then full resolution) gives two symbols for one property; relations compare symbols by identity, links and caches miss, instantiation counts move | counter `lazy_reinstantiated` = 0, asserted; tsrs reuses the lazy symbol at full resolution and so must Trig |
| R6 | `MembersResolved` readers | code that branches on `ObjectFlagsMembersResolved` (`IsEmptyAnonymousObjectType`, `checker.go:27078`) sees "unresolved" where eager saw "resolved" | only anonymous types branch today, and #64475 tables are on references; a grep of every `members_resolved` read in Trig, listed in the PR, and the rule that a lazy table never answers such a read without resolving |
| R7 | Recursion guards | a lookup inside an active `pushTypeResolution` or deep in the instantiation stack instantiating a member that eager mode had made earlier; symbols carry no type, so this is safe for #64475, but the `this`-type and base-type paths must run at preparation, not lookup | circular-base and `this` tests (§4) and the trace |
| R8 | `compareSymbols` fallback | Trig's last tie-break is `Sym` order; a lazily made symbol is numbered later | a debug counter of fallback hits where either side is a lazily made symbol; must be 0 on the corpus. If not 0, compare by a per-table reserved `Sym` range (allocate the table's members' handles at preparation) |
| R9 | Go map order in the PR | `prepareLazyMembers`, `resolveLazyMembers`, `everyLazyProperty` iterate a Go map | port onto ordered iteration in eager order (R4); `somePropertyReducesToNever` onto the pin's ordered #64521 version (the pin is after it) |

### 1.3 #64526: why it is not exact as posted, and an exact variant

Eager `resolveMappedTypeMembers` (`checker.go:21335`), for each key of the modifiers type: creates the
key literal type (`getLiteralTypeFromProperty`, interned, so the *first* creation fixes its id),
instantiates the name type for an `as` clause, calls `getPropertyOfType(modifiersType, name)` (which may
resolve the modifiers type's members), unions name and key types for duplicate keys, and for
non-literal keys instantiates the template into an index info. It also sets an empty member table
first, so recursive references see an empty type. The PR's lazy table does none of this until a
lookup; tsrs then had to move template resolution to stop a recursion (joi's `SchemaLike`), which
shows the cycle behavior itself changed.

Consequences for Trig at one checker:

- **Union order by type id.** A literal `"y"` first created by a lazy lookup, where eager mode created
  `"z"` then `"y"`, gets a lower id than `"z"`, and any later union of the two prints `"y" | "z"`
  instead of `"z" | "y"`. tsrs saw no drift in the conformance suite, but its default mode compared
  against itself and the PR's tsgo; Trig's oracle is the pin.
- **History-dependent cut-offs** at fewer instantiations (TS2589, TS5115) and the joi cycle.
- **The "no signatures" early return** and **`somePropertyReducesToNever`'s skipped constituent** skip
  resolutions that create types.

**Exact variant (#64526-exact):** at the point eager resolution would run, the lazy mapped table
performs every type-creating step of `resolveMappedTypeMembers` in order (key literal types, name-type
instantiations, the `getPropertyOfType(modifiersType, ...)` calls, duplicate-key unions, index infos),
including the empty-members-first step, and defers only the member *symbols* and their two links
(`valueSymbolLinks`, `mappedSymbolLinks`), keeping per key a compact record (key type, name type,
optional/readonly/strip flags, modifiers prop). The early return and the skipped constituent then
must create the table rather than skip it. This keeps (I1) and (I2), saves the 9.2% of symbols that
tsrs attributes to `newMappedTypeMember`, and makes tsrs's cycle fix unnecessary (the template is
resolved where eager resolves it). Whether it still pays is a measurement (§3).

### 1.4 Several checkers (the coordinator's question)

**Why output can differ at C > 1 when C = 1 matches.** Each checker sees a partition of the files, in
its own order, so it reaches a given type with a different cache behind it. The history-dependent
diagnostics (CHECKERS point 2) read that cache: the instantiation depth limit, the base-constraint
cut-off, which declaration a cycle is reported at. A change that creates fewer types or caches less
moves those cut-offs on some partitions and not others. Then a diagnostic raised while checking a file
owned by another checker is dropped (point 3), the error type stays in the cached result, and a
`@ts-expect-error` goes unused: tsrs's dify case, where tsgo prints no TS2578 at 1, 2, 3, 5, 7, 8 and
12 checkers and tsrs in Go mode with lazy members on printed `(93,9)` at 5, 7, 8 and 12. With
`TSRS_LAZY_MEMBERS=0` tsrs matched tsgo at every count. A single history (C = 1) is one sample of
that space; each C adds others, so C = 1 passing is weak evidence for C > 1.

What tsrs's default included when dify moved: #64475, #64526 and the follow-ups L1, L5, L6, L10, L11.
#64526 alone already changes the created types; the follow-ups change caching. Which one moved dify
is not recorded; Trig should find out by running dify with #64475 alone.

**What the checkers job must compare** (tests/suites/checkers.rip, G1, extended once Trig checks in
tasks):

1. For each project and each C in {1, 2, 4, 8} plus dify's counts {3, 5, 6, 7, 12, 16}: trig with the
   switch on = trig with it off = tsc at C (stdout, exit status, emitted files), at several task
   counts per C.
2. Per checker, the type trace's hash, the type count, the signature count and the instantiation count:
   on = off. This is stronger than output equality: a trace difference is a latent divergence even
   when no diagnostic moved yet.
3. The invariant counters (`lazy_types_created`, `lazy_instantiations`, `lazy_reinstantiated`) = 0 on
   every checker.
4. Add **dify** (`packages/contracts/tsconfig.json` at `7b69dea2c802`, 752 files) to misc/projects for
   the checkers job: it is the known case that separates the modes. Its tsc output varies with C, so it
   is compared per C, not against C = 1 (list it in `tests/checkers/known.txt` for the C = 1
   comparison).

**Can single-checker go first? Yes.** Trig checks single-threaded today (`CHECKER_ARGS` is
`--singleThreaded`; G2, a Program lent to tasks, is next). So:

- Phase A (now): the switch works at C = 1. Gates: §2 and §4 at C = 1, trace equality, invariant
  counters at 0.
- Phase B (when the pool lands): the switch is forced off at C > 1 until the checkers job above passes
  with it on at every C Trig claims, dify included. Because (I1) and (I2) are local, #64475 should pass
  by construction; the job confirms it. #64526-exact is held to the same rule.
- The plain #64526 as posted stays out: it cannot pass point 2 of the job.

---

## 2. The switch

### 2.1 Where it lives

- AGENTS rule 4: the core never reads the environment. So the checker gets a `lazy_members: Bool`
  (and later `lazy_mapped: Bool`) from its creator, stored on the `Checker` once, as tsrs reads its
  flag once in `new_checker`.
- `tools/trig/main.rig` (which already reads the environment through `os.env`) reads
  **`TRIG_LAZY_MEMBERS=0|1`** and **`TRIG_LAZY_MAPPED=0|1`**; the latter has effect only with the
  former on, so `TRIG_LAZY_MEMBERS=0` is reference mode whatever else is set (tsrs's rule for its
  candidates). The checker test pack and the declarations/js packs read the same variables.
- No command-line flag: `trig` must print what `tsc` prints, and tsc answers `--noLazyMembers` with
  TS5023 (unknown option). An environment variable keeps the command line tsc's.
- Default: **off** (Trig's position) until the gates pass; then on, with `TRIG_LAZY_MEMBERS=0` kept
  for good as the reference mode for triage, as tsrs keeps it.
- Read the flag only where a table would be created and at the sites that skip work without a table
  (tsrs: `get_ready_lazy_member_table`, `get_lazy_mapped_table`, the mapped early return,
  `somePropertyReducesToNever`). Keep the table's index on the type's side object, not in a checker
  map: tsrs found its 1M-entry map probe at about 1% of check samples (`cpu-checker.md`).

### 2.2 The rule: off is reference-identical

Stronger than tsrs: tsrs runs the PR's refactors in both modes and argues they are neutral; Trig's off
path **runs the pin's code**, with the refactors only on the on path (or proven to create the same
types, by trace). Verification, with the switch off, against main at the merge base:

1. Every suite, byte for byte: `.types`/`.symbols`/`.errors.txt` 12,884, declarations 1,780, js emit
   11,819, testcase 12,892, cli 30 runs (stdout, exit status, 210 emitted files), checkers job;
   `tools/pup checker` with no failure outside `tests/checker/known.txt`, and the known list
   unchanged.
2. Counters equal main exactly: type count, symbol count, signature count, instantiation count per
   cli project (tsrs's gate 2), and the type trace equal to main's.
3. Speed: the off arm within 2% of main on every bench project and no more than 0.5% more
   instructions (the cost of reading a Bool where a table would be made).

**Job cache caution:** TESTS.md says a job that passed is not queued again while its key (pack, inputs,
tsc's output) is unchanged; a runtime `TRIG_` variable is not in that key. Either add the two variables
to the job key in `tests/lib.rip` (preferred, one line) or run each mode with `fresh` and its own queue
(`-t lazy-on`, `-t lazy-off`). Without this an "on" run silently reuses "off" passes.

---

## 3. Counters and measurement

### 3.1 Counters (Trig's `LazyMemberStats`)

Printed to **stderr** at exit when `TRIG_LAZY_STATS=1` (stdout is what the cli suite compares; Trig has
no `--extendedDiagnostics`). Incremented only when the switch is on; compiled in always, read off
the hot path.

From tsrs (the rows that apply):

| Counter | Shows |
|---|---|
| member tables created / resolved in full | how many references stayed lazy (tsrs: 14% resolved in full) |
| declared members in tables / instantiated | how many members were never made (tsrs: 17% made) |
| member lookups, signature, index-info and every-property queries answered | that the lazy paths are used |
| mapped tables created / resolved in full; mapped members created; mapped lookups; mapped index-info computations | #64526-exact |
| mapped "no signatures" early returns; `somePropertyReducesToNever` skipped constituents | #64526 sites |

Trig's additions, which are the exactness invariants:

| Counter | Must be |
|---|---|
| `lazy_types_created`: types created while inside a lazy operation (a depth counter around `get_lazy_declared_member`, `resolve_lazy_members`, every-property queries; the type constructor checks it) | 0 |
| `lazy_instantiations`: `instantiation_count` increments inside a lazy operation | 0 |
| `lazy_reinstantiated`: a member instantiated twice for one table | 0 |
| `lazy_sym_tiebreaks`: `compare_symbols` fallbacks with a lazily made symbol | 0 |
| totals: types, signatures, instantiations, symbols | first three equal to off; symbols lower |

In debug packs the first three are assertions (`go_panic` with the table and member), so any corpus
test that breaks them fails by itself.

### 3.2 The type trace

`TRIG_TYPE_TRACE=PATH` writes one line per type at creation (`id flags objectFlags kind symbolName`)
and per signature, per checker. Off vs on must be byte-identical for every checker test and every cli
project; its hash goes into the checkers job (§1.4). This is the check for R1 and for #64526-exact;
it is also the fastest way to find the first divergent type when something does differ.

### 3.3 Measurement protocol

Arms, all built from the same Rig (pup's `/zfs/trig-pup/rig/bin/rig`) and the same Trig commit except
the change: **main**, **branch off** (`TRIG_LAZY_MEMBERS=0`), **branch on** (`=1`), and later
**on + mapped**. One binary covers off and on.

- **Time, x86:** pup, load under about 4, `PIN1="taskset -c 3"` with core 4 idle, release builds on
  the other slots, `tools/cli/bench -n 10` over mitt, tiny-invariant, neverthrow, superstruct, zod3,
  ts-pattern, arms interleaved per round, **fastest of 10**. Also `perf stat -e
  cpu_core/instructions/u,cpu_core/cycles/u` on the P-core. Plain build is the decision; report the
  BOLT `trigb` column too, but BOLT layouts trained on one arm confound a small change.
- **Time, arm64:** the Mac when `vm.loadavg` is under about 12, `/usr/bin/time -l` instructions and
  cycles, as confirmation.
- **Peak RSS:** max resident from `/usr/bin/time` (`-v` on pup, `-l` on the Mac), minimum and median
  of the 10 runs per arm.
- **Heap profile:** `RIG_HEAP_PROFILE=1 rig build --release` (rig#529) for main and the branch, one
  run each of ts-pattern and zod3 per mode: peak live heap and live bytes by type at peak. Expect the
  symbol store, `symbol_data`, symbol tables (`Tab`) and value-symbol links to drop, and a new row for
  the lazy tables. Watch for tables that stay live after full resolution: Trig frees nothing, so a
  table resolved in full (tsrs: 14% of member tables, 53% of mapped tables) must hand its arrays to
  the resolved members, not duplicate them.
- **Counters** from a separate, untimed run per project.
- Record everything in docs/RESULTS.md with the commands, as its sections do.

### 3.4 What clears the bar

- **Exactness first, no exceptions:** §2.2 and §4 green, invariant counters 0, trace equal.
- **Speed (AGENTS rule 9):** on vs off more than 2% faster, or at least 1% fewer instructions with time
  no worse, on ts-pattern and zod3 (the projects with generic interfaces and mapped types); no
  project more than 2% slower (noise); off within 2% of main.
- **Memory:** rule 9 does not speak to memory, and memory is where tsrs leads most (399 against
  215 MB on ts-pattern). Proposed: a peak RSS at least 5% lower on ts-pattern and zod3 with time no
  worse also clears it. This needs the owner's word (decision 3 below).
- Expectation from tsrs (monorepo, single-threaded): #64475 alone 17% lower peak, 5% less check time;
  with #64526, 23% and 13%. Trig's small projects spend much of their time in lib files (Array,
  Promise, Map references), where #64475 applies; tuples (tsrs's L1, 13% fewer symbols) are a later,
  separate switch.

---

## 4. Regression tests to add first (before any lazy code)

Each gets its expected output from tsc at the pin (the oracle), runs in both modes, and must pass
off on main before the branch starts.

1. **The PRs' own tests:** `instantiatedReferenceLazyMembers.ts` (#64475) and `mappedTypeLazyMembers.ts`
   (#64526). They are not at the pin; fetch them from the PR branches in microsoft/typescript-go, add
   them as checker cases with `.types`/`.symbols`/`.errors.txt` from the pin's tsc (and check they
   equal the PRs' own baselines; tsrs found they pass upstream baselines in both modes; tsc counts
   59,323 / 59,088 symbols with the PRs).
2. **tsrs `lazy-mapped-template-cycle`** (`a.ts`: joi's `SchemaLike`/`SchemaMap`/`Schema`; `b.ts`: the same
   cycle over an object type; strict, `lib: es2022`): expected output is empty at the pin. Add as a
   cli project and as a checker case.
3. **Member order** (`lazyMemberOrder`): `interface B<T> { a: T; b: T; c: T }`, look up `x.c` on a
   `B<number>` first, then `const y: B<number> = {}`; tsc lists `a, b, c` (TS2739). Variants: inherited
   members (`interface D<T> extends B<T> { d: T }`), merged interface declarations (from tsrs's
   `lazy-dts-members`, which tests another feature but has the right shapes: `Merged<T>` listing
   `a, a2, b, b2`), and `.types` printing an instantiated type after an out-of-order lookup.
4. **Union order by type id** (`lazyMappedLiteralOrder`, for #64526): a mapped type
   `{ [K in keyof T]: ... }` over `{ z: 1; y: 2 }` whose member `y` is looked up before anything
   makes `"z"`, then a printed `keyof` or union of the two literals in `.types` and in an error. Under
   eager resolution `"z"` is created first; a lazy table creating only `"y"` flips the printed order.
   Also an `as` clause (`[K in keyof T as `get${K}`]`) for name-type instantiation order.
5. **The refactored predicates** in both modes: `isWeakType` (TS2559 on an all-optional generic
   interface instance), `getSingleSignature` (contextual typing through a generic interface with one
   call signature), `isFunctionObjectType`, `isStringIndexSignatureOnlyType` with a non-generic mapped
   type (`stringIndexOnlyNonGenericMapped`, risk R3), `somePropertyReducesToNever` (an intersection of
   two instances of a generic interface with conflicting discriminants reduced to `never`).
6. **Recursion and cut-offs:** a circular base through an instantiated reference
   (`interface A<T> extends B<A<T>>`), a `this`-typed fluent interface instance, TS2456 through a mapped
   template, and a TS2589 case whose instantiation chain passes through instantiated members and a
   keyof mapped type.
7. **dify** as a cli and checkers project (§1.4), the one known case that separates the modes.
8. Then the whole corpus in both modes (§2.2 list), and the trace comparison.

---

## 5. Draft DIVERGENCE row (for #64475; #64526-exact gets its own)

| Go function | Trig change | Reason |
|---|---|---|
| `resolveTypeReferenceMembers` / `resolveObjectTypeMembers` (checker.go:19534, 19545), with `getPropertyOfTypeEx` (19335), `getSignaturesOfStructuredType` (19399), `getSingleSignature` (19789), `isWeakType` (relater.go:679), `isFunctionObjectType` (31784) | With `TRIG_LAZY_MEMBERS=1`, an instantiated class or interface reference gets a lazy member table (microsoft/TypeScript#64475): at the point Go resolves its members, Trig instantiates its signatures, index infos and base types as Go does, and instantiates each declared member symbol only when it is looked up, or all of them, in Go's order, when the reference is resolved in full. | Instantiating a symbol creates no type, no signature and no instantiation, so the types, their ids and their order, and every cache Go fills, are Go's at any checker count (the debug invariant counters and the type trace show it on the whole corpus). tsrs measured 34% fewer symbols and 17% lower peak memory on a 38k-file project with the same output; `TRIG_LAZY_MEMBERS=0` runs the pin's code. |

---

## 6. Decisions for the owner (defaults in brackets)

1. Port #64475 alone first, off by default, single-checker, behind `TRIG_LAZY_MEMBERS` [yes].
2. #64526 only as the exact variant (all eager type work kept, symbols deferred), its own switch and
   PR, after #64475 lands [yes]; the PR as posted [no: it changes the created types, against CHECKERS
   point 7].
3. Let a peak RSS at least 5% lower, with time no worse, clear the bar for a memory change, alongside
   rule 9's speed bar [yes].
4. Turn the switch on by default once the corpus, the trace and the checkers job pass at every C Trig
   claims, keeping `TRIG_LAZY_MEMBERS=0` for good [yes].
5. Add dify (`packages/contracts`) to misc/projects for the checkers job [yes].
