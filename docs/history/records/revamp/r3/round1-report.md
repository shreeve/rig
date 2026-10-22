# Round 1 — R + F + 0: rendering, flushing, `warn` and `panic`

- Branch: `r1-render-flush-panic`
- PR: https://github.com/shreeve/rig/pull/292 (not merged)
- Head: 914739be8, which includes origin/main at 2d67bc1ce
- Designs: r3/templates-design.md and r3/proposal-panic-print.md, built as written.

## What was built

### R: value rendering

- **Escaping.** Text nested in another value (an element, field, payload or optional) prints as a Rig string literal:
  - `"` and `\` take a backslash.
  - Newline, tab and CR print as `\n`, `\t` and `\r`.
  - Other control bytes, DEL and invalid UTF-8 bytes print as `\xHH`.
  - C1 controls and bidi controls print as `\u{h}`.
  - Top-level text is written as it is.
- **Floats.** A float prints the shortest digits that read back as the same value (`std.fmt.float.binaryToDecimal`).
  - From 1e21 up, and below 1e-6, it prints with an exponent, as JS does: `1e21`, `2.5e-7`.
  - A whole number keeps its point: `1.0`.
  - The special values are `inf`, `-inf` and `nan`.
- **Objects.** An object prints every field, in order.
- **Printability.** Whether a type can be printed is one per-type fact, `sema.printable`, memoized in TypeMemo.
  - Generic bodies get `Requirement.printable`, checked per instance.
  - `print`, `warn` and `panic` all reject a value that holds a `[]U8`, including a generic `show[[]U8]`.

### F: flushing

- **When stdout is flushed:**
  - before every stderr write (`warn`, `panic`, a runtime panic, an error leaving `main`);
  - on every exit, panics included.
- **The stdin and spawn hook.** `rig.flushOutput()` (runtime.zig) is the hook for stdin reads and process spawns. std has no stdin-read or spawn API yet, so nothing calls it. The first such API must call it.
- **`warn`** formats into a 4 KiB stack buffer and makes one `write` per line of up to 4 KiB.
- **EPIPE** ends the program with exit 0 and nothing printed (no drop, `defer` or leak check), in every build mode.
- **Any other stdout write error** prints `error: stdout: <reason>` and exits 1.

### 0: `warn(...)` and `panic(...)`

- **`warn`** is a built-in that a declaration can hide, like `print`.
- **`panic` is a keyword.**
  - It has type noreturn and is a `.jump` in Hands, so the proofs and unreachable-code checks see it.
  - It lowers to `rig.fail(.{ "path:L:C: panic: ", args..., "\n" })`.
  - The path is relative to the package root, the column counts runes, and only the first line carries the prefix.
- **Exit status.** Every panic exits 134 (`std.process.abort`) in every mode.
  - A runtime panic prints `panic: msg` with no location and no `thread N` prefix.
  - Following the design, the Zig trace is printed in debug builds only, using the safe unwinder. Release builds print the message alone.
- **Placement** is a positive list (`placePanics` → `panic_places`). A panic may stand:
  - as a statement;
  - as a branch of `if` or a ternary;
  - as a `match` arm;
  - on the right of `??`;
  - as a `catch` handler.
- **What is rejected:**
  - a panic in any other place, which is poison so nothing cascades from it;
  - a panic inside `defer` or `errdefer`;
  - a panic with no message;
  - a statement after a panic, as unreachable;
  - a keyword argument to `print`, `warn` or `panic`.
- **Under `rig test`,** a panic reports `FAIL  name: panicked`, then the count so far, then exits 134.

## Output changes (every one)

1. **Floats outside [1e-6, 1e21) print with an exponent.**
   - `Float(U128(1) << 100)` was `1267650600228229400000000000000.0` and is now `1.2676506002282294e30` (test/behavior/types/int128.rig).
   - `1e38` was 39 digits and is now `1e38` (float_literal_arithmetic.rig).
2. **Floats print the shortest round-trip digits**, for example `0.30000000000000004`. Values that already printed that way are unchanged.
3. **Nested text is escaped.** For example, `["a\tb"]` used to print a raw tab.
4. **Panics under `rig test`.** The report now ends with `N passed, M failed` (test/cli/test_blocks.sh). A run in which a test panicked exits 134.
5. **Release-mode runtime panics** no longer print Zig's stack trace, as the design requires. Debug builds keep it. test/cli/panic_status.sh now asserts the message alone in release.
6. **`panic` is reserved.**
   - Programs naming a local, type, function, module, variant or error `panic` are rejected.
   - A field, method or static named `panic` still works.
   - Renames:
     - the corpus probes audit-frontend-mods{,-Main2}: module `panic` → `os`;
     - emitter_reserved_names and print_renamed_names: `panic` → `os`;
     - SPEC's extern example: `panic` → `rig`;
     - the name grid now treats `panic` like `type` and `drop`.
7. **The harness.** `# expect-panic` now requires exit 134. main_fails_with_error, which exits 1 with an error, now uses `# expect-exit: 1` and `# expect-stderr:`.

## Tests

- **New behavior tests:**
  - panic_statement
  - panic_branch_values
  - print_floats_shortest
  - print_nested_text_quoted
  - warn_to_stderr
- **New CLI test:** cli/print_flush.sh. It runs built programs through `quiet` (main's crash-report change) and checks:
  - stdout/stderr order in debug and release;
  - a runtime panic;
  - EPIPE via `| head -1` in all three modes;
  - a closed stdout;
  - a panic in a test;
  - the package-root path from a directory module.
- **New reject tests:**
  - panic_as_value (5 sites)
  - panic_in_defer
  - panic_needs_message
  - panic_unreachable_after
  - print_keyword_arguments
  - panic_reserved
  - print_byte_slice_generic
- **Harness additions:** `# expect-exit:`, the `# expect-stderr:` block, and the doc fences ```` ```stderr ```` and ```` ```stderr exit=N ````.
- **Docs:**
  - SPEC §17 is now "Printing and stopping", with Output and panic subsections.
  - §1 and §13 were updated.
  - SYNTAX.md (keywords, statements, grammar) and docs/STD.md were updated, along with the INTERNALS rows.
  - Every example in them runs under the suite.

## Gates

- **Full suite** (Mac, after merging main): 4210 passed, 0 failed, 17 pending.
- **Unit tests** (`zig build test`, fresh cache) pass.
- **Print guard** passes: 62 bytes per site; the bound is 78.
- **JSON guard,** instructions per byte, two runs each, against the merge base: everything is within noise.
  - twitterescaped shows about 0.3% more instructions in both runs.
  - Disassembly of the parser functions (Doc.document, escaped, utf8_text, parse_float) is the same instruction for instruction. Only addresses and panic-symbol suffixes differ.
  - So the parser is no slower.
- **tools/gate** on the PR head runs the suite, corpus and matrix on burst. Its verdict is posted as `rig/gate` on the commit.
- The corpus and matrix were not run separately on the Mac. At -j 2 they take hours, and the gate runs both.

## For the owner

- **The CORE sentence (not added; CORE.md is unchanged):** "A panic ends the program where it stands: its output is flushed, and no drop, `defer`, or leak check runs."
- **Nexus sync:** the diff of the grammar and src/rig.zig is in r3/round1-nexus-sync.diff, regenerated after the merge. The build declares no new conflicts.
- **Untested:**
  - `warn`'s single write for a line of up to 4 KiB is built but not tested (no test watches the syscalls), so SPEC does not claim it.
  - `flushOutput` before stdin and spawn has no caller to test.
- **Process slip:** I built two JSON-guard probe binaries once without cpuq.

## Left out (as designed)

- Rejecting raw bidi controls in literals.
- `dbg` (round B).
- Escaping in panic slots (T1).


## Symbols (branch `symbols`, commit ac1129973, local only, held)

Split off #292 per the owner. `symbols` starts at 82ff55a6e (the pushed
head of r1-render-flush-panic) and adds one commit; nothing pushed.

Built per proposal-symbols.md DRAFT 2, S0-S10:
- Lexer: `Lexer.classifyColon` decides every `:` once (STEP_COLON, `:`,
  SYMBOL_COLON, or an error); `symbolName` reads S6 names
  (`:content-type`, `:a.b`); keyword names (`:if`); keyword arguments
  only right after `(`, `,`, or a closure bar.
- Type `Symbol`, plain; `==`/`!=` only; `.text` (Static, read-only);
  `Symbol.from_text(word)` via src/nametable.zig; print `:name`; hash,
  Map/Set keys; `match` needs `_ =>`, duplicate arms rejected; `.width`
  where a Symbol is expected rejected with the `:width` hint; no
  `U32(s)`, no `from_int`.
- Numbering: src/symbols.zig, whole program, deduplicated, sorted
  bytewise, after checking; `__rig_symbols.zig` (non-exhaustive
  `enum(u32)`, NameTable, `fromText`). Modules write tags by name.
- Docs: SPEC (Symbols section, primitive table, match, printing),
  SYNTAX (literal row, Symbols subsection with the `:` table, patterns,
  grammar summary), STD (Symbol names), INTERNALS (pipeline, source
  map, conflicts rows, Symbols desugaring and numbering), AGENTS map,
  WELCOME row. Editor files regenerated; highlight sample updated and
  checked.
- Tests: 6 behavior + 5 reject, all pass with the `symbol` filter; doc
  examples probed sanitizer-clean before writing; unit tests and build
  green.

Not yet done (held by the coordinator): doc tests through the suite,
`tools/check 10`, a targeted matrix grid, bench/print guard, push, PR.
A full `./test/run --delta` was started on the Mac by mistake and
stopped by the coordinator.
