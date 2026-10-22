# Review: fold (601f9ecd vs main 3ed2964f), adversarial soundness, round 1

Verdict: **not ready to merge.** I found two High findings. One is a use after free in an
accepted program. The fold causes it for `?Text` parameters; the cause predates the fold.
The other is a lost oracle rejection.

Probes: `.git/revamp/r3/review-fold-1-probes/`, 129 programs. `b*` covers UAF through the
view, `c*` the binders and holders, `d*` write-through (D4), `e*`/`f*` holders, `as`, and
Static, `g*` generics, `h*` value flow, and `i*` evaluation order. I ran each one with both
compilers (`check`, plus a `RIG_SANITIZE=1` run when accepted) and both oracles.

## H1. Named arguments: emit reorders, the checker does not (UAF, accepted)

`show(n: grow(!t), s: ?t)` for `sub show(s: ?Text, n: Int)` is checked in source order:
the grow runs first, then the lend. That order is sound. Emit writes the call in
declaration order, though: `show(t.bytes(), grow(&t))`. The bytes are taken before
`grow` reallocates, so the program reads freed memory.

- `i01c-named-args-qtext-param.rig`: **this is a fold regression.** Main emits
  `show(&t, grow(&t))` and prints the grown text (8046 bytes). The fold emits `t.bytes()`
  and fails with "use of freed memory" under `RIG_SANITIZE=1`.
- `i01b-named-args-reorder-print.rig`, with a `String` parameter: the same UAF on main.
  The cause is older than the fold. The fold widens it to every `?Text` parameter and
  every generic `?T` at `T = Text`.
- Struct and enum constructors written out of order keep the written order
  (`i02b`, `i04`), so they are correct.
- Class: emit adds an evaluation order the checker did not walk (AGENTS "The checker
  checks exactly what is emitted"). It applies to any argument a view emits by value
  (a String or a slice), not only to the fold. Fix: emit named arguments in source order
  into temporaries, or check them in declaration order. Sibling to check: named
  arguments in method calls and in generic calls.
- Neither oracle catches it, because the oracle also lowers in source order.

## H2. The oracle lost its rejection of `if ?p as x` / `while ?p as x` over a `Text?`

The old oracle rejects these programs. The new one accepts them, and all of them are
unsafe. The compiler still rejects them.

- In the tree: `fold-grid-if-as-add`, `-assign`, `-drop`, `fold-ret-ifas-local-bad`
  (function `f`), `fold-while-as`. They are not listed in `oracle/rejections`. The PR says
  these were "rejected by the compiler alone", but the old oracle did reject them.
- My siblings: `b05` (field subject), `b06` (assign in a while body), `b12` (an `if as`
  value), `f03` (returned from a field), `f04` (while, then drop), `f06` (Vec element).
- Cause: this is not the removed `.string` access rule. At `lower.zig` lines 865 and 1305,
  `bindHeld(..., self.optionalInner(h.ty))` passes the subject's type, which is
  `?(Text?)`, a read view. `optionalInner` does not unwrap the view, so `stored` is null
  and `views_text` is false. The surviving `carry_from` String rule then copies the root's
  loans instead of lending the holder.
- I verified a one-line fix, then reverted it: in `optionalInner`, switch on
  `self.ctx.types.get(sema.unwrapViews(self.ctx, ty))`. Over all 12668 programs in the new
  tree, it brings back exactly those 5 rejections, changes no other verdict, and adds no
  prod-accepts difference. It also catches the six sibling probes, and the
  `fold-grid-ctl-if-as` and `fold-ret-ifas-param-ok` controls stay accepted. Then add
  the 5 programs to `oracle/rejections`.

## Removing the oracle `carry` rule: no other loss

- Same sources: I ran the old and new oracle over the new tree (12668 programs). The only
  rejections lost are the 5 in H2.
- On the old tree's sources, the new oracle loses 7 rejections. Each one follows from the
  fold's semantics and is safe, or the compiler still rejects it:
  - `r3-or-handle-unsound drop_while_viewed` and `return_view_of_local bad`: the String
    views a literal (D2). The first runs clean (`f02`).
  - `r3-s36-loans-t09`, `text_st04`, `p47`, `static-owned_closure_string_param`,
    `text_string_param_in_cell later`: `+s` is now a Text (D3), and all run
    sanitizer-clean.
- String fields reached through a view still carry their loans in both checkers
  (`c24`, `c25`, `c23`). The literal controls are accepted (`c24b`, `c25b`).

## Use after free through the folded view (item 1): no hole found besides H1

The compiler rejects every unsafe probe:

- the direct, field, `*Text`, shared-struct, and Box holders; `(?Text)?`, `Box[?Text]`,
  `String?`, `Vec[String]`, and Cell holders;
- generics: `?T`, `?(?T)` at String, generic struct, method, and enum payloads;
- closures; match payloads: positional, named, catch-all then nested, nested enum, a
  struct field of a payload, a match value, bare match;
- `if as` and `while as` (bare, `?`, field, element, `(!Text)?`); `for` (indexed, array,
  field, slice of a slice, write);
- String slice chains; a Static/Text join; `catch` and `??` values; temporaries
  (`match ?mk()`, `if ?mk() as`).

The controls run sanitizer-clean. The `bindPayload` fix holds for the named and
catch-all siblings (`b01`, `b02`, `b03`, `h07`–`h10`).

## `.bytes()` timing (item 2)

- Apart from H1, receivers, operands, and positional arguments are rejected where a
  later write would follow an earlier read (`b21`–`b26`, `i03`, `i06`).
- Loop, payload, and `as` bytes are taken at bind time, under a live loan. Captures take
  them at creation, and the closure's loan keeps the Text unchanged until its last call.

## `!String` removal (item 4): nothing silently copies

These constructs still bind a write view of a String slot and write through:

- `for x in !Vec[String]`, `for x in !array`;
- `match !e` and generic `match !` on a String payload; `if !o as p` (also generic
  `!T?`);
- `![]String`, struct fields written through `!H`, a `|!h|` capture, and a local `!h`;
- generic `!T` at String (`d01`–`d15`).

Every one writes through, with the same output as main. Low: D4 is enforced only for an
explicit `!s` (and `!String` as a written type). Constructs and generic bodies still make
`!String` bindings (`d01`, `d15`). That is sound, but it does not match the CORE wording
proposed in pr-fold.md ("nothing lends a String place to write").

## Low

- `!v.push(+(?v[0]))` on a `Vec[Text]` was accepted on main and is now rejected ("read
  loan is live"; `b29`, `b33`). Under D3, `+(?v[0])` is a fresh Text, so this is a
  prod-strict regression. `c = +(?t)` alone is accepted (`b31`).
