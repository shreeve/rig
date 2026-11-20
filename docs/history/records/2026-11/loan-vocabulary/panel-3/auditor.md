# Panel 3: the accuracy auditor

Compiler: `~/Data/Code/rig/bin/rig` at 41d245dff (#1191), the same commit
as the loan-vocab worktree. 80 programs, each run with `rig run`; every
program and its output is in the appendix, named by file. References like
(d05) point there.

## Verdict

The model is accurate in substance, and **read view / write view** never
said anything false in any program: a read view never let its holder
change anything (a `?*Cell` cannot `set`), and a write view always could.
**Off-limits** is true wherever the model applies it. **Read-only** is the
one false word, and only where the brief already suspected: under the
Cell exception, and under a read view of a handle whose value holds a
Cell, the owner's value still changes (d05, d07, f01, f02, k02). What is
true there is that the *handle* is read-only: it may not be assigned,
moved, dropped or repointed.

**The possible bug does not reproduce.** `w: !Cell[Int] = !c` leaves `c`
read-only, exactly as CORE §4 says: `c.get()` is accepted while `w` lives
(e01, e02, d03), a second `!c` too (d04, d05), and `c = *Cell(2)` is
rejected (e03). What does make `c` off-limits is `w = !c` with no type
(e04): with no view expected, `!c` lends by §4's first row, `!*Cell[Int]`,
the handle itself, which can repoint `c` (e08 prints 7), and §4 says such
a lend "puts a write loan on `h`". So it is no bug against §4; Panel 2's
snippet most likely lost its annotation. It is a trap worth one sentence:
whether `!c` is the exception depends on the view the context expects.

## Line by line

1. **True** (a01-a06), with two notes. A read view may be unwritten:
   in `sum(v, grow(!v))` the bare `v` is one (h01). And `?s` of a
   `?String` binding is the same view copied, not a view of `s`, so `s`
   may be reassigned (j01; CORE §4 says "a read view of a read view is
   that read view"); a `[]Int` binding is lent normally (j02).
2. **True**, given what "in use" means. A method's write self starts at
   the call: `!v.push(v.len)` is accepted (b04) but `grow(!v, v.len)` is
   rejected (b05), as CORE §6 says. A task that holds self keeps the owner
   off-limits until it is joined (i03, i04).
3. **True as listed** (d01, d02, d04, f01, f03, f04, f06, m01, m02), but it
   must be stated about the value the view sees, not the name:
   - a write view of the *handle* (`!*Cell[Int]`) is ordinary: off-limits
     (d09, d10, e04, e09, i01);
   - an object holding a *handle* to a Cell is not covered (k01); "holds
     a Cell" means by value, behind `*`;
   - an erased `!{A}` parameter, or a `!T` of a type parameter, is not
     seen as covered even when the value is a `*Hits` (k03, k04).
4. **False for the exception's values, true otherwise.** For a List or
   an Int every verb holds (a02-a06). For a Cell or a value holding one,
   "may not be changed" is false: `!c.set(5)` with `r = ?c` live (d07),
   `!c.set(3)` with a write view of the Cell live (d05), `!h.bump()` and
   `!h.n.set(3)` under `r = ?h` (f01, f02), `!b.c.add(...)` under `r = ?b`
   when `b` holds a `*Cell` field (k02). Assigning, moving, dropping and
   repointing stay forbidden (e03, d10).
5. **True** (b01-b03, b06, b08, i02, h06): even copying an Int is refused.
6. **True for fields, two corrections needed.**
   - Elements are not places: a view of `a[0]` limits all of `a`
     (c08, c09).
   - "Limits `p`" means `p` as a whole. Under a read view of `p.a`, `p`
     may be read whole (c03) and `p.b` changed (c01), only reassigning `p`
     is refused (c02). Under a write view of `p.a`, `p.b` may be read and
     written (c04), `p` whole may not be read (c05). So "p is read-only /
     off-limits" is false as a sentence about `p`; "p.a is, and so is p
     as a whole" is true.
   - A call's result limits what its signature names: `pick(!t) -> !Int`
     limits all of `t` (h03) unless it says `from @value`.
7. **True when the viewed type does not copy** (g05, g07; the note reads
   "kept lent to read by a view that only reads it"). When it copies, as
   in the brief's own `?Int`-returning `head`, `r` is an `Int`, not a view,
   and `v` is free at once (g02, g06). A write-view result keeps `v`
   off-limits (g04).
8. **Workable with two cautions.** Keep naming both places
   ("cannot reassign `p` while `p.a` is read-only"; c02, c05). And keep
   the exact verb: "cannot change `c` while it is read-only" for
   `c = *Cell(2)` reads false beside an accepted `!c.set(3)`; "cannot
   reassign" is true. The new words would fix today's worst text, where
   the note says "`c` lent to read here" under a `!c` (e03, i01) and the
   error says "cannot lend `c` to read" for a `!c` (d10). The held read
   (h01) and the write self (l01, "read until the call starts") still need
   their notes.

## Do the words feel natural

Read view, write view and off-limits: yes, and true. Read-only: natural,
but false for exactly the values the exception names. **The one change:**
state the exception about the handle, which is what is true: "A write view
of a shared value that changes only through its own calls (a Cell, ...)
leaves the handle read-only: the handle stays put, and what it shares
changes only through those calls, by anyone holding a write view." This
matches sentence 9 ("what you share changes only by a marked call") and
keeps all four words.

Is "loan" needed by users? Not by any program here. Every conflict is
statable as "a view of x, written or not, wherever it went, is in use";
the head case is a read view of `v`, and the binding case (h04, h07)
is reported path for path. Keep "loan" for the compiler and CORE.

## The owner's question

Yes. A read view has no qualifier: the owner is always read-only. A
write view has exactly one: the owner is off-limits, unless the view sees
a shared value that changes only through its own calls, when the owner is
only read-only. Nobody writes the qualifier; the type of the value
decides it, and with a `*Cell` the type of the view does too (`!Cell[Int]`
or `!*Cell[Int]`). The two timing facts (a write self starts at the call;
a call that returns only read views leaves the owner read-only) are not
kinds.

## The picture

A two-by-two grid. Rows: read view `?x`, write view `!x`. Columns: an
ordinary value, a shared value that changes by its own calls. Cells:
read-only, read-only; off-limits, read-only (the handle). Beside it, one
timeline for `x`: a bar from each lend to that view's last use, coloured
by the grid, with "free" before and after.

## Appendix: every program and its output

```text
=== a01_ro_read_copy.rig
sub main()
  v: List[Int] = List()
  !v.push(1)
  r = ?v
  n = v.len
  r2 = ?v
  w = +v
  print(n, r2.len, w.len, v[0], r.len)
--- result
  1 1 1 1 1
=== a02_ro_change.rig
sub main()
  v: List[Int] = List()
  r = ?v
  !v.push(1)
  print(r.len)
--- result
  a02_ro_change.rig:4:3: error: cannot lend `v` to write while a read loan is live
    !v.push(1)
    ^
  a02_ro_change.rig:3:8:   note: `v` lent to read here
    r = ?v
         ^
=== a03_ro_assign.rig
sub main()
  v: List[Int] = List()
  r = ?v
  v = List()
  print(r.len)
--- result
  a03_ro_assign.rig:4:3: error: cannot reassign `v` while it is lent
    v = List()
    ^
  a03_ro_assign.rig:3:8:   note: `v` lent to read here
    r = ?v
         ^
=== a04_ro_move.rig
fun take(v: List[Int]) -> Int
  v.len

sub main()
  v: List[Int] = List()
  r = ?v
  print(take(<v))
  print(r.len)
--- result
  a04_ro_move.rig:7:15: error: cannot move `v` while a read loan is live
    print(take(<v))
                ^
  a04_ro_move.rig:6:8:   note: `v` lent to read here
    r = ?v
         ^
=== a05_ro_drop.rig
sub main()
  v: List[Int] = List()
  r = ?v
  <v
  print(r.len)
--- result
  a05_ro_drop.rig:4:4: error: cannot drop `v` while it is lent
    <v
     ^
  a05_ro_drop.rig:3:8:   note: `v` lent to read here
    r = ?v
         ^
=== a06_ro_int_assign.rig
sub main()
  n = 1
  r = ?n
  n = 2
  print(r)
--- result
  a06_ro_int_assign.rig:4:3: error: cannot reassign `n` while it is lent
    n = 2
    ^
  a06_ro_int_assign.rig:3:8:   note: `n` lent to read here
    r = ?n
         ^
=== b01_ol_bind_int.rig
sub main()
  n = 1
  w: !Int = !n
  print(n)
  w += 1
--- result
  b01_ol_bind_int.rig:4:9: error: use of `n` while a write loan is live
    print(n)
          ^
  b01_ol_bind_int.rig:3:14:   note: `n` lent to write here
    w: !Int = !n
               ^
=== b02_ol_copy_int.rig
sub main()
  n = 1
  w: !Int = !n
  m = n
  w += 1
  print(m)
--- result
  b02_ol_copy_int.rig:4:7: error: use of `n` while a write loan is live
    m = n
        ^
  b02_ol_copy_int.rig:3:14:   note: `n` lent to write here
    w: !Int = !n
               ^
=== b03_ol_arg_copy.rig
sub add(a: !Int, b: Int)
  a += b

sub main()
  n = 1
  add(!n, n)
  print(n)
--- result
  b03_ol_arg_copy.rig:6:11: error: use of `n` while a write loan is live
    add(!n, n)
            ^
  b03_ol_arg_copy.rig:6:8:   note: `n` lent to write here
    add(!n, n)
         ^
=== b04_ol_self_arg.rig
sub main()
  v: List[Int] = List()
  !v.push(1)
  !v.push(v.len)
  !v.push(v[0] + v[1])
  print(v)
--- result
  [1, 1, 2]
=== b05_ol_arg_len.rig
sub grow(v: !List[Int], k: Int)
  !v.push(k)

sub main()
  v: List[Int] = List()
  grow(!v, v.len)
  print(v)
--- result
  b05_ol_arg_len.rig:6:12: error: use of `v` while a write loan is live
    grow(!v, v.len)
             ^
  b05_ol_arg_len.rig:6:9:   note: `v` lent to write here
    grow(!v, v.len)
          ^
=== b06_ol_list_read.rig
sub main()
  v: List[Int] = List()
  w: !List[Int] = !v
  print(v.len)
  !w.push(1)
--- result
  b06_ol_list_read.rig:4:9: error: use of `v` while a write loan is live
    print(v.len)
          ^
  b06_ol_list_read.rig:3:20:   note: `v` lent to write here
    w: !List[Int] = !v
                     ^
=== b07_ol_list_ok_after.rig
sub main()
  v: List[Int] = List()
  w: !List[Int] = !v
  !w.push(1)
  print(v.len)
--- result
  1
=== b08_ol_lend_read.rig
sub main()
  v: List[Int] = List()
  w: !List[Int] = !v
  r = ?v
  !w.push(1)
  print(r.len)
--- result
  b08_ol_lend_read.rig:4:8: error: cannot lend `v` to read while a write loan is live
    r = ?v
         ^
  b08_ol_lend_read.rig:3:20:   note: `v` lent to write here
    w: !List[Int] = !v
                     ^
=== c01_place_ro_sibling_write.rig
obj In
  x: Int
  y: Int

obj P
  a: In
  b: Int

sub main()
  p = P(a: In(x: 1, y: 2), b: 3)
  r = ?p.a
  p.b = 4
  print(r.x, p.b)
--- result
  1 4
=== c02_place_ro_parent_write.rig
obj In
  x: Int
  y: Int

obj P
  a: In
  b: Int

sub main()
  p = P(a: In(x: 1, y: 2), b: 3)
  r = ?p.a
  p = P(a: In(x: 0, y: 0), b: 0)
  print(r.x)
--- result
  c02_place_ro_parent_write.rig:12:3: error: cannot reassign `p` while `p.a` is lent
    p = P(a: In(x: 0, y: 0), b: 0)
    ^
  c02_place_ro_parent_write.rig:11:8:   note: `p.a` lent to read here
    r = ?p.a
         ^
=== c03_place_ro_parent_read.rig
obj In
  x: Int
  y: Int

obj P
  a: In
  b: Int

sub main()
  p = P(a: In(x: 1, y: 2), b: 3)
  r = ?p.a
  q = p
  print(r.x, q.b)
--- result
  1 3
=== c04_place_ol_sibling_read.rig
obj In
  x: Int
  y: Int

obj P
  a: In
  b: Int

sub main()
  p = P(a: In(x: 1, y: 2), b: 3)
  w: !In = !p.a
  print(p.b)
  p.b = 9
  w.x = 5
  print(p.a.x, p.b)
--- result
  3
  5 9
=== c05_place_ol_parent_read.rig
obj In
  x: Int
  y: Int

obj P
  a: In
  b: Int

sub main()
  p = P(a: In(x: 1, y: 2), b: 3)
  w: !In = !p.a
  print(p)
  w.x = 5
--- result
  c05_place_ol_parent_read.rig:12:9: error: use of `p` while a write loan on `p.a` is live
    print(p)
          ^
  c05_place_ol_parent_read.rig:11:13:   note: `p.a` lent to write here
    w: !In = !p.a
              ^
=== c06_place_ol_child_read.rig
obj In
  x: Int
  y: Int

obj P
  a: In
  b: Int

sub main()
  p = P(a: In(x: 1, y: 2), b: 3)
  w: !In = !p.a
  print(p.a.y)
  w.x = 5
--- result
  c06_place_ol_child_read.rig:12:9: error: use of `p.a.y` while a write loan on `p.a` is live
    print(p.a.y)
          ^
  c06_place_ol_child_read.rig:11:13:   note: `p.a` lent to write here
    w: !In = !p.a
              ^
=== c07_place_ro_child_of_view_write.rig
obj In
  x: Int
  y: Int

obj P
  a: In
  b: Int

sub main()
  p = P(a: In(x: 1, y: 2), b: 3)
  r = ?p.a.x
  p.a.y = 7
  print(r, p.a.y)
--- result
  1 7
=== c08_elem_ro_other_elem.rig
sub main()
  a = [1, 2, 3]
  r = ?a[0]
  a[1] = 5
  print(r, a)
--- result
  c08_elem_ro_other_elem.rig:4:3: error: cannot assign to `a[1]` while `a` is lent
    a[1] = 5
    ^
  c08_elem_ro_other_elem.rig:3:8:   note: `a` lent to read here
    r = ?a[0]
         ^
=== c09_elem_list_other_elem.rig
sub main()
  v: List[Int] = List()
  !v.push(1)
  !v.push(2)
  r = ?v[0]
  v[1] = 5
  print(r, v)
--- result
  c09_elem_list_other_elem.rig:6:3: error: cannot assign to `v[1]` while `v` is lent
    v[1] = 5
    ^
  c09_elem_list_other_elem.rig:5:8:   note: `v` lent to read here
    r = ?v[0]
         ^
=== d01_cell_nest.rig
sub main()
  c = *Cell(1)
  !c.add((!c).swap(4))
  print(c.get())
--- result
  5
=== d02_cell_two.rig
sub two(a: !Cell[Int], b: !Cell[Int])
  !a.set(5)
  !b.add(1)

sub main()
  c = *Cell(1)
  two(!c, !c)
  print(c.get())
--- result
  6
=== d03_cell_bind_w.rig
sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  print(c.get())
  !w.set(5)
--- result
  1
=== d04_cell_bind_w_two.rig
sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  u: !Cell[Int] = !c
  !w.set(5)
  !u.add(1)
  print(c.get())
--- result
  6
=== d05_cell_bind_w_then_lend.rig
sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  !c.set(3)
  !w.add(1)
  print(c.get())
--- result
  4
=== d06_cell_bind_w_read_lend.rig
sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  r = ?c
  !w.add(1)
  print(r.get())
--- result
  2
=== d07_cell_ro_still_changes.rig
sub main()
  c = *Cell(1)
  r = ?c
  !c.set(5)
  print(r.get())
--- result
  5
=== d08_cell_ro_reassign.rig
sub main()
  c = *Cell(1)
  !c.add((!c).swap(4))
  w = 0
  print(c.get(), w)
--- result
  5 0
=== d09_cell_handle_lend.rig
sub repoint(h: !*Cell[Int])
  h = *Cell(9)

sub main()
  c = *Cell(1)
  repoint(!c)
  print(c.get())
--- result
  9
=== d10_cell_handle_lend_conflict.rig
sub both(h: !*Cell[Int], k: !Cell[Int])
  !k.set(2)
  h = *Cell(9)

sub main()
  c = *Cell(1)
  both(!c, !c)
  print(c.get())
--- result
  d10_cell_handle_lend_conflict.rig:7:13: error: cannot lend `c` to read while a write loan is live
    both(!c, !c)
              ^
  d10_cell_handle_lend_conflict.rig:7:9:   note: `c` lent to write here
    both(!c, !c)
          ^
=== d11_cell_param_bind.rig
sub f(c: !Cell[Int])
  w: !Cell[Int] = !c
  print(c.get())
  !w.set(5)

sub main()
  c = *Cell(1)
  f(!c)
  print(c.get())
--- result
  1
  5
=== d12_cell_viewed_across_reassign_via_w.rig
sub main()
  c = *Cell(1)
  r = ?c
  w: !Cell[Int] = !c
  !w.set(4)
  print(r.get())
--- result
  4
=== e01_bug_exact.rig
sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  print(c.get())
  print(w.get())
--- result
  1
  1
=== e02_bug_set_then_get.rig
sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  print(c.get())
  !w.set(5)
  print(w.get())
--- result
  1
  5
=== e03_bug_reassign.rig
sub main()
  c = *Cell(1)
  w: !Cell[Int] = !c
  c = *Cell(2)
  !w.set(5)
--- result
  e03_bug_reassign.rig:4:3: error: cannot reassign `c` while it is lent
    c = *Cell(2)
    ^
  e03_bug_reassign.rig:3:20:   note: `c` lent to read here
    w: !Cell[Int] = !c
                     ^
=== e04_bug_infer.rig
sub main()
  c = *Cell(1)
  w = !c
  print(c.get())
  !w.set(5)
--- result
  e04_bug_infer.rig:4:9: error: use of `c` while a write loan is live
    print(c.get())
          ^
  e04_bug_infer.rig:3:8:   note: `c` lent to write here
    w = !c
         ^
=== e05_bug_get_only_arg.rig
fun peek(w: !Cell[Int], k: Int) -> Int
  w.get() + k

sub main()
  c = *Cell(1)
  print(peek(!c, c.get()))
--- result
  2
=== e06_bug_toplevel.rig
c = *Cell(1)
w: !Cell[Int] = !c
print(c.get())
print(w.get())
--- result
  e06_bug_toplevel.rig:1:5: error: a module-level constant needs a value known at compile time: a literal, `.variant`, a constant, or operators, ternaries, and arrays over them, or a vector of them (`Simd[T, n](array)`, `Simd[T, n].splat(x)`)
  c = *Cell(1)
      ^~~~~~~~
  e06_bug_toplevel.rig:2:18: error: cannot lend constant `c` to write: it lives for the whole program and never changes; bind its value to a name first
  w: !Cell[Int] = !c
                   ^
  e06_bug_toplevel.rig:2:17: error: a module-level constant needs a value known at compile time: a literal, `.variant`, a constant, or operators, ternaries, and arrays over them, or a vector of them (`Simd[T, n](array)`, `Simd[T, n].splat(x)`)
  w: !Cell[Int] = !c
                  ^~
  e06_bug_toplevel.rig:3:1: error: only declarations and bindings are allowed at module level; move this statement into a function
  print(c.get())
  ^~~~~~~~~~~~~~
  e06_bug_toplevel.rig:4:1: error: only declarations and bindings are allowed at module level; move this statement into a function
  print(w.get())
  ^~~~~~~~~~~~~~
=== e07_bug_toplevel_infer.rig
c = *Cell(1)
w = !c
print(c.get())
print(w.get())
--- result
  e07_bug_toplevel_infer.rig:1:5: error: a module-level constant needs a value known at compile time: a literal, `.variant`, a constant, or operators, ternaries, and arrays over them, or a vector of them (`Simd[T, n](array)`, `Simd[T, n].splat(x)`)
  c = *Cell(1)
      ^~~~~~~~
  e07_bug_toplevel_infer.rig:2:6: error: cannot lend constant `c` to write: it lives for the whole program and never changes; bind its value to a name first
  w = !c
       ^
  e07_bug_toplevel_infer.rig:3:1: error: only declarations and bindings are allowed at module level; move this statement into a function
  print(c.get())
  ^~~~~~~~~~~~~~
  e07_bug_toplevel_infer.rig:4:1: error: only declarations and bindings are allowed at module level; move this statement into a function
  print(w.get())
  ^~~~~~~~~~~~~~
=== e08_infer_is_handle.rig
sub main()
  c = *Cell(1)
  w = !c
  w = *Cell(7)
  print(c.get())
--- result
  7
=== e09_annot_handle.rig
sub main()
  c = *Cell(1)
  w: !*Cell[Int] = !c
  print(c.get())
  w = *Cell(7)
--- result
  e09_annot_handle.rig:4:9: error: use of `c` while a write loan is live
    print(c.get())
          ^
  e09_annot_handle.rig:3:21:   note: `c` lent to write here
    w: !*Cell[Int] = !c
                      ^
=== f01_hits_two.rig
obj Hits
  n: Cell[Int]

  sub bump(!@)
    !@n.add(1)

sub hit(h: !Hits)
  !h.bump()

sub two(a: !Hits, b: !Hits)
  !a.bump()
  !b.bump()

sub main()
  h = *Hits(n: Cell(0))
  r = ?h
  hit(!h)
  two(!h, !h)
  !h.bump()
  print(r.n.get())
--- result
  4
=== f02_hits_field_plain.rig
obj Hits
  n: Cell[Int]
  k: Int

sub main()
  h = *Hits(n: Cell(0), k: 1)
  r = ?h
  !h.n.set(3)
  print(r.n.get(), r.k)
--- result
  3 1
=== f03_shared_map.rig
use std.shared

sub main()
  m = shared.Map[Int, Int].new()
  a = ?m.get(1)
  _ = !m.put_new(1, 10)
  v = !m.ensure(2, 20)
  _ = !m.put_new(3, 30)
  print(v, m.len(), a ?? -1)
--- result
  20 3 -1
=== f04_signal.rig
sub main()
  s: *Signal[Int] = *Signal(0)
  r = ?s
  !s.set(7)
  print(r.get())
--- result
  7
=== f05_api_two_owned.rig
api Bump
  sub bump(!@)

obj K: Bump
  n: Int

  sub bump(!@)
    @n += 1

sub two(a: !{Bump}, b: !{Bump})
  !a.bump()
  !b.bump()

sub main()
  k = K(n: 0)
  two(!k, !k)
  print(k.n)
--- result
  f05_api_two_owned.rig:16:12: error: cannot lend `k` to write while a write loan is live
    two(!k, !k)
             ^
  f05_api_two_owned.rig:16:8:   note: `k` lent to write here
    two(!k, !k)
         ^
=== f06_api_hits.rig
api Bump
  sub bump(!@)

obj Hits: Bump
  n: Cell[Int]

  sub bump(!@)
    !@n.add(1)

sub two(a: !{Bump}, b: !{Bump})
  !a.bump()
  !b.bump()

sub main()
  h = *Hits(n: Cell(0))
  two(!h, !h)
  print(h.n.get())
--- result
  2
=== f07_param_hits.rig
obj Hits
  n: Cell[Int]

  sub bump(!@)
    !@n.add(1)

sub two(a: !Hits, b: !Hits)
  !a.bump()
  !b.bump()

sub inner(h: !Hits)
  r = ?h
  two(!h, !h)
  print(r.n.get())

sub main()
  h = *Hits(n: Cell(0))
  inner(!h)
--- result
  2
=== g01_head_read_after.rig
fun head(v: !List[Int]) -> ?Int
  !v.push(0)
  ?v[0]

sub main()
  v: List[Int] = List()
  r = head(!v)
  print(v.len, r)
--- result
  1 0
=== g02_head_write_after.rig
fun head(v: !List[Int]) -> ?Int
  !v.push(0)
  ?v[0]

sub main()
  v: List[Int] = List()
  r = head(!v)
  !v.push(1)
  print(r)
--- result
  0
=== g03_head_readlend_after.rig
fun head(v: !List[Int]) -> ?Int
  !v.push(0)
  ?v[0]

sub main()
  v: List[Int] = List()
  r = head(!v)
  s = ?v
  print(r, s.len)
--- result
  0 1
=== g04_head_write_result.rig
fun first(v: !List[Int]) -> !Int
  !v[0]

sub main()
  v: List[Int] = List()
  !v.push(1)
  w = first(!v)
  print(v.len)
  w += 1
--- result
  g04_head_write_result.rig:8:9: error: use of `v` while a write loan is live
    print(v.len)
          ^
  g04_head_write_result.rig:7:14:   note: `v` lent to write here
    w = first(!v)
               ^
=== g05_head_slice.rig
fun head(v: !List[Int]) -> []Int
  !v.push(0)
  ?v[..1]

sub main()
  v: List[Int] = List()
  r = head(!v)
  print(v.len)
  s = ?v
  !v.push(1)
  print(r, s.len)
--- result
  g05_head_slice.rig:10:3: error: cannot lend `v` to write while a read loan is live
    !v.push(1)
    ^
  g05_head_slice.rig:7:13:   note: `v` lent to write here, and kept lent to read by a view that only reads it
    r = head(!v)
              ^
=== g06_head_int_is_copy.rig
fun head(v: !List[Int]) -> ?Int
  !v.push(0)
  ?v[0]

sub main()
  v: List[Int] = List()
  r = head(!v)
  r += 5
  print(r, v)
--- result
  5 [0]
=== g07_head_slice_ok.rig
fun head(v: !List[Int]) -> []Int
  !v.push(0)
  ?v[..1]

sub main()
  v: List[Int] = List()
  r = head(!v)
  s = ?v
  print(v.len, r, s.len)
--- result
  1 [0] 1
=== h01_held_read.rig
fun grow(v: !List[Int]) -> Int
  !v.push(1)
  v.len

fun sum(a: ?List[Int], k: Int) -> Int
  a.len + k

sub main()
  v: List[Int] = List()
  print(sum(v, grow(!v)))
--- result
  h01_held_read.rig:10:22: error: cannot lend `v` to write while a read loan is live
    print(sum(v, grow(!v)))
                       ^
  h01_held_read.rig:10:13:   note: `v` lent to read here
    print(sum(v, grow(!v)))
              ^
=== h02_place_hold.rig
fun grow(v: !List[Int]) -> Int
  !v.push(1)
  0

sub main()
  v: List[Int] = List()
  !v.push(5)
  v[grow(!v)] = 3
  print(v)
--- result
  [3, 1]
=== h03_deref.rig
obj Slot
  value: Int

fun pick(s: !Slot) -> !Int
  !s.value

sub main()
  t = Slot(value: 1)
  w = pick(!t)
  print(t.value)
  w += 1
--- result
  h03_deref.rig:10:9: error: use of `t.value` while a write loan on `t` is live
    print(t.value)
          ^
  h03_deref.rig:9:13:   note: `t` lent to write here
    w = pick(!t)
              ^
=== h04_deref_binding.rig
obj Slot
  value: List[Int]

sub fill(s: !Slot)
  w: !List[Int] = !s.value
  print(s.value.len)
  !w.push(1)

sub main()
  t = Slot(value: List())
  fill(!t)
  print(t.value.len)
--- result
  h04_deref_binding.rig:6:9: error: use of `s.value` while a write loan is live
    print(s.value.len)
          ^
  h04_deref_binding.rig:5:20:   note: `s.value` lent to write here
    w: !List[Int] = !s.value
                     ^
=== h05_two_reads_while_ro.rig
sub main()
  v: List[Int] = List()
  r = ?v
  for x in v
    print(x)
  print(r.len, v.len)
--- result
  0 0
=== h06_for_write.rig
sub main()
  v = [1, 2, 3]
  for x in !v
    x += 1
    print(v.len)
  print(v)
--- result
  h06_for_write.rig:5:11: error: use of `v` while a write loan is live
      print(v.len)
            ^
  h06_for_write.rig:3:13:   note: `v` lent to write here
    for x in !v
              ^
=== h07_deref_other_field.rig
obj Slot
  value: List[Int]
  tag: Int

sub fill(s: !Slot)
  w: !List[Int] = !s.value
  print(s.tag)
  !w.push(1)

sub main()
  t = Slot(value: List(), tag: 7)
  fill(!t)
  print(t.value.len)
--- result
  7
  1
=== i01_cell_then_handle.rig
sub both(k: !Cell[Int], h: !*Cell[Int])
  !k.set(2)
  h = *Cell(9)

sub main()
  c = *Cell(1)
  both(!c, !c)
  print(c.get())
--- result
  i01_cell_then_handle.rig:7:13: error: cannot lend `c` to write while a read loan is live
    both(!c, !c)
              ^
  i01_cell_then_handle.rig:7:9:   note: `c` lent to read here
    both(!c, !c)
          ^
=== i02_ol_assign.rig
sub main()
  n = 1
  w: !Int = !n
  n = 5
  w += 1
--- result
  i02_ol_assign.rig:4:3: error: cannot reassign `n` while it is lent
    n = 5
    ^
  i02_ol_assign.rig:3:14:   note: `n` lent to write here
    w: !Int = !n
               ^
=== i03_task_self.rig
obj Acc
  n: Int

  fun work(!@) -> Int
    @n += 1
    @n

sub main()
  a = Acc(n: 0)
  t = (!a).work()&
  print(a.n)
  print(>t)
--- result
  i03_task_self.rig:11:9: error: use of `a.n` while a write loan on `a` is live
    print(a.n)
          ^
  i03_task_self.rig:10:9:   note: `a` lent to write here
    t = (!a).work()&
          ^
=== i04_task_self_after.rig
obj Acc
  n: Int

  fun work(!@) -> Int
    @n += 1
    @n

sub main()
  a = Acc(n: 0)
  t = (!a).work()&
  print(>t)
  print(a.n)
--- result
  1
  1
=== j01_view_of_view.rig
sub main()
  s: ?String = "abc"
  r = ?s
  s = "def"
  print(r, s)
--- result
  abc def
=== j02_view_of_slice.rig
sub main()
  a = [1, 2, 3]
  b = [4, 5]
  x: []Int = ?a[..]
  r = ?x
  x = ?b[..]
  print(r, x)
--- result
  j02_view_of_slice.rig:6:3: error: cannot reassign `x` while it is lent
    x = ?b[..]
    ^
  j02_view_of_slice.rig:5:8:   note: `x` lent to read here
    r = ?x
         ^
=== j03_cursor_from_field.rig
obj Item
  n: Int

obj Cursor
  items: ?List[Item]
  i: Int

  fun next(!@) -> ?Item
    @i += 1
    ?@items[@i - 1]

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  !v.push(Item(n: 2))
  c = Cursor(items: ?v, i: 0)
  a = !c.next()
  c = Cursor(items: ?v, i: 1)
  print(a.n, c.i)
--- result
  1 1
=== k01_box_holds_handle.rig
obj Box
  c: *Cell[Int]

sub two(a: !Box, b: !Box)
  !a.c.set(1)
  !b.c.add(1)

sub main()
  b = Box(c: *Cell(0))
  two(!b, !b)
  print(b.c.get())
--- result
  k01_box_holds_handle.rig:10:12: error: cannot lend `b` to write while a write loan is live
    two(!b, !b)
             ^
  k01_box_holds_handle.rig:10:8:   note: `b` lent to write here
    two(!b, !b)
         ^
=== k02_box_field_lend.rig
obj Box
  c: *Cell[Int]
  k: Int

sub main()
  b = Box(c: *Cell(0), k: 1)
  r = ?b
  !b.c.add((!b.c).swap(5))
  print(r.c.get(), r.k)
--- result
  5 1
=== k03_erased_param.rig
api Bump
  sub bump(!@)

obj Hits: Bump
  n: Cell[Int]

  sub bump(!@)
    !@n.add(1)

sub two(a: !{Bump}, b: !{Bump})
  !a.bump()
  !b.bump()

sub again(a: !{Bump})
  two(!a, !a)

sub main()
  h = *Hits(n: Cell(0))
  again(!h)
  print(h.n.get())
--- result
  k03_erased_param.rig:15:12: error: cannot lend `a` to write while a write loan is live
    two(!a, !a)
             ^
  k03_erased_param.rig:15:8:   note: `a` lent to write here
    two(!a, !a)
         ^
=== k04_generic_param.rig
obj Hits
  n: Cell[Int]

  sub bump(!@)
    !@n.add(1)

sub two[T](a: !T, b: !T)
  print(1)

sub main()
  h = *Hits(n: Cell(0))
  two(!h, !h)
  print(h.n.get())
--- result
  k04_generic_param.rig:12:12: error: cannot lend `h` to write while a write loan is live
    two(!h, !h)
             ^
  k04_generic_param.rig:12:8:   note: `h` lent to write here
    two(!h, !h)
         ^
=== l01_reserved_write.rig
fun grow(v: !List[Int]) -> Int
  !v.push(1)
  v.len

sub main()
  v: List[Int] = List()
  !v.push(grow(!v))
  print(v)
--- result
  l01_reserved_write.rig:7:17: error: cannot lend `v` to write while a read loan is live
    !v.push(grow(!v))
                  ^
  l01_reserved_write.rig:7:4:   note: `v` lent to write here, as `self`, which is read until the call starts
    !v.push(grow(!v))
     ^
=== l02_reserved_keep_read.rig
fun first(v: ?List[Int]) -> []Int
  ?v[..]

sub main()
  v: List[Int] = List()
  !v.push(first(?v).len)
  print(v)
--- result
  [0]
=== m01_chan.rig
sub main()
  ch = *Chan[Int](2)
  r = ?ch
  !ch.send(1)!
  !ch.send((!ch.recv()! ?? 0) + 5)!
  x = !ch.recv()! ?? -1
  _ = r
  print(x)
--- result
  6
=== m02_actor.rig
obj Counter
  n: Int

  fun add(!@, k: Int) -> Int
    @n += k
    @n

sub main()
  a = *Actor(Counter(n: 0))
  print((!a).add((!a).add(1)))
--- result
  2
```
