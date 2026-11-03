# Idiom and beauty review: too-many-lists (2026-10-29)

Every change below was applied to a copy in a temp dir and run with `rig test`
(and `RIG_SANITIZE=1`), `bin/rig` at main `1b2f4b59d`. "probed" means it passes. All changes
together are in `reviews/tml-idiom-probes/*.rig`: all 25 tests pass, sanitized too; code lines
269 to 266, with tests 501 to 495. Nothing under `compare/` was edited.

The port is already good: the core forms (`<@head`, `(<@head)?.unbox()`, `?? return none`,
`if … as … and *weak as`, `from @`, `?sub(!T)`) are the right ones, and I could not shorten
`peek`, `Iter.next`, or `pop` (see "Tried and rejected").

## first.rig

**1. Header names the Rust it ports** (house style §3, all seven files). probed
```
before: # A stack of Int: Rust's first list, "a bad stack".
after:  # A stack of Int, "a bad stack".
        # Ports too-many-lists/lists/src/first.rs.
```
Why: the house rule; it also brings fourth, silly1, silly2 (105, 103, 103 columns) under 100.

## second.rig

**2. The `each_mut` comment says what it does, not how Rust differs.** probed
```
before: # Rust's `iter_mut`: a write cursor cannot yet advance in a loop, so the walk recurses.
after:  # Calls `f` on each element, front to back, one stack frame per node.
```
Why: house style puts Rust comparisons in the README and bans "yet" (timeless prose). The
README already says why it recurses (G2).

**3. Restore the Rust's `peek_mut` check in test "peek".** probed
```
before:                          after:
  if (!list).peek_mut() as value    if (!list).peek_mut() as value
    value = 42                        return false if value != 3
                                      value = 42
```
Why: Rust asserts `peek_mut() == Some(&mut 3)`; the port dropped it. One line restores it.

**4. Add a million-node drop test for the generic stack, with owned elements.** probed
```rig fragment
test "a long list of owned elements drops without recursion"
  list = Stack[String]()
  for _ in 0..1000000
    !list.push(String("x"))
  true
```
Why: README says "The tests check each list", but second (the generic `^Node[T]?` the README
holds up) has none; first's is `Int` only. Passes sanitized.

## third.rig

**5. Header** as (1). probed. Naming, for the owner if he cares: `Persist` is a verb; candidates
`Shared[T]`, `PStack[T]`, `Persistent[T]` (P6 forces a rename from `List`).

## fourth.rig

**6. `update` drops a level and a rebinding with `?? return`.** probed
```
before:                                    after:
sub update[T](node: !*Node[T], f: ?sub(!T))  sub update[T](node: !*Node[T], f: ?sub(!T))
  if (!node.elem).swap(none) as elem           new elem = (!node.elem).swap(none) ?? return
    new elem = <elem                           f(!elem)
    f(!elem)                                   !node.elem.set(<elem)
    !node.elem.set(<elem)
```
Why: same early-out shape as `pop_front`'s `?? return none`; one line and one indent less, and
the `new elem = <elem` papercut dissolves (an `as` binding can't be written; `as new elem`
does not parse).

**7. Header** as (1), now 2 lines under 100 columns. probed

## fifth.rig

**8. Share fourth's `update` helper instead of inlining it twice.** probed
```
before (update_front and each_mut each):    after:
  if (!node.elem).swap(none) as elem          update(!node, f)
    new elem = <elem
    f(!elem)
    !node.elem.set(<elem)
```
plus the 3-line `sub update[T]` of (6) with fourth's comment. Why: the same four lines appeared
twice; −5 lines, and fourth and fifth now read alike.

**9. Header without the Rust comparison.** probed
```
before: # A queue with a tail handle, safe where Rust's fifth list is `unsafe`: "an ok unsafe queue".
after:  # A queue of shared nodes with a handle on its tail: "an ok unsafe queue".
        # Ports too-many-lists/lists/src/fifth.rs.
```
Why: house style; the README makes the safe/unsafe point.

## silly1.rig

**10. Keep the Rust test's state diagrams as trailing comments.** probed
```
  list = Zipper[Int]()                  # [_]
  !list.push_left(0)                    # [0, _]
  !list.push_right(1)                   # [0, _, 1]
  ...
  while (!list).go_left()               # [_, 0, 2, 3, 4, 1]
    pass
```
Why: they are the only thing that makes `walk_aboot` readable; the port dropped them. Max 88
columns.

**11. One sentinel across files: `?? -1`, not `?? 9` here and `?? 0` elsewhere.** probed
Why: `-1` is never a pushed value; `?? 0` in second/third would pass a wrong `none` if a test
expected 0. (The sentinel only exists because of gap N1 below.)

**12. (Optional) Show what `from @left` buys.** probed (`tml-idiom-probes/silly1-from-field.rig`)
```rig fragment
  l = ?list.peek_left()
  !list.right.push(9)          # accepted: the loan is on `list.left` only
  (l ?? -1) == 1
```
Without `from @left` the same lines are rejected ("`list` lent to read here"). Rust cannot
narrow a method's borrow to one field. Today the port writes `from @left` but nothing shows it
matters; a test (or a README line under "What Rig does better") would.

## silly2.rig

**13. `push` is an associated function, as Rust's `List::push`.** probed
```
before: pub fun push[U](prev: ..., then: once ?fun(?Frame) -> U) -> U    # at the margin
        push(none, *Cell(3), |a| ...)
after:  (inside obj Frame) pub fun push[U](prev: ..., then: ...) -> U
        Frame.push(none, *Cell(3), |a| ...)
```
Why: faithful (Rust calls `List::push(None, 3, ...)`), and the frame's constructor lives with
the frame. SPEC §Methods: "without one it is an associated function".

**14. `pub data`, `pub prev`, as Rust's `pub data: T, pub prev`.** probed. Why: house style
"`pub` exactly where the Rust has `pub`".

**15. Move the "Not generic until … (bug B1)" line to the README** (it is there already).
Why: not timeless; the code says what is.

## All test files

**16. (Optional) A setup triple becomes a loop** in tests that only set up: second peek,
into_iter, iter, iter_mut; fourth peek, into_iter; fifth into_iter, iter, iter_mut. probed
```
before:              after:
  !list.push(1)        for x in [1, 2, 3]
  !list.push(2)          !list.push(x)
  !list.push(3)
```
Why: Rust writes these on one line (`list.push(1); list.push(2); list.push(3);`); Rig has no
`;`, so three lines became the norm. −9 lines. Keep `basics` and `miri_food` step by step.

## README claims

| Claim | Verdict |
|---|---|
| 24 tests pass, sanitized too | true (probed) |
| Line and token counts, 52% / 61%, 501 / 827 | true (sloc.py reproduces every cell) |
| "a few tests are added … (a million nodes drops; owned elements move)" | true (5 added: 19 Rust + 5) |
| "`Iter` holds `?^Node[T]?`, advances with `@at = ?node.next`" | true |
| "`pop` is three lines" | true |
| "Rust writes [a Drop] for every list so that a long list doesn't overflow the stack" | **partly**: six of seven have one; first, second, silly1 (and third) for recursion, fourth to break its `Rc` cycle, fifth to free raw nodes. Suggest: "to avoid recursion (first, second, third, silly1), break a cycle (fourth), or free raw nodes (fifth)". |
| "Rig drops a chain of a million … The tests check each list." | **partly**: second and silly1 have no such test (change 4 fixes second; silly1 is the same `^Node` stack). |
| "fifth … same algorithm and the same speed" | **partly**: push and pop are the same; the walks (`values`, `each_mut`) swap each link out and clone it back (G15), which Rust's pointer walk does not. Say "push and pop are the same algorithm". |
| "`each_mut` … would overflow the stack at about a million nodes" | true: 100,000 nodes pass, 1,000,000 give "stack overflow" (debug test build, probed). |
| "a statement's loans last to its end, so `a.peek() != none or (!a).peek_mut() != none` is two lines" | true (probed: "cannot lend `a` to write while a read loan is live") |
| "a multi-line closure ends with `)` on a line of its own" | true (probed; the error names the column) |
| "`(!x)` … 119 times" | 119 **lines**; 173 occurrences of `(!`, 115 of them `(!x).m(` calls. Say "on 119 lines". |
| Renames | `values` (fifth's `iter`, a copy walk) and `update_front`/`update_back` (Rust's `peek_*_mut`) are not in a mapping table; `each_mut` and `next_of` are explained. Add `values`. |
| Speed and memory table | not checked (not this review's remit). |
| Prose lines 3, 16–22 run 101–156 columns | style only; table rows can't wrap. |

## New gap

**N1. An optional view does not compare with a value.** (Also seen by the reader expert, §2.4;
not in the routed list.) `?Int == Int` and `Int? == Int` are both accepted, and SPEC says "a
value compares with an optional as its value", but `(?Int)? == Int` is rejected:
```rig
fun first(xs: ?List[Int]) -> (?Int)?
  if xs.len > 0
    return ?xs[0]
  none

sub main()
  xs = List[Int]([3])
  print(first(xs) == 3)
```
`error: cannot compare `(?Int)?` with `Int``. Cost here: 13 comparisons in five tests write `(x.peek() ?? 0) == 3`
with a sentinel where Rust writes `Some(&3)`. Probe: `tml-idiom-probes/gap-optional-view-eq.rig`.

## Tried and rejected (each probed)
- One-line `peek`: `?@head?.elem` is rejected ("cannot lend `@head?` … unwrap it in a
  header"). `node = ?@head ?? return none` and `node = @at ?? return none` (Iter.next) are
  rejected ("a view cannot give up the resource inside it"). The `if … as` form stands.
- `node = <@head?.unbox()` without parens: rejected; `(<@head)?.unbox()` is the form.
- `peek_front` as a method with a `[T: Copy]` bound: SPEC rules out `Copy` as a method-only
  bound (it goes in the type's brackets), so the free function is right.
- Dropping `[T: Owned]` from `Deque`/`Queue`: rejected ("keeps a `T` where no loan is
  tracked"). fifth's `IntoIter[T: Owned]` can drop its bound (probed) to match fourth's
  `IntoIter[T]`; cosmetic.
- third's `tail` as `node = +@first ?? return Persist()`: passes, but bumps a count for
  nothing. Keep the `if … as`.
- `if e as new x`: does not parse ("unexpected name").
