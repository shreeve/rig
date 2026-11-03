# Binding files in parallel in Trig: design note (item 16, fix 3)

Rig - Merges, 2026-10-31, for Rig - Swiss before any code.

## Why

On zod3 at four checkers Trig binds on one thread for 12 ms (E-core) where tsrs shows none, part of the 25 ms gap ([startup-15-16.md](startup-15-16.md), "Item 16 settled"). On small projects binding is larger still: on mitt at one checker the binder is 21.6% of user cycles (parser and lexer 33.1%, checker 14.9%; 30 runs, E-core 18, perf). lib.dom.d.ts is about two thirds of the text, so a parallel bind is bounded by that one file: at most about 8 ms of zod3's 12 at four.

## What serializes it

- `new_program` (compiler/program.rig) binds each file as it is loaded: `binder.bind_source_file(!file, !names)`.
- `names` is one program-wide `ast.Names` (ast/names.rig): a `text.Interner` that numbers each name (atom) in the order binding first sees it, plus `class_ids`, a counter for private names (Go's `ast.GetSymbolId`). Every bind writes to it, so binds cannot overlap.
- Go and tsrs key symbol tables by string and bind files concurrently (Go's `bindSourceFiles` in a work group; tsrs per file). Atoms are Trig's own departure (docs/binder/DESIGN.md §3), and the only shared state.

## Output identity

Atoms reach the output only through their text, as far as this audit found: no `HashMap` or `HashSet` keyed by atom; ordered `Map` and `Set` iterate in insertion order, not by value; comparisons go through the text (`Checker.compare_atom_lists`). `class_ids` cannot reach tsc's output either, since Go numbers them from parallel binders. But "as far as found" is not proof, so the design keeps numbering exactly as today.

## Design: bind with local names, merge in file order

1. Bind each file in its own task, against a fresh local `Names` (local atoms, local class ids from 1). The predefined atoms (`ATOM_MISSING` to `ATOM_PROTOTYPE`) are the same in every `Names`, so the binder's constants hold.
2. Merge serially, in program order (the order binding runs today): for each file, intern its local names into the program's `Names` in local-atom order, which is first-seen order, so the program numbers every name as serial binding would; offset its class ids by the class ids so far. Then rewrite the file's `Binding`: each `SymbolRec`'s name atom, and each `SymbolTable` (`Map[Atom, SymbolId]`, rebuilt in the same insertion order with the mapped keys); any other atom field the audit finds (pattern ambient modules, diagnostics arguments).
3. Same atoms, same class ids, same tables in the same order: the program's state after the merge equals today's, by construction, whatever the output depends on.

Cost: the merge hashes each file's distinct names once more (lib.dom.d.ts: tens of thousands) and rewrites its symbols and table keys; the binding's AST walk, symbol creation and flow graph run in parallel. The reach is bind time minus the merge, bounded by lib.dom.d.ts.

## Alternatives not chosen

- Intern every identifier in one serial pass first, then bind in parallel against a read-only `Names`: simpler, but it numbers atoms differently (extra names interleaved), so identity rests on the audit alone.
- A shared concurrent interner: atom numbering would depend on timing, and safe Rig has no shared mutable map.
- Key tables by string, as Go does: undoes Trig's atoms and their speed in the checker.

## Measure first

1. The merge's cost against the bind's: a prototype of step 2 alone (bind serially into a local `Names`, then merge), timed against today on mitt, zod3 and ts-pattern at one checker. If merge plus local bind is over 1.5% slower at one checker, stop.
2. Then the parallel bind, stacked on lib-parse-ahead and the scheduler result, at four checkers.
3. Output: the six projects byte-identical at 1 and 4 checkers, and Trig's light gate.

Owner of the code: Trig (binder, compiler/program.rig). It touches neither the lexer nor the parser.

## Approved by Rig - Swiss (2026-10-31), with three changes

1. One checker keeps today's serial path, untouched: bind with local Names and merge only when binding runs on more than one task. The prototype is measured as the merge's cost against the parallel gain at four checkers.
2. Peak RSS: no higher on any project at one checker; at four, reported beside the time.
3. Binder diagnostics, and anything else the binder emits while it runs, come out in program order: the merge replays them in file order. Added to the audit list.
Order: after the sched-wake measurement; ends as a Trig PR for the owner.

## Lead from Rig - Rust (2026-11-01, trig#234's profile)

Interning is 14% of the binder's samples (empty project, one checker), and the symbol table then hashes the atom a second time. tsrs hashes a name's text once and keys its tables by that hash. Two options, both mine to decide since they touch SymbolTable's storage:
1. Carry the hash computed during interning into the symbol table.
2. Key the table by atom with a near-identity hash.
Option 2 leaves first-seen numbering alone, since atoms are already assigned, and the ordered Map keeps insertion order. So it fits the merge, which rebuilds tables with mapped keys either way. Rust measures a Mac ceiling for option 2 first.
Rust's Mac ceiling for option 2: every U32 key hashed by one multiply, an upper bound, trig#234 at one checker, 7 interleaved rounds. Empty: 0.14% fewer instructions, cycles level. zod3: 0.40% fewer instructions, 0.9% fewer cycles. That's under the bar, because Rig already hashes an int key in about one cycle, and option 1 removes no more than that. Both options dropped. The binder's 14% is interning itself, hashing and copying the text. Tables stay as they are.

## Base for the prototype (2026-11-01)

trig#234 (binder in tsrs's shape) merged as dd4334190; build parallel bind on it. bind is a missing-node test that calls bind_node; the children walk is generated (`Binder.bind_children_of`, src/binder/children_generated.rig, from tools/ast/gen.py); declaring arms and reports are `called`. bind_source_file's signature, Names, interning order and SymbolTable are unchanged. Rust is re-measuring the serial head by phase and checks with me before touching the loader, parse-ahead or the bind loop.

## Before the prototype: what the merge must rewrite (2026-11-01, on Trig fb60a18)

- **Where atoms live after binding:** each `SymbolRec.name` (ast/symbol.rig) and every `SymbolTable` key in `Binding.tables`. The binder interns at about 20 sites in binder.rig, all through `Names.intern` or `text_atom`. Nothing else in `Binding` holds an atom.
- **Class ids sit inside atom text.** A private name's symbol name is `INTERNAL_SYMBOL_NAME_PREFIX + "#" + class_id + "@" + description` (`get_symbol_name_for_private_identifier`). So with local class ids (from 1 per file), the merge can't just offset a counter. For each local atom in that form it rewrites the text with the global id (the local id plus the classes counted so far), then interns the rewritten text. The prefix (`\xFE#`, digits, `@`) can't occur in source text, so the form is unambiguous. lib files have no private names, so this costs nothing on the big files.
- **Text that reaches diagnostics while binding:** `get_display_name` prints a node's own name text when it has one (private identifiers do), and atom text otherwise (ambient module names, signed numeric names), none of which holds a class id. `Duplicate_identifier_0` at binder.rig:1127 prints the `prototype` symbol's name. So the binder's diagnostics don't depend on class ids, and are kept as each file made them. The merge still replays them in file order, per Swiss's third change.
- **Ambient pattern modules:** the "pattern@id" name uses the attribute node's lazy id, which is local to the file, so it's the same either way.
- **Serial head now** (Rust, pool-inline Rig): at four checkers, zod3 is 13.9 ms and ts-pattern 15.3 ms behind tsrs, and bind is 7.1 ms serial against tsrs's 0. That's the reach, less the merge's cost.

## Lazy .d.ts member binding (Rig - Rust, measurement only, 2026-11-01)

Agreed with Rust: if built, it takes option (a). The skipped member lists' names are interned during the first bind, so atom order and the merge's numbering stay exact, and only symbol and table creation is deferred. Option (b), names per checker, only after asking me. Rust measures a generous bound (skip interning too) and an arm that interns but skips the tables, at one and four checkers, and repeats the four-checker run on my parallel-bind prototype once it's timed.
