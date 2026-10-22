# lend-base, redesigned

The rule is unchanged: **a lend of a place is never the base of a path.** It has three non-cases: a method receiver, a branch that picks a place, and a lend of a slice.

The old version (tag `lend-base-r1`, bb46d1a0) called its decider from four typing routines: `memberOf`, `indexInto`, `synthSlice` and `writeSlice`. Each review found another routine that reaches a path without passing through one of them:

- review 1: a lend under `<`, and a closure's value;
- review 2: a called function field (`synthMemberCall` -> `dataField`).

Hints had the same problem. A table of contexts chose their sigil, and each review found a context the table got wrong.

## 1. One walk sees every path

The decider runs as one pass over the typed function body. It visits every `member`, `index` and `slice` node in the IR exactly once. Nothing about a path can route around it, because the walk is driven by the tree, not by whichever typing routine handled the node.

- **What the base is** comes from one recorded fact, `lendOf(obj)`. Typing records it once: the lend a base denotes, after parentheses and a `<` of a lend, or nothing. The walk reads that fact and never re-derives it from syntax.
- **A non-case is a positive fact, not a syntax check:**
  - a member that typecheck resolved as a method, which is the callee of a method call;
  - a lend whose operand is a slice;
  - a branch, which `lendOf` already reports as no lend.

  A called function field is a field, not a method, so it is a path and is rejected.
- **The error is always reported.** A hint is extra, so failing to build one never suppresses the error.

## 2. Hints come from what the context takes

A hint replaces the lend base with the bare path, then gives the whole path the sigil the context takes. That sigil is the same fact #89's decider reads:

- a write view is expected, or the path is written by a write call: `!path`;
- a read view is expected where it is not implicit: `?path`;
- a value is expected, or the path is assigned: bare `path`;
- a temporary as the base: "bind it to a name first".

**The suite enforces it.** The hint check (from `lend-base-tools/`) moves into `test/`. It applies every hint in the reject tests and fails if the result does not compile, or does not hit the documented next error.

## 3. Emit parenthesizes any compound base

`emitMemberBase` parenthesizes every base that is not a name, field, element or call: a move, a lend and a branch included. A future decider gap can then fail only as a Rig rejection, never as Zig that does not compile.

## Kept from r1

The tests, the corpus fixes, the docs, the two emit fixes, the grid and the deletion of #89's path machinery all stay.

The new tests:
- function-field calls: `(!t).f(1)`, `(?t).f(1)`, `(<(?t)).f(3)`, and an owned-closure field;
- every hint in a view-taking context;
- the review 2 probes (`review-lend-base-2-probes/`).

## Order

syntax-a lands first; it does not depend on lend-base. lend-base v2 then merges main and passes the full gates, the grid and the hint check. Then comes one review, which also finishes review 2's unrun areas: the sanitizer run over the generated grid, Cells, weak handles, imported modules and the error-suppression spans.
