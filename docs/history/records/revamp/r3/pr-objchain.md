# Spell struct as obj, and continue a statement on a leading-dot line

## Summary

Two owner-confirmed v0.3.0 syntax changes.

1. **`obj` replaces `struct`.** `obj Point`, `pub obj Pair[T]`, `obj Random unique`.
   `obj` is a keyword only at the start of a statement (after any `pub`) when a name
   follows it. Everywhere else it is an ordinary name: `obj = 5`, `obj.x`,
   `fun f(obj: Int)`, a field `obj: Int`. `struct` is an ordinary name too; a declaration
   written `struct Name` is rejected with: "Rig has no `struct`; write `obj Name`:
   `struct` is spelled `obj`". The IR node is still `struct` / `generic_struct`.
2. **Leading-dot chains.** A line indented deeper than its statement that starts with
   `.name` continues the statement above, and so does each further such line. Blank and
   comment lines between them do not end the chain (layout already skips them). The rule
   is positive and lives in the lexer (`continuesChain`): the previous statement ends in a
   complete operand, its line has none of the tokens that open a block (`fun sub enum
   error if else while for match test raw extern drop obj`), and its block is not a
   member list or the arms of a `match`. So `x = match c` and `match c` keep their arms,
   and an arm `.red` with its body below keeps a `.blue => ...` body line.

Because every statement may start with a name or a declaration, `obj` could not use the
`@keywords`/`@as` promotion that `unique`, `from` and `static` use: in that state the
parser accepts both, and promotion would turn every statement-initial `obj` into the
keyword (`obj = 5` fails). The lexer wrapper classifies it, as it does `new` (docs/INTERNALS.md,
Keywords). See "Decisions to confirm".

## Migration

| Before | After |
|---|---|
| `struct Point` | `obj Point` |
| `pub struct Pair[T]` | `pub obj Pair[T]` |
| `struct Random unique` | `obj Random unique` |
| `struct = 3`, `f(struct: 1)`, `x.struct` | unchanged (an ordinary name) |
| `# struct Point`, `"struct Point"` (comment, string) | unchanged |

`tools/migrate-0.3.py` gains the `obj` mode (run with the other three on a 0.2 file or
directory; idempotent; `# error: L:C:` directives move). `test/cli/migrate_tool.sh`
checks it: pub, generic, unique, `struct` as a name, a comment, a string, a file already
written with `obj`, and that the migrated program runs.

The tree (7,669 `.rig` files, the docs' fences and inline code, the generators in
`test/matrix.py` and the `test/cli` scripts, the compiler's own comments and unit tests)
was rewritten by `.git/revamp/r3/objchain/bulk.py` and `bulk2.py` (re-runnable).

## Evidence

- Unit tests: `obj` as keyword and as name, `struct` as name, chains (blank/comment gaps,
  same indent, `.5`, headers, member lists, arms).
- Behavior (debug and `--release`, sanitizer-clean): `obj_declaration`, `obj_is_a_name`,
  `leading_dot_chain` (binding, assignment, return, argument, closure body, a following
  statement at the original indentation), `leading_dot_chain_gaps`, `match_arms_stay_arms`
  (statement and value `match`).
- Reject: `struct_retired`, `struct_retired_pub_generic`, `dot_chain_not_after_header`,
  `dot_chain_not_after_arm`, `dot_chain_needs_deeper_line`, `dot_chain_not_in_members`.
- Gates on the merged tree (main 57b4d740): suite 3222 passed, 0 failed; corpus 10032
  passed; matrix 7140 programs, 3626 ran clean, 3514 rejected, 0 failed (identical counts
  to main's); unit green; `nexus` reports no conflicts (no `@conflicts` block).
- Compare (`objchain/compare_rewrite.py`, main's compiler on the original source against
  this compiler on the rewritten source): 7582 programs; 2637 both accept with identical
  emitted Zig and sanitized package; 4938 both reject with the same messages; 7 differ,
  all by wording the change intends (the hint now names `obj`), plus
  `test/corpus/R11a-k_type`, a type named `type` that both reject, now at `obj type`
  ("expected `:` or `=`" for "expected a name").
- `test/equiv.py` is not run: it feeds both compilers the same tree, and main's compiler
  rejects `obj`. The compare script is its counterpart for a rewrite.
- `test/oracle/rejections`: 15 doc keys re-keyed (a doc example's key is the checksum of
  its text, which the rewrite changed); no entry gained or lost.

## Decisions to confirm

1. **`obj` is classified by the lexer wrapper, not `@keywords`.** Reason above. The cost
   is that `rig tokens` prints `obj` for the keyword (like `new`), and `obj` followed by a
   reserved word (`obj type[T]`) reads as the name `obj`, so the message is the parser's
   "expected `:` or `=`" rather than "expected a name". Confirm.
2. **`struct` is an ordinary name**, rejected only at a declaration start, with the hint.
   Zig's reserved-word escaping of an emitted `struct` identifier is unchanged.
3. **The IR node stays `struct` / `generic_struct`**, and prose (docs, diagnostics) still
   says "a struct" for the concept, and `obj` for the keyword. Rename the concept in prose
   too?
4. **Chain scope.** A chain also follows a complete arm body (`.red => foo()` then a deeper
   `.x`) only when the arm is not in a `match` block (arm blocks never chain), and it does
   not apply inside `( )`/`[ ]`, where a newline was already whitespace. A statement whose
   line holds a block-opening token (`fun`, `if`, `match`, ...) anywhere, such as
   `f: fun(Int) -> Int = make()`, does not chain; that is the conservative side. Confirm.
5. **Blank and comment lines** between chain lines do not break the chain (layout skips
   them before the rule is asked); a comment at the statement's own indentation also does
   not. Teaching text for SYNTAX is in the Line joining paragraph.

## CORE / teaching text

No CORE change: neither feature touches ownership. SYNTAX gains the Line joining sentence
and a runnable example; the "Seven words are keywords only in one position" paragraph
names `obj`.
