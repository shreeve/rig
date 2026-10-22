Lifts the 64 KB limit on a token by opting into Nexus's `@longtokens` (shreeve/nexus#33, Nexus main ad8f45c). A string literal, raw (`'...'`) literal, name, number, or comment may now be of any length up to the 16 MiB source limit.

## Design

A token over 65534 bytes keeps its category, and its `len` of 65535 stands for "longer". Its end is read in one place per side:

- **Lexer side:** `rig.endOf(base, tok)` gives the end from the lexer's record (`base.longEnds`). Every lexer-side `pos + len` goes through it.
- **Parser side:** `BaseParser.tokenEnd` and `tokenText`.
- **Leaves (every pass after the parse):** `rig.leafEnd(source, leaf)`. `rig.leafText` and `rig.leafSpan` read it.

**One departure from Nexus's guidance.** Nexus suggests reading leaf ends through `BaseParser.leafEnd`. About 100 call sites in sema, resolve, typecheck, emit, and storage hold only `source`, not the parser, and they all read text through `rig.leafText`. So `rig.leafEnd` finds a long leaf's end by running the generated lexer again from the leaf's start. That lexer keeps no state between tokens, and the wrapper never builds a long token for the parser, so the scan gives the end the parser kept. `Parser.parseTree` checks this for every long token and panics if the two ever disagree.

## Sites (the class: every token or leaf end and every slice by token span)

Lexer side, `src/rig.zig`, through `endOf`:
- `keyword()`: `tok.len == word.len`
- `Lexer.next`: `prev_end`
- `produce`: the special case for a 65535-byte `.err` comment is removed. A comment is now one `.comment` token of any length.
- `lineBreak`: the newline's end
- `checkSpacing`: `Layout.len`
- `charAfter`
- `nextIsName`: this read a token scanned by a probe through `self.base.text`, which would panic on a long name after `obj` or `new`. It now reads `probe.text`. The new test catches the old code.
- `lexError`: the `too_long` error is removed, along with `LexError.too_long` and its message.

Parser side, `src/rig.zig`:
- `diagnostic()`: `BaseLexer.makeToken` on the failure span would panic on a long token. The token is now built with `base.token`, and its end comes from the span.
- `openRange`: `tokenEnd`
- `foreignWord`: reads the word with `tokenText`, and the scan of the first word no longer builds a token with `makeToken` (that panicked on a word over 64 KB).
- `inclusiveRange` and `detachedPrefix`: `probe.text`
- `isBindingName`: `getText` → `leafText`

Leaves:
- `rig.leafText` now uses `leafEnd`.
- `diag.leafSpan` moved to `rig.leafSpan(source, …)`. Its callers are in sema.zig (×4), ownership.zig, and proofs.zig.
- modules.zig: 4 × `getText` → `rig.leafText`. `error.TokenEndUnknown` is unreachable, because `Lexer.next` returns each token it scans before it scans another.
- main.zig: `rig tokens` reads its error end through `endOf`. `rig parse` and `rig normalize` print through the new `rig.writeTree` (`Sexp.write` panics on a long leaf). `declaresMain` uses `leafText`.
- test/oracle: 23 × `getText` → `lower.leafText`. This gives the same output as `getText`, except that it returns the whole text of a long leaf.

Checked and left unchanged:
- Layout `sp.pos + sp.len`: `Layout.len` is a `u32`, now computed through `endOf`.
- typecheck `checkEscapes` `pos + i`: `i` is an offset into the whole text.
- typecheck leaf identity (`pos` and `len` equal): two long leaves at one position are the same token.
- The hint helpers: they read positions before `tok.pos`.
- `BaseParser` spans: Nexus already reads long ends there.
- Two tests that use `pos + len` (facts.zig:857, sema.zig:8164).

## Source limit

`readFileAlloc(.limited(16 MiB))` rejects a file of exactly 16 MiB ("reached or exceeded"), while the message says "larger than 16 MiB". Both reads now pass `max_source_bytes + 1`, so a file of up to 16 MiB is read. SPEC §1 now states the limit and that a token may be of any length within it.

## Docs

- INTERNALS: the 65535-byte bound is replaced by the long-token design above.
- SPEC §1: the source limit.
- RIG-NOTES #18: long literals are marked fixed; `@embed` stays open.

## Tests

`test/cli/long_tokens.sh` generates its programs in the script, not in the repository. It covers:
- `"..."` (with escapes) and `'...'` (with `''`) literals of 65532–65536 bytes and 1 MiB, checked by length and a hash, sanitizer-clean in debug and `--release`;
- a 70 KB name, a 70 KB obj name, a 70 KB-zero hex literal, and 70 KB comments: whole-line, trailing, and inside brackets;
- every CLI mode (`check`, the three `--facts` modes, `tokens`, `parse`, `normalize`, `emit`). The emitted Zig holds the 1 MiB literal on one line and passes `zig ast-check`;
- a `test` named by a 70 KB string;
- 11 diagnostics after or inside a 70 KB token, each checked for line and column: unbound name on the same line and on the next line, a bad escape at the end of the literal, a control character, an unterminated string, a malformed number, an unexpected token after and at a long token, a foreign first word, a detached prefix, and operator spacing;
- a 16 MiB source is read, and 16 MiB + 1 is rejected.

The unit test for `too_long` is replaced by tests of long-token categories and ends, of `leafEnd` and `leafText` against the parser's kept end, and of `leafSpan`. Against main's `bin/rig` the new script fails at once with `token is longer than 65535 bytes`.

## Gates

- `zig build`, and `zig build oracle`
- unit tests: 164/165 passed (1 skipped)
- `test/cli/long_tokens.sh`: passes
- `./test/run --delta` (Mac, -j 2): 3486 passed. Two CLI tests timed out under load (`cli/results_cache`, `cli/test_prune`) and passed when rerun alone, in 28 s.
- `test/equiv.py` (pup) against main 4db1ff2's `bin/rig`: 12914 programs, 0 differ. No parse, normalize, check, facts, emit, or package output changes for any program under 64 KB.

## For the owner

- docs/json/DESIGN.md:187 and test/json/compare.py:51 (`CHUNK = 60000`) still describe the 64 KB token. They belong to std.json and are left to that session. std.json's tests and benchmark could stop splitting files into 60 KB literals.
- Nexus has no long-aware form of `Sexp.write`, so Rig added `rig.writeTree`. A `BaseParser.writeSexp` in Nexus would let Rig drop it.
