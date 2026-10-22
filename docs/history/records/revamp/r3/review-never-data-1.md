# review-never-data-1: adversarial soundness review of `never-data` (7d224dab vs 0fc49541)

Probes: `.git/revamp/r3/review-never-data-1-probes/` (about 110 programs, `n01..n03` are
two-module dirs). Each was checked by head and base, run under `RIG_SANITIZE=1` in
debug and built and run with `--release`, and given to `bin/rig-oracle`.

**Verdict:** no regression found. Every hole below is also on main, and the PR
neither causes nor widens any of them. F1 is a soundness hole in exactly the
class this PR reopened and then patched (f886f40a), so it should be fixed here
or tracked before the release tag.

## F1 (HIGH, soundness, pre-existing): a branch of Cell-holding places is copied by value, and an alias changes the Cell (use-after-free)

f886f40a restored the write loan on a branch leaf that holds a Cell. That loan
is keyed to the leaf's root, so it catches only `grow(?a.s)`. A Cell lives
behind `*`, so any other handle to the same box, or a closure that captured
one, changes it without touching that root:

```rig
a2 = +a
print(a.s if k else b.s, grow(?a2.s))     # h02
f = |?a| grow(?a.s)
print(a.s if k else b.s, f())             # h03
t = Text(a.s if k else b.s, grow(?a2.s))  # h04
print(a.s.c if k else b.s.c, growc(?a2.s.c))  # h14
```

Emit evaluates `rig.print(.{ if (k) a.value.s else b.value.s, grow(&a2.value.s) })`.
The copy of `S` keeps the old Vec buffer, and `grow` reallocates it. The
sanitizer reports "use of freed memory" (base and head alike), and `--release`
prints garbage (`[0]`).

The oracle abstains on all four: "a branching value holding a Cell, read".

A branch of handles (`(a if k else b).s`, `x if k else y` with `*Cell`) is
fine (h13, h15, h16), because it copies the pointer.

**Class:** a value that holds a Cell by value, made outside `*` by a branching
form. `cellMadeAway` decides only `.call` nodes, so an `if` or `??` (or any
branching form) whose leaves are Cell-holding places makes such a value
unchecked. Rule 1 plus rule 4 imply the fix: reject the branch read by value
(lend each branch: `?a.s if k else ?b.s`), or read it in place by address as
the receiver path already does (e11). Either way, the root-keyed write loan in
`ownership.zig:4116` is then unneeded.

## F2 (MEDIUM, accept-means-correct, pre-existing): a generic closure's `?` capture passed on as `?T` fails in Zig

Fix #4 (e41eaf20) covers storing a `|?x|` capture of a write-view binding. It
does not cover passing that capture on. `f(x)` inside the closure, with `f`
taking `?T`, emits `rig.viewed(T, cap_x)`, a `T`, where a `rig.ReadView(T)`
(`*const P`) goes:

- k05: `sub gen[T](w: !T, f: sub(?T))` with `h = |?w, ?f| f(w)`
- k06: the same with `w: ?T`
- k09: the PR's own `poke` shape, a match binding, passed on
- k10: the same in a `fun`

All four are accepted on base and head, and Zig then fails: "expected type
'*const P', found 'P'". The non-generic case (k08) runs.

## Checked, sound (no finding)

- **Deletions.**
  - **Cells behind `*S`:** reached through `?self`, a nested struct field, a
    weak upgrade, closures and owned closures, a `Vec[*Counter]` (loop, `?v`,
    index, slice), enum payloads matched on the handle, or a `?Cell` view
    returned. All run correct and clean (a06, a09–a17).
  - **Generics:** the Cell is in a generic struct, a nested generic struct
    (`W[T]{i: In[T]}`), or a generic enum payload. All run correct (a11,
    l01–l04).
  - **`T` holding a Cell:** inferred or explicit, it is rejected (i05, i09,
    i12).
  - **Copying or moving a Cell holder out of a handle's field:** a binding, a
    constructor argument, `*(branch)`, or `<h.c` is rejected (a01–a03, a07,
    h06–h12).
  - **Field types:** `[2]Cell`, `Cell?`, aliases of either, and both of those
    across modules are rejected (b01–b06, n01–n02).
  - **Const pointers:** `[]const` slices and `*const` views of
    `*Cell`/`D{c:*Cell}` elements run (l03).
- **Rule 2.** None of these lets a `!T` or `![]T` end up inside a value:
  aliases, inference through a generic fn, a struct or enum constructor,
  array literals, `Vec`/`Box`/`Signal`, closures, owned closures, fallible
  results, or `match`/`if`/`while` values (b04, b05, c01–c16, m01–m07).
  Generic inference rejects `T = ![]Int` (m06, m07).
- **`lendsBranch`.**
  - **Rejected, as rule 4 says:** `?.` on a branch, `e?` receivers, nested
    branches, `??`, `catch` fallbacks, `for !(...)`, and write receivers
    (e03–e12).
  - **Typed binding against a view:** a block `if`, a `match`, or a `while`
    value bound to a view type checks each arm (f01–f07).
  - **Read receivers on a branch (`(a if c else b).first()`):** loans are
    held on every leaf (j01, j02, j05, j06, j09).
  - **Inconsistent, but sound:** a bare `(h.k if c else g.k).hit()` is
    accepted and lent by address (e11), while `?(h if c else g).hit()` is
    rejected.
- **Bug fixes.**
  - **`lendTempArray`:** siblings run leak-free: a branch of temporary
    arrays, `?[..]` of a field of a temporary struct, `for` over a temporary
    array, and nesting (k01).
  - **`derefToHandle`:** siblings run correct: a `Vec[*Q]` and `[2]*Q` with
    reordered named arguments, `(?w1 if c else ?w2).h`, and a bound branch of
    `?h` lends (k02).
  - **`Vec[?P]` loop:** siblings run correct: `?rv`, `?rv[a..b]`, indexed
    loops, a payload `?P`, `(?P)?`, `[2]?P`, and `Vec[?Vec]` (k03).
  - **Generic closure capture:** see F2.
- **Function-result exemption.** A branch of places returned as `!T` or `?T`
  is rejected; a branch of write-view parameters returned runs correct
  (o01–o04).

## Note (LOW, pre-existing)

`print(a.s, grow(?a.s))` (d01, h05) reads the place in place, so it prints the
value after `grow` ran, not the value when the argument was evaluated. Memory
stays safe. Whether that matches SPEC's "left to right … uses them all when it
runs" is worth one sentence in SPEC.
