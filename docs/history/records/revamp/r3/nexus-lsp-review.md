I recommend going ahead, with changes. Tier 1 needs hooks before `rig lsp` can move onto it, Rig should skip tier 2, and tier 3 needs work in Rig's compiler first.

**(a) Can Rig implement the eight functions?** Not yet. Partial types are possible with modest work.

- **Parse failure stops everything.** A parse failure sets `ir = .nil` and marks the module `failed`, so sema never runs (`src/modules.zig:644-652`). A module whose import failed is not checked either (`src/modules.zig:242-245`). So at `x.` there are no types at all today.
- **Typecheck already tolerates resolve errors.** `sema.check` runs every pass without stopping early (`src/sema.zig:3433-3450`), and the poison types `unknown`/`invalid` keep one mistake from cascading. Ownership is skipped when there are type errors (`src/modules.zig:716`).
- **What partial types would take:**
  1. Run the wrapper's rewrite and sema on the tolerant tree.
  2. Treat a zero-width hole leaf as a silent poison name.
  3. Make sure the recording code tolerates repaired list nodes, since `recordKey` panics on a node without an id (`src/sema.zig:838`).
  4. Keep that analysis away from emit.
  5. Keep the last good analysis of each imported module, so one broken import doesn't blank its importers.
  6. Cheap first win: spacing errors fail `parseProgram` (`src/rig.zig:1938-1950`) even though the tree is complete, so that tree can be handed to sema.
- **Symbol ids are not stable.** A `SymbolId` is an index into one module's `symbols` list, in walk order. A `ModuleId` is the load order, so it depends on which file is the root. Neither survives an edit. Use the declaring file plus `decl_pos`, mapped through `parts` for directory modules, and follow proxies (`proxyOrigin`, `src/sema.zig:4390`).
- **Facts the server would need are missing:**
  - `facts.names` (`src/sema.zig:877`) maps a position to a local symbol only. A qualified `mod.name` records nothing for `name` (`typecheck.zig:6647-6650`).
  - Nothing records which field or method `x.f` resolved to.
  - `from`/`keeps` names are matched to parameters by text (`src/resolve.zig:1490-1508`), not recorded as references.
  - Built-in members are scattered: `len` is hard-coded in typecheck (`typecheck.zig:6433`); String methods go through `stringCallOf` and element methods through `elemCallOf`, while `push` is registered (`src/resolve.zig:2986`). `members()` would have to re-derive them unless typecheck reads one shared table.
- **Pass byte offsets, not Nexus nodes.** Rig's facts are keyed by its own parse's node ids after rewrites, and `desugarIterLoops` changes the tree after the first check. A node from Nexus's tolerant parse won't key into them. Have `symbolAt`, `typeOf` and `signatures` take (file, offset).

**(b) Does `@lsp` cover Rig?** No. Rig should rely on tier 3 for names and not write a tier-2 section.

- Tier 2 reads the raw grammar tree (`src/editor.zig:74`), but Rig's meaning comes after the wrapper's rewrites. In the raw tree:
  - `captures` and `result_part` don't exist yet (they are `@wrapper` in `@schema`).
  - Module constants aren't marked `fixed` yet.
  - `fun Point.twice` isn't attached to `Point` yet (`attachMethods`).
- Forms that need a hook, not a declarative entry:
  - **Plain `x = …`** declares only if no assignable binding exists, otherwise it assigns (`src/resolve.zig:508-516`). `new` shadows, and `=!` declares a fixed binding. At module level, names are visible throughout; in a body, from the declaration on.
  - **Captures:** `|?x|` is a new symbol whose `origin` is the outer `x`, and a closure sees outer locals only through captures (`src/resolve.zig:320-337`). Renaming `x` must rename the capture too, so lexical scoping gives wrong answers.
  - **Context-typed `.variant`, `x.f`, and keyword arguments** (`call_slots` maps them to the callee's parameters or an object's fields) all need types.
  - **Labels** live in their own namespace (`jump_dests`).
  - **`use`** binds the alias or the path's last name, and in a directory module only in its own file (`file_uses`). The other files' top-level names are shared, which per-file scoping can't see.
  - **`":"`** is a field inside an object and a parameter elsewhere; `@lsp` has no parent context to tell them apart.
  - **Generic type parameters** are detached symbols (`src/resolve.zig:447-480`).
- These map fine: `raw` blocks, `extern zig`, `extern_fun`/`zig_const`.
- **Duplication:** yes. Declarative resolution would be a second classifier for what `resolve.zig` decides, which breaks "one classifier per fact". The design should let a language with `symbolAt` turn tier 2 off, and say that when `analyze` fails the server answers from the stale analysis, never from tier 2.

**(c) A file, or a program root plus open files?** A program root plus an overlay of open files.

- Every non-std `use` resolves from the root's directory (`src/modules.zig:282`). Checking a nested module file as its own root resolves its imports wrongly.
- A file inside a directory module, checked alone, loses its sibling files' names.
- `root_source` covers only a single-file root (`src/modules.zig:219`). `readDir` and imported modules read from disk, so unsaved edits there are ignored.
- **Recommendation:** replace `root_source` with a path→text overlay that `read` and `readDir` consult. The analysis then covers a whole program and returns diagnostics per file.
- The embedded std has no file to open, while `$RIG_STD` std files do.
- Finding the root needs a rule; Rig has no manifest. One option is a setting with the open file as the fallback. I'm unsure which is best.

**(d) What phase 1 would lose** if the generated server keeps only what the design specifies:

1. **Diagnostic equality.** The design publishes "`writeError`'s" first error plus the tolerant parse's repairs. Rig's parse errors come from its wrapper: the foreign-word hints, spacing errors, the extra errors after the first, and the unclosed-bracket note (`src/editor.zig:27-44`). Publishing repairs as diagnostics fails the as-typed check in `lsp_check.sh`. A `parseDiagnostics` hook is needed.
2. **When the full check runs.** Rig checks on open and save only (`src/lsp.zig:406-428`), runs `inlining.decide` (`src/lsp.zig:517`), and re-shows the last check while the text hashes the same (`src/lsp.zig:496`).
3. **Diagnostics in other files.** Rig publishes to imported files, tracks them, and clears them on close or recheck (`src/lsp.zig:566-597`, `src/lsp.zig:429-440`). Errors with no position go at 0:0 (`src/lsp.zig:530`). A diagnostic's span needs a file (`d.module`, `parts`).
4. **Notes.** Notes are linked both ways as related information, and a note in the built-in std is folded into its error with a `path:line:col:` prefix (`src/lsp.zig:768-785`). The design's severities have no "note".
5. **The 100-error cap**, which still counts errors in std modules no editor can open (`src/lsp.zig:532-541`).
6. **Semantic tokens.** Rig tells sigils from operators by the tree, using node start and end and the token category (`src/editor.zig:385-389`). It also marks:
   - the `!` of a fallible `sub` and contextual keywords;
   - keyword-argument names, builtins, labels and enum members;
   - method versus function and property versus method.

   `@highlight`'s sigil rules guess by spacing, and `lsp.sh` checks the tree-based result. A `tokens` hook is needed.
7. **Outline and folds.** The outline shows `Point.twice`, unquoted test names, module constants (`isModuleConst`), field types and `extern zig` children. Folds come from the indent and outdent layout tokens plus runs of comment lines.
8. **Process details.** UTF-16/UTF-8 negotiation, the byte order mark, lone `\r` line breaks and bad UTF-8 (`src/lsp.zig:100-202`). The leak-checked `SafeAllocator`, where a leak means exit 1 (`src/lsp.zig:262-284`). `$RIG_STD`, `untitled:` documents that get parse errors only, advertising exactly the capabilities that are built (`lsp.sh:119`), and the error codes. `@repair` itself is kept, since it's Nexus's own `parseTolerant`.

**Changes I'd recommend, most important first**

1. Phase 1 moves `rig lsp` only when the generated server calls lang-module hooks for parse diagnostics, check diagnostics (per file, with related notes and the cap), tokens, symbols and folds. Its gate is `lsp_check.sh` and `lsp.sh` unchanged.
2. The functions take (file, byte offset), not Nexus nodes.
3. `analyze` takes a program root plus an overlay.
4. A language can turn tier 2 off; for Rig the compiler's facts are the only source of names.
5. Rig adds the missing facts (member target, foreign reference, `from`/`keeps` names) in typecheck and one table of built-in members that typecheck itself reads, before tier 3.
6. Tolerant analysis is a contract written down in `docs/INTERNALS.md`: holes are poison, imports fall back to their last good analysis, and nothing tolerant reaches emit.
7. `describe` should be able to carry ownership facts for Rig's phase 2 hover. "Moved at" lives only in the ownership checker today and is skipped after a type error, so it needs a recorded fact. I'm unsure what that fact should look like.

Two things I didn't check: whether `expected(state)` lists the contextual keywords (`unique`, `from`, `static`, `keeps`), which lex as names; and whether repaired list nodes get ids.