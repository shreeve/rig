# `from @field`: approved

The owner approved the CORE paragraph of [6-final.md](6-final.md) on
2026-10-23, in his words:

> Approve the from @field CORE paragraph as written in 6-final.md; build
> it with its must-pass tests, label the List/Map/Set iterators, lift
> the strict Iter rule, and land after the suite and light gate.

The paragraph is CORE §2, sentence 7, as written there. Its rules 1 to
10 are built as 6-final.md states them, with the must-pass tests of
[5-review.md](5-review.md) (G1, G2) in `test/rig/ownership-origin.rig.test`
("origin self path ...") and `test/rig/std-iter.rig.test`. List has no
iterator object of its own (a `for` walks a List directly), so the List
case is a cursor over a `?List[Int]` with `from @items`.
