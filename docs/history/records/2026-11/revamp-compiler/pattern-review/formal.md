# Rig patterns: a formal review

Reviewer angle: the mathematics. Rig under test:
`.git/rig-baseline/dd355f669a06ebd37bba85738099466432d18034/rig`.
The probes are in `formal/p/*.rig` (run them with `formal/run.sh`), the generator is
`formal/gen.py` (logs `formal/equiv.log` and `formal/cover.log`), and
`formal/cover2.py` (log `formal/cover2.log`) sorts the dead-arm cases.
λRig (`formal/`) has nothing on enums or patterns: no sum types, no `match`.
Nothing below is proved in Lean.

## 1. Semantics

**Values.** A value is `v = t(a1..ak)`, a tag and its fields. A field of type
`T?` holds `none` or `some a`.

**Binders** (grammar `pbind`; patterns are flat, so there are no nested
sub-patterns or literals in a payload). `B[b] : field → Env⊥`:

| b | B[b](a) |
|---|---|
| `_` | `{}` |
| `x` | `{x ↦ a}` (the field's type, so `Int?` on an optional field) |
| `x?` | `{x ↦ a'}` if `a = some a'`, else ⊥ |
| `_?` | `{}` if `a ≠ none`, else ⊥ |
| `none` | `{}` if `a = none`, else ⊥ |

**Patterns.** `M[P] : Value → Env⊥`:

- `M[.t](v) = {}` if `tag v = t`, else ⊥ (rule 1: a bare variant tests only the tag)
- `M[.t(b1..bk)](v) = ⊎i B[bi](ai)` if `tag v = t`, where k is the variant's arity exactly (rule 2)
- `M[.t(g1: b1 .. gj: bj)](v) = ⊎i B[bi](a_idx(gi))` if `tag v = t`, for distinct field names gi (rule 3)
- `M[c](v)` for a literal, range, symbol, string or qualified constant is `{}` if `v ∈ S(c)`, else ⊥
- `M[(P1, .., Pn)](v) = M[Pi](v)` for the least i where it is defined (rule 4)

`⊎` is the union of maps with disjoint domains. It is total because the
checker rejects a name bound twice.

**Static scope.** `N(c)` is the set of names visible after condition `c`:
`N(e matches P) = dom P`, `N(c1 and c2) = N(c1) ⊎ N(c2)` with the two disjoint,
and `N(c1 or c2) = N(not c) = N(anything else) = ∅`.

**Dynamic.** `C[c]ρ` gives a Bool and an environment:

- `C[e matches P]ρ = (true, ρ ⊎ M[P](⟦e⟧ρ))` if `M[P](⟦e⟧ρ)` is defined, else `(false, ρ)`. `e` is evaluated once.
- `C[c1 and c2]ρ = C[c2]ρ1` if `C[c1]ρ = (true, ρ1)`, else `(false, ρ)`: the right side short-circuits.

**Lemma (scope soundness).** If `C[c]ρ = (true, ρ')` then `dom ρ' ⊇ N(c)`. The
proof is by induction on c, and the `or` and `not` cases hold trivially
because their N is ∅. The body of an `if`/`while`, and the then-value of a
ternary, see `N(c)`. `else` sees nothing.

**Bool.** `⟦e matches P⟧ = isSome(M[P](⟦e⟧))`, which is
`match e { erase(P) => true; _ => false }`. Here `erase` puts `_` for every
name and `_?` for every `x?`. Unread names are rejected, so in a Bool the
names in P must be read after an `and`.

**Coverage.** Because binders are flat, the only refutable parts are the tag
and the some/none state of each optional field. So the space of variant t is
exactly `{S,N}^(its optional fields)`, a finite set. An exact checker is
therefore possible: arm j is dead iff `cells(Pj) ⊆ ∪_{i<j} cells(Pi)` (guards
excluded), and a match is exhaustive iff the union of all cells is the whole
space.

**Disjoint alternatives.** The checker rejects two alternatives with the same
tag. So in an accepted list the alternatives match disjoint sets of values,
and `M[(P1..Pn)] = ∪ M[Pi]`, a union of partial functions with disjoint
domains. That makes it invariant under permutation. Order can change neither
which alternative matches, nor the value bound, nor which names exist.

## 2. Properties

| # | Property | Verdict | Evidence |
|---|---|---|---|
| W1 | Bare variant = tag test | holds | a10, shapes 1/7a |
| W2 | Positional needs full arity; `_` skips one | holds | a04 (1 of 2), a07 (`()`), a09 (3 of 2) rejected |
| W3 | By-name: any subset, any order; field bound twice rejected; unknown field rejected | holds | a05, a06; generator: every subset in both orders |
| W4 | Mixing positional and by-name rejected | holds | SPEC reject example |
| W5 | A name bound twice in one pattern, or across `and`, rejected | holds, but the message is wrong | a01, a02, d08 say "shadows the local `a`" and add a spurious "bound but never read" |
| W6 | One meaning per field position | holds, with a hazard | a03: `.rect(h, w)` binds `h` to the **w** field without a word. `.rect(h, w)` and `.rect(h: h)` give `h` different fields. Rejecting a positional name that equals a *different* field's name would be an exact, cheap rule. |
| W7 | Constant in a payload is not read as a comparison | holds | a11: rejected ("same name as the module-level declaration") |
| A1 | Alternatives bind the same names with the same types | holds | b06, b07, b10, i07 rejected with the right message |
| A2 | Overlapping alternatives rejected, so order cannot matter | holds (conservative) | b01, b02, b03, b09: `(.rect(x,_), .rect(_,x))` rejected; b08: permuted lists agree. **Over-strict:** disjoint same-tag lists are rejected too, `(.ready(_?), .ready(none))` (c01) and `(.pair(x?, none), .pair(none, x?))` (c10). The message says "duplicate arm" for two alternatives of one `matches`. |
| A3 | `matches (P1,..)` ≡ arm `P1, .. =>` | **fails (North Star 1)** | **85 of 85** generated lists where one alternative binds `m?` and `m` is read *in the condition* (after `and`, as a Bool, or in a ternary) are accepted by `rig` and then fail in Zig: `expected type 'i64', found '?i64'`. Minimal: i03 `print(v matches (.b(m), .d(m?)) and pos(m))`. The same fails in `if … and pos(m)` (i11), in `while` (i12), in a ternary (i08), and with both sides `m?` (i09). The if-body (i01) and the match arm (i02) are correct. Emit builds `switch (v) { .b => v.b.x, .d => v.d.p }` without unwrapping `p`. |
| B1 | `and` binds into its right side and the body only when matched; short circuit | holds | f02: the guard runs only on a match, d14 (left side cannot see it), d05/e02 (`else` cannot), d17 (after the `if`) |
| B2 | `or` and `not` bind nothing visible | holds; the messages mislead | d01, d02, d04, d06, d15, d16, d18, d20, e04, e05 are rejected, but most say "`r` is bound but never read" when the user does read `r` (below the `or`). d03 says "unbound", which is right. d09 (`not (… and …)`) is accepted with nothing bound: correct. |
| B3 | Ternary `x if c else y` | holds, undocumented | e01, e03: `r if s matches .circle(r) else 0` binds `r` in the then-value, and is correct on both branches. e06: `as` does the same, though SPEC §"Joined bindings" says `as` is "not in the condition of a ternary". The postfix guard (d12) rejects: consistent with SPEC, but now the one form that differs. |
| E1 | `matches` ≡ `P => true, _ => false` | holds on every single pattern | gen: 453 single patterns (every tag, positional, by-name subset in both orders, `x?`/`_?`/`none`) × 15 values × 5 forms: 0 disagreements. Also 105 alternative lists without `x?`: 0 disagreements. |
| E2 | A pattern means the same in `matches` and `match` | **fails (consistency)** | h01 vs h02/h03/h07: a module constant `K` (or an enum constant `WARM`) compares as a match arm, but after `matches` it is rejected as "matches every value", a false statement. Qualified `lim.K` works in both (mod/main.rig). SPEC documents the rejection ("use `==`"), but the message is wrong and rule (5) has this exception. |
| X1 | No false "exhaustive" (soundness) | holds | cover: 0 missed non-exhaustive in 819 sequences. g15 finds the U8 gap. |
| X2 | Exhaustiveness exact for tag, positional, by-name, `_` | holds | j01 (a by-name subset covers its variant), j03, j06, g13, g14 |
| X3 | Exhaustiveness exact for optional fields | **fails (incomplete, safe)** | 56 of 819 sequences are exhaustive but rejected. An arm that tests two optional fields covers nothing: k01 enumerates all four cells `(_?,_?),(_?,none),(none,_?),(none,none)` and is rejected with "misses `.d` (its arm has a guard)", though it has no guard. Arms on different fields do not combine: k03, k04, where the message names a missing case that is covered. One field split across arms works (c06, k02). |
| R1 | Unreachable and duplicate arms rejected | holds for tags, literals, ranges and catch-alls | j02, j07, j08, j09, g12, c07, c09; 198 of 198 exhaustive dead-arm sequences are reported as dead |
| R2 | Same for optional-test arms | **fails (missed)** | 28 accepted matches have a dead arm: c08 `.ready(_?) => 1; .ready(_?) => 2`, and k05 / cover2.log, e.g. `.d(p: _?) \| .d(p: _?) \| .d(p: none)`. This contradicts SPEC "Duplicate and unreachable arms are rejected". |
| M1 | `matches` never constant | holds | `_`, a bare name, a one-variant enum, `(true,false)`, a full U8 split, and all variants listed are each rejected (g01-g04, g07, g16, j10, j11). The message for them is the leaked "this arm never runs". |
| V1 | Scrutinee evaluated once | holds | f01 (`mk` prints once per test, with alternatives, `and`, and match guards), f03 (`while`: once per iteration, plus the failing one) |
| V2 | Guard after `and` runs only when matched; arms' guards tried in order | holds | f02, f04 |
| V3 | Field reads have no effects | holds by construction | fields are plain loads; there are no getters |

## 3. Doc drift found

- SPEC §12 (line ~10788) and docs/design/matches.md say an optional test "covers none of its variant's values", and matches.md "Later, not now" lists `.ready(r?)` + `.ready(none)` coverage as unbuilt. It is built for one field (c06, and c07's message "`.ready(v?)` and `.ready(none)` cover `.ready`").
- SPEC "Joined bindings" says `as` is not allowed in a ternary's condition. It is accepted and binds (e06), and so does `matches` (e01).

## 4. Suggested fixes, by weight

1. **A3** (an accepted program fails in Zig). In the condition and Bool lowering of alternatives, unwrap a `name?` binder the way the if-body path does. Add the generator's case class to the tests: alternatives × `x?` × {and, Bool, ternary, while}.
2. **X3/R2**. Compute coverage on the cells `{S,N}^k` of each variant, which is exact and at most 2^k. That fixes the false non-exhaustive results, the dead optional arms, the "its arm has a guard" message, and A2's rejection of disjoint same-tag alternatives (or keep that rejection and say "two alternatives of `.ready`" instead of "duplicate").
3. **E2**. In `matches`, resolve a bare constant as `match` does. Failing that, say "`K` is a constant; compare with `==`".
4. Messages for W5 and B2. Optionally, the W6 rule.
5. Docs: §3 above.
