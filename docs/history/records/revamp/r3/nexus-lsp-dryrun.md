# Nexus PR #50 (`nexus --editor`) dry run on Rig, 2026-10-16

Branch lsp-design @ c5a410d, cloned to scratch, built `-Doptimize=safe`. Nothing pushed, commented or changed in nexus or rig.

## Repro
    nexus --editor --lang ~/Data/Code/rig/src/rig.zig ~/Data/Code/rig/rig.grammar ed
    cd ed/server && zig build -Doptimize=safe -j2      # 11 s; rig-lsp, 2.0 MB
    python3 nexus/test/lib/lsp ed/server/zig-out/bin/rig-lsp PROJECT file.session
Generation 0.2 s, no errors. rig.zig copied with diag.zig (its only import besides parser.zig); no change to Rig needed. Reference: the same sessions through a wrapper running `bin/rig lsp`.

## Works
- Syntax errors on broken code (4 files); positions exact.
- UTF-16: astral emoji and CJK before an error, correct column (2:14); utf-8 mode ok; CRLF ok; BOM file parses, columns right.
- Folding and selection on broken files (@repair works with Rig's tolerant parse). Keyword completion works at line start.
- Speed: open+tokens+folds+selection+completion on a 2,400, 1,346 and 6,395-line file: whole session (process spawn included) 20-140 ms. No request near 100 ms.
- Hook: analyze running `rig check` and mapping `file:line:col: msg` works (rej_enum_from_int.rig -> 10:18-10:29). Whole-session cost with rig check on 6,395 lines: 0.14 s.
- Pre-initialize (-32002), unopened doc (-32602), unadvertised hover (-32601), rename with no analysis (-32803 "no analysis yet: save the file"), untitled: URI document (tokens, folds, parse errors, completion work; definition null; no crash), file doc whose first analysis failed (definition/references null, completion falls to keywords). Exit 0 after shutdown.

## Blockers to landing
1. A failing `analyze` is silent. Repro: open rej_enum_from_int.rig (error shown); change text to start with `#FAILHOOK` (hook returns error.Boom); save. Diagnostics go to `none`, no logMessage/showMessage, nothing on stderr: the file looks clean. lsp.zig analyzeProgram `catch { held.arena.deinit(); return; }`. At least log it (window/logMessage) and keep the last diagnostics or mark them stale. HANDOFF item 4 lists this case as untested; it now is, and the behaviour is the silent one.

## Later (not blockers)
Nexus side:
- Single held analysis, one root: opening an unrelated file re-roots and clears the first file's analysis diagnostics (repro: open rej_enum.. then open hello.rig -> rej diagnostics become none). Rig files are separate programs, so Rig needs one analysis per root or a rule for this.
- analyze runs on the request thread; a slow checker blocks tokens/folds. Fine at 0.1 s.
- Every open/change/save republishes diagnostics for all open files (noisy).
- Node spans include trailing blank lines/comments: fold ends and selection ranges run to the next line start or EOF (hello.rig: fold 2-6 where `rig lsp` gives 2-3; selection parent 3:1-8:1). No comment folds (Rig's lexer wrapper skips comments).
- Selection innermost range is the whole statement (print("x") at `print` gives 4:3-4:22), no token or call level.
- Parse message from lexer error tokens: `...or *%, got err` plus a list of ~60 expected tokens (`;` in uni.rig); `rig lsp` says "Rig ends a statement at the end of its line". Needs parseDiagnostics hook; consider shortening long expected lists generally.
- Diagnostic range for a message with no span is an empty range; fine.
Rig side (hooks):
- Semantic tokens come from @highlight by token text: no comments, function names, types, parameters, properties, sigil modifiers, `invalid`. ownership_tour.rig: 3 keywords/37 punctuation vs rig lsp's 4 keywords, 9 modifier, 6 parameter, 11 comment. Rig needs `tokens` hook over its classifier (src/editor.zig).
- Completion lacks contextual/lexer-classified words (`obj`, `called`, `rarely`, `inline`, `new`, `of`, `else`) and offers `break/continue/true/unique/keeps` where Rig would not. Needs a way to add words, or the visible hook plus analyze.
- `rig check` reads the disk, not the overlay: after an unsaved change + save-less analysis the diagnostic is stale (3:1 clamp in a2). Never-saved path (file not on disk): rig check output unparsable, hook returns zero diagnostics = looks clean. Wants `rig check --stdin` or an overlay option.
- `rig lsp` has no completion or selection; generated server adds both.
