# Oracle triage: Trig's accepted-by-compiler, rejected-by-oracle functions

Consolidation round 2, track 3, step 1. Measured 2026-10-24.

- Rig: main 634f9c764, worktree ~/Data/Code/worktrees/rig/oracle-triage (built with
  `tools/heavy zig build` and `tools/heavy zig build oracle`; no code changed, nothing committed).
- Trig: ~/Data/Code/trig main d090e97, its `src/*` copied flat beside `main.rig`
  (tools/trig/main.rig) in
  /private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/e969f22a-9df2-4b7d-be7d-d73f157fafcd/scratchpad/oracle3/,
  plus `all.rig`, a root that `use`s all 34 modules.
- Run: `cd oracle3 && RIG_OUT_DIR=... tools/low bin/rig-oracle trig=main.rig all=all.rig`
  (`-v` for every verdict, `--explain Type.method` for the lowered core).
- Probes: /private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/e969f22a-9df2-4b7d-be7d-d73f157fafcd/scratchpad/probes/

## Result

Seven differences today, not six: `core.first_non_zero` is new (Trig 5dac384 gave public
generics `[E: Copy]` bounds, so the oracle now decides it), and `or_else`/`coalesce` changed
class from C2 to C5 for the same reason. **All seven are oracle imprecisions; no compiler
hole was found.** Each is reproduced in a standalone probe that the compiler accepts, runs
clean under `RIG_SANITIZE=1`, and the oracle rejects with the same rule. Each class also has
a control: the unsafe sibling shape is rejected by both checkers.

| Function | Oracle says | Verdict | Why |
|---|---|---|---|
| `core.or_else` (core.rig:373) | C5 `value` does not live long enough | imprecision | `E: Copy`, but the oracle kinds `E?` as owning, so `if value as v; return v` returns a copy still carrying a pointer loan on the local `value` |
| `core.coalesce` (core.rig:382) | C5 `a` does not live long enough | imprecision | same shape |
| `core.first_non_zero` (core.rig:244, new) | C5 `value` does not live long enough | imprecision | same shape, over a slice's elements |
| `CopyOnWriteMap.get` (cow.rig:64) | C6 a view of `k` leaves, `from` does not name it | imprecision | ignores the callee's `from @`: `Map.get` is `-> (?V)? from @` |
| `MultiMap.get` (multimap.rig:14) | C6 a view of `key` leaves | imprecision | same |
| `Parser.parse_jsx_element_or_...` (parser.rig:4584) | C1 use of `lc` after move | imprecision | oracle bug: a value block's `tail_floor` leaks into its non-final statements, so `lo = x ?? lc` "moves" the plain `lc` |
| `TextWriter.write_line_raw` (textwriter.rig:143) | C9 a value carrying a loan on `@` would be stored in `@` | imprecision | `!@builder.add(@new_line)`: a `String` holds no view, so nothing stored carries the loan; C9 does not filter by what the target can hold |

## 1. `core.or_else`, `core.coalesce`, `core.first_non_zero` (C5; were C2)

**Rejection.** `C5 955:12 \`value\` does not live long enough: a loan of it is still live`
(coalesce: `a`; first_non_zero: `value` at 827:14). Rule C5 = CORE s3, s6, §3: "nothing is
dropped while a loan of it is live".

**Source.**

```
pub fun or_else[E: Copy](value: E?, default_value: E) -> E
  if value as v
    return v
  default_value
```

`coalesce` is the same; `first_non_zero[E: Copy](values: []E?) -> E?` is
`for value in values; if value as v; return v`. Ownership: `value` is a parameter of type
`E?` with `E: Copy`; `if value as v` reads its payload in place (s1, a header's subject);
`return v` copies an `E` out (s1: a bare name copies plain data and read views).

**Lowered core (`--explain or_else`).** `value:owning`, `default_value:read_view`,
`v:read_view`; `lend temporary = ?value (L0)`, `copy v = the as value` (carries L0),
`copy result = v`, `kill value`, `ret result` → C5, because the result still carries L0.

**Verdict: imprecision.** In kinds.zig the bounded type variable `E` is classified by its
bounds (`Copy` without `Owned` → read_view, holds_pointers), but `E?` falls through to
`ti.holds_type_var` → `.owning`. So the oracle sees an owner whose payload is lent in place,
and the copy out keeps the pointer loan on the local holder. Per CORE s7 ("A view reached
through a read view that a value holds carries that view's loans, not a loan on the holder")
and SPEC "Generic bodies" (a bounded parameter is checked against its bounds alone), a copy of
an `E: Copy` carries whatever loans the instance's `E` carried, never a loan on `value`, which
an `E` stored inside `value` cannot point at (§5, a value never holds a view of itself). The
oracle accepts the same body written with a concrete `(?String)?` (`or_else_s` in the probe),
which settles it.

Before Trig's bounds (Trig 0bac3fa, `[E]` unbounded) the oracle said C2 ("a bare `v` owns a
resource and would be copied"). That too was an imprecision: the compiler records the copy and
rejects each owning instance at its call (probe `c2_unbounded.rig`: `or_else[String] cannot use
E = String: the generic body copies a E`), as SPEC "Generic bodies" says.

**Probes.** `probes/c5_generic.rig` (compiler: runs, prints `hello hello 3 4 world`,
sanitizer-clean; oracle: DIFF `or_else` C5, DIFF `first_non_zero` C5, accepts `or_else_s` and
`or_else_i`). `probes/c2_unbounded.rig` (the historical C2 shape).

**What the oracle needs.** Classify a type built from bounded type parameters by their bounds
(`E?`, `[]E` of `E: Copy` copies as `E` does) instead of `holds_type_var → owning`.

## 2. `CopyOnWriteMap.get`, `MultiMap.get` (C6)

**Rejection.** `C6 69:16 a view of \`k\` leaves the function, whose \`from\` does not name it`
(MultiMap: `key`, 150:6). Rule C6 = CORE s7: "A function returns a view only of what it was
lent ... when the result says `from a`, of `a` alone."

**Source.**

```
pub fun get(?@, k: ?K) -> (?V)? from @        # CopyOnWriteMap[K, V]
  i = @layers.len
  while i > 0
    i -= 1
    if @layers[i].get(k) as v
      return v
  none

pub fun get(?@, key: ?K) -> (?List[V])? from @   # MultiMap[K, V: Eq]
  ?@m.get(key)
```

Both return what built-in `Map.get` returns, and `std/__rig_builtin.rig:110` declares
`pub fun get(?@, k: ?K) -> (?V)? from @`.

**Verdict: imprecision.** CORE s7: "Its result carries the loans of the arguments whose types
could hold what it views, or, when the result says `from a`, of `a` alone." The oracle reaches
by type alone: with K and V generic, `V` could hold what `k` views, so it lets `Map.get`'s
result carry `k`'s loan, ignoring the callee's `from @`. The compiler honors the `from` and
checks each body against it, so trusting it at the call is sound. (This matches
oracle-abstain.md's E2 finding.)

**Probes.** `probes/c6_from_self.rig`: the same two methods on user objects; `main` drops the
key (`<key`) while the result of `?l.get(?key)` is still used, and it runs clean under the
sanitizer (prints `x`, `true`) — the result really does not view `k`. Oracle: DIFF on both, C6.
Control `probes/c6_control.rig`: a `from @` method that does return `k` (directly, and after a
`Map.get`) is rejected by both checkers ("`bad` returns a view of `k`, but its signature says it
views only `@`").

**What the oracle needs.** In sentence 7, a call's result carries only the loans of the
arguments its callee's `from` names (oracle-abstain.md ranked step 2).

## 3. `Parser.parse_jsx_element_or_self_closing_element_or_fragment` (C1)

**Rejection.** `C1 5842:41 use of \`lc\` after move` (parser.rig:4603, `lc_children =
@ast.children(lc)`). Rule C1 = CORE s1, s2: a name is used only while it holds a value.

**Source (parser.rig:4587-4604).** `r = match @kind(opening)`, arm `.JsxOpeningElement` is a
value block ending in `result`; inside it `if last_child as lc` (`lc: Node`, a plain object
`{id: U32}`), then

```
le = @ast.jsx_element(lc)
lo = le.opening_element ?? lc        # the oracle moves lc here
lc_children = @ast.children(lc)      # C1
```

Ownership: `lc` is plain data; every use copies. Nothing moves.

**Lowered core.** `move def=temporary#51 m:lc#35 whole(lc#35)` in the `??` fallback branch.

**Verdict: imprecision — an oracle lowering bug.** lower.zig `valueInto`'s `.block` case (and
`armValue`) sets `tail_floor` for a value block's last value, but the block's non-final
statements are lowered while an outer `tail_floor` is still set (from the enclosing match arm
or `if` arm). `lo = x ?? lc` goes `fallback → valueInto(handler) → storeValue`, which sees the
floor and applies the "a block's own binding, as its last value, leaves with it" rule
(`moveWhole`) — to a non-tail statement, and to plain data. CORE s1 moves a name only "where the
value leaves for good ... `x` as the last value of the function or block that declares `x`";
neither holds here.

**Probes.** `probes/c1_tail_min.rig`, nine lines each:

```
fun a(k: Int, o: Int?) -> Int
  r = if k == 1
    x = 5
    y = o ?? x
    print(x + y)
    7
  else
    0
  r
```

Compiler: accepts, runs clean, prints 10. Oracle: `C1 use of \`x\` after move`. The same with an
`if o as v / v / else / x` value instead of `??` (function `b`). The same statement outside a
value block (function `c`) is accepted. `probes/c1_tail.rig` is the Trig shape (match arm,
`if last as lc`, `Node` object). Control `probes/c1_tail_owner.rig`: with `x: String` both
checkers reject (`x` owns a `String` ... write `<x`), so the compiler is not treating it as a move.

**What the oracle needs.** Clear `tail_floor` while lowering a value block's non-final
statements (only its last value runs under the floor).

## 4. `TextWriter.write_line_raw` (C9)

**Rejection.** `C9 9295:6 a value carrying a loan on \`@\` would be stored in \`@\`: a value
never holds a view of itself`. Rule C9 = CORE §5: "a value never holds a view of itself".

**Source (printer/textwriter.rig:143).**

```
sub write_line_raw(!@)
  @last_written_start = @builder.len
  !@builder.add(@new_line)          # TextWriter: new_line, builder: String
  ...
```

Ownership: `@new_line` is lent to read for the call, `@builder` to write; disjoint fields (s5).
`String.add` copies bytes; a `String` holds no view.

**Verdict: imprecision.** CORE s7: "What a call stores in what a write view lent to it sees
carries ... the loans of the arguments whose types could hold it". A `String` cannot hold a
view, so nothing stored in `@builder` carries the loan on `@new_line`. flow.zig's C9 check
takes the op's whole store flow (`flowOf(op, ..., no_store, store_loan)`) and tests only
`storesInto(op, st, l.root)`; it never asks whether the place stored into can hold a view. The
oracle accepts the same call on an owned local (`!w.b.add(w.nl)` in `main`) and rejects it
through any write view, `@` or a `!W` parameter.

**Probes.** `probes/c9_add.rig` (three `!@` methods; compiler accepts, runs clean, prints `5 4`;
oracle DIFF C9 on all three, accepts `main`'s owned-local form). `probes/c9_control.rig`:
`viaparam(w: !W)` with `!w.b.add(w.nl)` is also a DIFF; the true self-view shapes
`!@v.push(?@s)` and `!x.v.push(?x.s)` (a `List[?String]` field) are rejected by both
("cannot let this call store a view of `@s` in `@v`").

**What the oracle needs.** Drop from C9's stored set the loans the stored-into place's type
cannot carry (`Func.keeps` / `holds_views` of the target: a `String` field carries none).

## Not settled

- The fixes named above are read from the code and the probes, not tried: no oracle change was
  made. The C5 fix in particular is a hypothesis (the concrete `(?String)?` form being
  accepted supports it).
- The earlier C2 form was checked only in a standalone probe, not on Trig 0bac3fa.
- Trig runs the oracle on 5,174 of 9,861 functions (the rest abstain, mostly the `fun`-field
  class); the classification covers only the decided ones.

## Outcome (track 3, steps 1 and 3)

The four fixes landed in the oracle, each with its safe shape as a test the oracle accepts and
its unsafe sibling as one both checkers reject:

- C5: `kinds.zig` gives an optional of a bounded type parameter the kind its bounds give (an
  `E?` of an `E: Copy` copies). Only the kind: what such a value may carry is unchanged, since
  making `S.Item?` carry what `S.Item` carries exposes the open question of a value of
  `S.Item` that may view its base (PLAN track 2, row 29), in six suite functions.
- C6: a callee's `from` and `keeps` are read from the module that declares it (`homeOf`). A
  generic type or function another module declares, `Map` among them, had its clauses looked
  up in the caller's module, found nothing, and was treated as a built-in that carries every
  argument. The same fix makes `test/reject/probes/rev255-m01 main` an oracle rejection (a
  `keeps x` across modules, which the oracle had ignored).
- C1: a statement clears `tail_floor`: only a block's last value moves its own binding.
- C9: `storesInto` counts a store through a write loan only where the lent place can hold a
  view (`Loan.stores_views`), as the flow itself does.
- Step 3: `Map`, `Set`, and the other types of `std/__rig_builtin.rig` are checked as a List
  is, by their methods' signatures (`rigBuiltin`). Deciding them exposed one more oracle
  imprecision, `slot(!v, 1) = slot(!v, 0)`: a `!Int` a call gives, where an `Int` is stored, is
  now read there (`readWanted`).

Measured after the fixes: Trig 0 disagreements (was 7), 5,251 functions decided (was 5,174);
the suite's `tests` set 22,767 decided (was 22,695: 32 more by Map and Set, 40 in the new
tests), `docs` 1,077 (was 1,070, all by Map and Set), `matrix` 71,930 (unchanged). No rejection was lost.
