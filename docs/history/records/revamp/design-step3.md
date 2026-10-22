# Design: generics across modules (based on `ct-sizes`)

## Core idea: import foreign generic declarations as detached proxy symbols
Every module's `SemContext` is already kept alive in the shared `ModuleMap` (`src/modules.zig` `ModuleGraph.semas`), and each library is fully checked, ownership included, before its importers. So **the library's SemContext is the export**. There is no new file format.

When an importer first needs a foreign generic declaration, it copies what it needs from the declaring module's context into its own tables. It adds a local *proxy* symbol that is in no scope and records its origin. Proxies are created for:
- generic types, with their type parameters, and
- type and integer parameters of generic functions and methods.

After that, the existing machinery runs unchanged: `membersOf`, `substituteType`, inference (`bindArg`), `expandInstantiations`, `checkRequirements` and ownership's `checkInstantiations`. They all index `ctx.symbols.items[sym]`, and for a proxy that index is valid locally. I rejected extending `imported_nominal` with args. The importer's store must still be able to spell the foreign `T` for inference, so proxy type variables would be needed anyway. Proxying the generic type as well keeps all ~50 `symbols.items[pn.sym]` sites valid.

## 1. What an importer reads from the library
- **Signatures:** `Symbol.ty`, `FunctionType.ct_params`/`ct_syms`, `type_params`, `fields` (method signatures, payloads, `param_names`/`param_defaults`), and `contents` (glue, plain, cell, borrows, `held`).
- **Requirements with positions:** `generic_requirements` (`GenericRequirement{param, req, pos, op}`). This already includes `array_len`, `plain`, `fits` and the others. The position is relative to the library's source.
- **Generic calls and types the body uses:** `generic_fn_uses` and `generic_uses`. These chain instances onward.
- **Ownership summary (new):** ownership's `plain_reqs` (copies of `T`, and elements taken from a loop that does not consume its collection) currently die with the `ownership.Checker`. `modules.zig` `check()` will append `own.plain_reqs` into a new `SemContext.plain_reqs` field (`{param, pos, element, module_id}`) after `own.check`.

**Import unit is one parameter.** `sema.importParam(ctx, ref)` makes the proxy for `ref = {module, sym}`, then copies from the origin:
- the requirements whose `param == sym`, retargeted to the proxy, with `module_id = origin`;
- the origin's `plain_reqs` for `sym`;
- every origin use whose args mention `sym`, translated by `importType`. A set `imported_uses{module, list, index}` stops duplicates.

`importGenericType` builds a proxy `generic_type`:
- It is inserted in the memo *before* its fields are imported, so recursive types terminate.
- It keeps the same `kind` for value parameters (`.param`), because `typeInstance`/`ctIntArg` test for it.
- It copies `contents` and preset `state = .done`.

## 2. Type identity
- `Symbol` gets `from: ForeignRef = .{}` (`{module_id, sym}`; module 0 means declared here).
- `SemContext` gets `imported: AutoHashMap(ForeignRef, SymbolId)`.
- A proxy always records the **ultimate** origin. When the foreign symbol is itself a proxy, its `from` is followed.
- `sema.importType` (sema.zig ~2129) changes:
  - `.type_var`/`.ct_param` map to the proxy's var instead of `invalid`;
  - a non-builtin `.parameterized_nominal` becomes `parameterized_nominal{sym = proxy(origin), args = imported}`;
  - function `ct_syms` map to proxies for type and `Int` slots instead of `symbol_invalid`, so `intSlot` works for `lib.zeros[3]()`.
- Builtins keep their ids, because they are registered first in every module. For the same reason, `pn.sym == ctx.vec_sym_id` checks can never match a proxy.
- **Result:** in module A, `lib.Box[Int]` is always `pn{proxy_A(lib, Box), [Int]}`, whether it was spelled in A, imported from lib, or reached through B or C. Interning makes them one `TypeId`. In lib itself it is the real symbol. In Zig it is `lib.Box(i64)` or `@import("lib.zig").Box(i64)`, and Zig memoizes both to one type.
- Proxies use `decl_pos = imported_decl_pos` (`maxInt(u32) - 1`), which never collides with a source position (emit.zig:1011 and ownership `symbolAt` compare positions). `builtin_decl_pos` is not reusable: it would skip expansion (sema.zig:1256) and ownership checks (ownership.zig:465).

## 3. Where a foreign instance is checked
In the importer, exactly as for a local instance:
- `crossModuleCall` → `instantiateCall` records `FnInstance{params = proxies}`; a proxy type goes into `instantiation_sites`.
- Step 7, `expandInstantiations`, works over the local plus imported uses.
- `checkRequirements` sees the imported requirements.
- Ownership `checkInstantiations` covers borrow arguments, `has_methods` (proxies have fields) and `checkCopies` (plain reqs seeded from `ctx.plain_reqs` entries with `module_id != 0`).

The error is at the importer's call. The note goes to `req.pos` in `req.module_id`. Polymorphic recursion is caught by the importer's depth limit (`max_instance_depth` 24, `typeInfo.depth`) and reported at the importer's site, naming its root (`lib.nest[Int]`).

## 4. Chains and cycles
- `lib.f[T]` calling `util.g[T]`: lib's own `generic_fn_uses` holds `g[·]` over lib's proxies of `util.g.T`. When main imports `f.T` from lib and translates that use, the proxy resolves to its ultimate origin, `(util, g.T)`. That imports `g`'s requirements and uses from util's context, which is in `ModuleMap` even when main does not `use util`.
- Cycles cannot happen: `ModuleGraph.resolveUse` rejects a cyclic import. So generic recursion that goes back and forth between two modules is impossible, and recursion inside one module is caught by the depth limit.

## 5. Visibility
Private helpers already work. emit.zig writes every declaration as `pub` in Zig (lines 377, 459, 587). lib's body calls its helpers inside `lib.zig`. The importer never re-checks the body, and the helpers' instances are checked through the imported uses. `test/behavior/modules/generic_fn_in_module` already shows a private generic serving public functions.

A private generic type can be held through a `pub` function's result but not named: `lib.Hidden[Int]` fails the existing "not public" check.

## 6. Emit (emit.zig, about 30 LOC)
- `writeNominalName`: for a proxy, write the module prefix. Factor the prefix out of the `.imported_nominal` branch (~3474) into `writeModuleRef(module_id)`, which uses the local alias or `@import`.
- `emitCallDirect` member-callee path (~2694): for `lib.Box[Int](..)` and `lib.Box(..)`, add a `.parameterized_nominal` case: `emitTypeTy(t)` then `emitFieldInit`.
- `emitMemberBase` (~2545): `lib.Box.make(1)`, where the object is a member naming a proxy `generic_type`, emits `obj_ty`. Typecheck must record that type on the member node.
- Calls already emit `lib.max(i64, 3, 7)` through `genericCallOf`.

## 7. Deletions
- resolve.zig: `checkPublicSurface`, `exposedInMember`, `reportGenericFn`, `reportExposed`, `exposedInstance` (~1718–1800, −85).
- typecheck.zig: `checkPublicArrayLengths`, `ctParamSym`, `reportSizedPublic` (~5833–5885, −55).
- typecheck.zig: `InstTarget.foreign_generic` and its message (−10).

## 8. Changes by file (LOC estimates)
- **diag.zig (+25):**
  - Add `Diagnostic.module: u32 = 0`.
  - `writeSome` takes a lookup from module to `{source, path}`, and resets `Lines` when the file changes. It is used by `ModuleGraph.writeAllDiagnostics`.
  - Unit test for a note in another file.
  - **Notes in another file are not supported today:** each module's list prints against its own source (modules.zig `writeAllDiagnostics`).
- **modules.zig (+20):** persist `plain_reqs` after ownership in `check()`; the file lookup for the writer; `addDiagnostic` copies `module`.
- **sema.zig (+170/−10):**
  - `Symbol.from`, `imported_decl_pos`, and the maps `imported`, `imported_uses`, `plain_reqs`; `GenericRequirement.module_id`.
  - New `importParam`, `importGenericType`, `proxyOf`.
  - `importType` changes as above.
  - `formatTypeIn` prints a proxy as `lib.Box[...]`.
  - `computeCells`/`computeBorrows`/`checkInfiniteTypes`/`computeContents` skip proxies.
  - `report` records the module and deduplicates with it; new `noteIn(module, pos, …)`.
- **resolve.zig (−85/+30):**
  - Qualified generic instances in types: `resolveGenericInst` accepts a member name, runs `resolveQualified`'s module and `pub` checks, then the argument loop over the proxy's `type_params`.
  - `resolveQualified` keeps its "needs type arguments" error for a bare `lib.Box`.
- **rig.grammar (+3, then `zig build parser`):** `tatom` today only has `name LBRACKET_INDEX …`, so a type written `x: lib.Box[Int]` does not parse. (Expression forms such as `lib.Box[Int](..)` and `Vec[lib.Box[Int]]()` already parse as `index`/`inst` over a `member`.) Add `object "." name LBRACKET_INDEX types "]"`: either factor a `tname` so `generic_inst`'s name is a leaf or a `(member)`, or add a node `qualified_inst module:leaf name:leaf ...args`. Record any conflict in INTERNALS.
- **typecheck.zig (−65/+45):**
  - `instTarget` (~2599) and `namedType` (~2486) return a proxy `NamedType` for a foreign `generic_type`.
  - `crossModuleCall` (~4531): for a `.generic_type`, share the local generic-constructor branch from `synthCallInner` (extract `constructGeneric`). Record the *instance* signature on the callee (move `noteCallee` after `instantiateCall`, as `functionCall` does), because emit's `callParams` reads it.
  - `findMethod`: `Method.source` is the origin's source for a proxy, so method defaults stay right.
  - Guard the "declared here" notes (1434, 3058, 4174, 4183) with `decl_pos < imported_decl_pos`.
  - `checkRequirements` notes with `noteIn(req.module_id, …)`.
- **ownership.zig (+20):** `PlainRequirement.module_id`; seed imported entries at `initWithSema`; `checkCopies` notes in that module; its diagnostics carry the module.
- **Net:** about +340 / −230.

## 9. Tests
**Behavior** (`test/behavior/modules/<name>/main.rig` + lib files):
- **`generic_fn_across_modules`**
  - `lib.max(3, 7)` and `lib.max[Float](1, 2)`;
  - `z: U8 = lib.max(1, 2)` and `lib.max(lib.max(1, 2), small)`;
  - a public generic calling a private generic;
  - a resource argument, moved and dropped leak-free.
- **`generic_type_across_modules`**
  - `lib.Box[Int](v: 3)` and `lib.Box(v: "s")`;
  - `b: lib.Box[Int]` and `lib.Box[Int].make(1)`;
  - a generic method `b.with[Bool](true)`;
  - `lib.Opt[Int].some(value: 7)` plus a `match`;
  - `Vec[lib.Box[Int]]()`.
- **`generic_instance_identity`:** a diamond. `a.make() -> lib.Box[Int]` is passed to `b.take(x: lib.Box[Int])` and to `lib.unbox`. Also a type reached only transitively, which emits `@import`.
- **`const_generics_across_modules`:** `lib.Ring[Int, 4]`, `lib.zeros[3]()`, `a: [3]Int = lib.zeros()`, `lib.sum([1, 2, 3])`, and `pub sub show[k: Int]` calling a private `helper[k]()`. This converts `pub_ct_array_len`.
- **`generic_chain_three_modules`:** main → `lib.f[T]` → `util.g[T]`, where main does not `use util`.
- **`public_surface_generic_instances`:** converts `pub_generic_instance_return`, `pub_generic_instance_field`, `pub_private_holds_generic_instance`, `pub_leaks_private_type_signatures` and `cross_generic_type` into passing programs.

**Reject** (`test/reject/modules/<name>/`):
- `foreign_instance_requirement`: `lib.max("a", "b")`, with a `# error: L:C:` pin on the note line.
- `foreign_instance_ownership`:
  - `lib.twice(Res(..))`, whose body copies `T`, with the note in lib;
  - `lib.same(?r)`, a borrow argument;
  - `lib.Box[?Res]` on a type with methods.
- `foreign_polymorphic_recursion`: `lib.nest(1)`, where `nest[T]` calls `nest[Wrap[T]]`.
- `foreign_chain_requirement`: the note lands in `util.rig`.
- `foreign_array_len`: an out-of-range `lib.zeros[…]`.
- `foreign_builtin_element`: `lib.keep(Res(..))` instantiates `Vec[Res]`.
- `foreign_private_generic`: `lib.Hidden[Int]` is not public; a bare `lib.Box` in a type needs arguments.

The runner strips paths, so add a case to `test/cli/diagnostics.sh` asserting the note prints as `lib.rig:L:C:   note:`.

Delete `test/reject/modules/pub_generic_function`, or keep its `uses_local` part as a behavior test.

## 10. Docs, risks and open questions
**Docs:**
- **SPEC §4 Generic functions:** drop the "cannot cross module boundaries yet" sentence.
- **SPEC §4 Generic bodies:** the note is "in the module that declares the body".
- **SPEC §15:** replace the "Generics cannot cross…" paragraph and its reject example with an accepted `boxes.rig` example, plus a reject example whose error block includes the lib-side note.
- **SPEC §17:** add `lib.zeros[3]()`.
- **SPEC §19:** remove three rows.
- **SYNTAX §14 Limits:** remove bullets 2 and 4. §23 gets a generic example.
- **DESIGN "Per-instance checking":** rewrite the final paragraph. The requirement record is read from the defining module, and it remains an unwritten contract. Traits stay on the roadmap.
- **INTERNALS:**
  - Modules: proxies, ultimate origin, `plain_reqs` export.
  - Generics: remove the `checkPublicArrayLengths` text.
  - Diagnostics: `Diagnostic.module`.
  - Ownership: persisted `plain_reqs`.
- **ROADMAP:** remove the "Generics across modules" bullet.

**Risks and open questions:**
1. A library edit that adds an operation on `T` breaks importers, which then see a note in the library. This is the known cost the DESIGN section names; the user should confirm they accept it.
2. The library author sees nothing until someone instantiates. This applies to requirements no type can meet and to polymorphic recursion. Should `pub` generics be checked for self-nesting at declaration?
3. Every `symbols.items` loop and every `decl_pos` use must tolerate proxies. Audit list: sema contents passes, `checkUnreadLocals` (`.local` only), emit 1011/3779, ownership 983/1368/3080.
4. Instances reached through a chain are named by the library's spelling (`g[...]`). Should imported use names be qualified as `util.g`?
5. Grammar: Nexus conflicts for the qualified generic instance in types; choose between the `tname` factoring and a new `qualified_inst` node.
6. The same failing foreign instance is reported once per importing module, each at its own call site. I believe this is fine.

### Critical Files for Implementation
- /Users/shreeve/Data/Code/rig/src/sema.zig
- /Users/shreeve/Data/Code/rig/src/typecheck.zig
- /Users/shreeve/Data/Code/rig/src/resolve.zig
- /Users/shreeve/Data/Code/rig/src/modules.zig
- /Users/shreeve/Data/Code/rig/src/diag.zig
- /Users/shreeve/Data/Code/rig/src/ownership.zig
- /Users/shreeve/Data/Code/rig/src/emit.zig
- /Users/shreeve/Data/Code/rig/rig.grammar

## Decisions (lead, 2026-09-26; user agreed to the plan)
1. Accept the "unwritten contract": a library edit may break importers, with the note in the library file. Traits stay deferred.
2. Check `pub` generics for self-nesting (polymorphic recursion) at DECLARATION when it can be done by reusing the existing depth-limited expansion with the generic's own type parameters as arguments. If that turns out complex, defer it and say so; importers still catch it at their call.
4. Qualify names of instances reached through a chain with their module (`util.g[Int]`).
5. Grammar: prefer the `tname` factoring (so `generic_inst`'s name is a leaf or a `(member)`) if it is conflict-free; otherwise add `qualified_inst`. Record whichever is chosen in INTERNALS.
6. One report per importing module is fine.
