# Review seam3-2: is `sema.reachedTypeVars` complete? (head 5f9fb4ff)

Built in a detached worktree (removed). About 60 probes, each checked, and each accepted one run under
`RIG_SANITIZE=1` in debug and `--release`. Probes live in the scratchpad (`r/`, `s/`, `mm/`).

## Verdict: no hole found. No program that stores a loan-carrying `T` in a no-loan home was accepted.

Every probe that stores a `T` hidden in a container, in a Cell, a Signal or an owned closure, with
`T = ?Box[..]`, `?Text`, `?Vec` or `String`, is rejected with the "generic body stores a `T`" diagnostic
(or an earlier, equally correct one). The 19 review-1 probes (e*, j*) are all rejected now.

Covered, all rejected:
- generic struct nested 2 and 3 deep (`Out[In[Vec[T]]]`, `C[B[A]]`) in a Cell;
- generic enum payload `E[T]::one(Vec[T])` in a Cell and in an owned closure;
- closure capturing `Vec[T]`, a struct with a `Vec[T]` field, `Vec[T?]`, `Vec[[1]T]`, `Pair[A, B]`;
- `Cell[*fun() -> Int]` over a `Vec[T]` capture, `Vec[*fun]` of such closures, `Fh[T]` with a closure field;
- `Box[*Hold[T]]`, `*Cell[~Hold[T]]`, `Box[T?]`, `Box[Vec[T]]`, `Vec[Vec[T]]`, `Vec[?T]`, `Vec[T]?`, `[1]T`, `Vec[T]!`;
- the same through a type alias of an instance (`type WT = W[?Box[Text]]`);
- generic functions called from generic bodies (`wrap[U]` calling `store[Hold[U]]`, `store[~Hold[U]]`, `Hold.mk`);
- a `Cell[Vec[T]]` passed in as a parameter, with the generic body setting it (`put[T]`), and a generic method of
  `S[T]` setting `self.c`: rejected, or the owner stays lent (`cannot drop b while it is lent`);
- a generic struct and a generic function imported from another module (`hold.keep`, `hold.clos`, `Wrap[hold.Hold[T]]`).

Positive controls run clean in debug and `--release` under the sanitizer: `ok[T]` returning `Vec[T]` with a
box view (prints, owner live), `keep(5)`, `mk(7)`, `Cell[[2]T]` with Int.

## Gaps in the walk, none exploitable
- `reachedTypeVars` does not descend into `.function` / `.callable` types. Not exploitable: a closure's loans
  come from its captures, which `requireNoView` checks, and a `T` in a signature carries no loan.
  A comment saying so would help.
- Not testable: no `Map`/`Set` (unbound), generic type aliases (rejected by the parser).

Several probes are rejected by an unrelated rule first ("copies a T", Cell requires plain data), which
masks the view check; the walk itself was shown by the cases above that name "stores a `T`".
