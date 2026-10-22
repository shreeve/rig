# Review seam3-1: use-after-free hunt in programs PR #104 newly accepts

Head 54a5ed05 vs base ecce07f7, both built in detached worktrees (removed).
95 probes in `review-seam3-1-probes/` (`SUMMARY.txt` has every verdict).
Each one was checked on both compilers. Each one head accepts was run under
`RIG_SANITIZE=1` in debug and `--release`, and through `bin/rig-oracle -v`.

## Verdict: not sound. One class of hole, use-after-free under the sanitizer

### S1: a generic body hides `T` inside `Vec[T]`, `*X[T]` or `~X[T]`, then stores it where no loan is tracked

`checkViews` rejects an instance at a view only when the body records a
`view` requirement (`requireNoView` → `addRequirement` →
`sema.heldTypeVars`). `heldTypeVars` stops at `Vec` (its `contents.held`
bit is false for the element), at `.shared`, and at `.weak`. So when
`Vec[T]`, `*Hold[T]`, `~Hold[T]` or a generic struct whose `T` sits in a
`Vec` field goes into an owned closure or a `Cell`, nothing is recorded,
and the instance at `T = ?X` is accepted with no loan on `X`.

```rig
fun keep[T](x: T) -> *Cell[Vec[T]]
  xs: Vec[T] = Vec()
  !xs.push(x)
  *Cell(<xs)

sub main()
  b = Box(P(x: 7, y: 8))
  c = keep(?b)
  <b
  old = (!c).replace(Vec())
  print(old[0].x)        # rig: use of freed memory (debug); release reads freed memory
```

| Probe | Store | Owner | Result |
|---|---|---|---|
| e10, j02 | `Cell[Vec[T]]` (ctor; `replace` through a param) | Box | sanitizer: use of freed memory |
| e11 | owned closure captures `Vec[T]` | Box | sanitizer: use of freed memory |
| e15 | owned closure captures `*Hold[T]` | Box | sanitizer: use of freed memory |
| e16 | owned closure captures `~Hold[T]` and `*Hold[T]` | Box | sanitizer: use of freed memory |
| j01 | `Stack[T]{items: Vec[T]}` method `*\|<self\|` | Box | sanitizer: use of freed memory |
| e02 | `Cell[Vec[T]]` | Vec | panic: index out of bounds (reads the dropped Vec) |
| e01, e05, e08 | the same, of a dropped Text | Text | prints "" instead of `hello` (reads a dropped stack owner, which the sanitizer cannot see) |
| e12, e13, e14 | the same, `T = String` from `?t[..]` | Text | **base accepts these too**: sanitizer use of freed memory on both |

- **Pre-existing for String.** Base has the bug for `T = String`
  (e12–e14). The PR widens it to every read view: it removed the blanket
  "a generic holds no view" rejection and now relies on `checkViews`,
  which has the same gap.
- **The oracle abstains** (`main ref=unknown`) on every one, so the
  oracle gate cannot catch it.
- **The matrix `holder.` family does not catch it**, because it never
  hides `T` inside a container inside a generic body.

**Fix the class:** compute the type variables for the view requirement
with a walk that reaches every type variable a value may hold:
`Vec`/held arguments, `*`, `~`, Box, optional, array, fallible, and
function types. The same walk is the right one for any "where can a `T`
end up" question. Do not use the inline `held` bits. Check the three
`requireNoView` sites (Cell set/replace target, Cell arguments, owned
captures) against `Vec[T]`, `*X[T]`, `~X[T]`, and a struct with a
`Vec[T]` field. Keep e10/e11/e15/e16/j01/j02/e12 as reject tests.

## What held (sound, rejected as it should be)

- **Boxes, generics and fields:**
  - a box returned from a function, of a parameter (a01–a07);
  - a struct field box (a08, a09), and `Vec[Box[?T]]` (a10, f07);
  - a box moved with `<` (f06), and a conditional holder (i07);
  - an array of boxes (i08);
  - a generic identity chain (i10), and a slice view (i03, i04);
  - a loop element (i01), and a field view (i02).
- **Handles:**
  - a `*Box[?T]` cloned with `+h`, kept past `<h` (b01), returned (b09) or stored in an outer Vec (i09): the loan follows the clone;
  - `*T` cannot be written through, so a handle cannot alias a later push (b02–b05);
  - a handle cannot escape the owner's scope (b06, b10);
  - weak handles and their upgrades keep the loan (b08, b11).
- **Closures:** a stack closure that lends or moves a box keeps the loan
  (c01, c02). An owned closure capturing a holder is rejected (c03, c04).
  A generic body storing `T`, `Box(T)`, `Hold(T)` or `T?` in an owned
  closure is rejected, directly and through another generic (c06,
  d02–d05, d08). `Cell`/`Signal` of a view in a generic body is rejected
  (d09, d10).
- **Generic methods that store `T` in `self`:**
  - the receiver in a Vec, a field, or reached through a `!` param (h01–h03);
  - `T?` set (h05) and take (h06);
  - a two-param pick (h07), and a scope exit (h04).
- **Views given out:** `?h.get()` keeps `v` lent after `<h` (f09); a bare
  `h.get()` is the lasting-lend error (f10); a temporary holder's
  `.get()` (f08).
- **Nested holders and payloads:** `Box[Box[?T]]` (f03) and `((?T)?)?`
  (f05b) hold the loan; an `if as` or `match` payload keeps it (f01, f02).
- **Write views** in Box or generic are still rejected (corpus).

## Emit fixes: correct where reachable

These run clean in debug and `--release` and print the right values:

- `match` through `Box[?Enum]`, `Box[Box[?Enum]]`, and a field `w.b` (g01, g10);
- field and method access through `Box[?P]`, `Box[Box[?P]]`, `Box[?Box[P]]` and `Box[?*P]` (g03);
- Text `len`, slicing, printing and `==` through `Box[?Text]` and `Box[Box[?Text]]` (g02, g08);
- `Vec[Box[?Text]]` (g10), `?Box[?P]` and `Box[?P]` params (g05), and `Box[?T]?` payloads (g06).

Indexing or iterating a `Box[?Vec]` is rejected by type (g04). That is a
gap, not a hole.
