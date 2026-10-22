import os, sys
P = sys.argv[1]
PRE = open(os.path.join(os.path.dirname(__file__), "pre.rig")).read()
def w(name, body):
    open(os.path.join(P, name + ".rig"), "w").write(PRE + body.strip("\n") + "\n")
W = "struct W\n  v: Vec[Int]\n  e: E\n\nfun mkw(n: Int) -> W\n  v: Vec[Int] = Vec()\n  for i in 0..n\n    !v.push(i + 1)\n  W(v: <v, e: mk(n))\n"
w("c01_lend_branch_part_then_write", W + """
sub f(a: !W, b: !W, c: Bool)
  s = ?(a if c else b).v[..]
  for i in 0..100
    !a.v.push(i)
  print(s[0])

sub main()
  x = mkw(3)
  y = mkw(3)
  f(!x, !y, true)
""")
w("c02_read_branch_part_bind_then_write", W + """
sub f(a: !W, b: !W, c: Bool)
  s = (a if c else b).v[..]
  for i in 0..100
    !a.v.push(i)
  print(s[0])

sub main()
  x = mkw(3)
  y = mkw(3)
  f(!x, !y, true)
""")
w("c03_for_branch_writevecs_grow", """
sub f(a: !Vec[Int], b: !Vec[Int], c: Bool)
  n = 0
  for x in (a if c else b)
    for i in 0..100
      !a.push(i)
    n += x
  print(n)

sub main()
  v: Vec[Int] = Vec()
  for i in 0..5
    !v.push(i + 1)
  u: Vec[Int] = Vec()
  f(!v, !u, true)
""")
w("c04_for_branch_part_vec_grow", W + """
sub f(a: !W, b: !W, c: Bool)
  n = 0
  for x in (a if c else b).v
    for i in 0..100
      !a.v.push(i)
    n += x
  print(n)

sub main()
  x = mkw(5)
  y = mkw(5)
  f(!x, !y, true)
""")
w("c05_while_as_branch_part", """
struct G2
  o: (!E)?

fun f(a: !G2, b: !G2, c: Bool) -> Int?
  k = 0
  while (a if c else b).o as x
    match x
      .a(r0)
        s = ?r0.v[..]
        if !a.o as y
          match !y
            .a(r)
              for i in 0..100
                !r.v.push(i)
            .b => pass
        print(s[0])
      .b => pass
    k += 1
    break if k == 1
  1

sub main()
  e = mk(1)
  d = mk(2)
  x = G2(o: !e)
  y = G2(o: !d)
  _ = f(!x, !y, true)
""")
w("c06_owned_locals_branch_part_reassign", W + """
sub main()
  x = mkw(3)
  y = mkw(3)
  c = true
  match (x if c else y).e
    .a(r0)
      s = ?r0.v[..]
      x = mkw(4)
      print(s[0])
    .b => pass
""")
w("c06b_owned_locals_branch_part_push", W + """
sub main()
  x = mkw(3)
  y = mkw(3)
  c = true
  match (x if c else y).e
    .a(r0)
      s = ?r0.v[..]
      match !x.e
        .a(r)
          for i in 0..100
            !r.v.push(i)
        .b => pass
      print(s[0])
    .b => pass
""")
w("c07_lend_branch_part_owned_then_write", W + """
sub main()
  x = mkw(3)
  y = mkw(3)
  c = true
  s = ?(x if c else y).v[..]
  for i in 0..100
    !x.v.push(i)
  print(s[0])
""")
w("c08_capture_of_branch_part_binding", """
struct G2
  o: (!E)?

fun f(a: !G2, b: !G2, c: Bool) -> Int?
  if (a if c else b).o as x
    g = |?x| print(x)
    if !a.o as y
      match !y
        .a(r) => r.n = 9
        .b => pass
    g()
  1

sub main()
  e = mk(1)
  d = mk(2)
  x = G2(o: !e)
  y = G2(o: !d)
  _ = f(!x, !y, true)
""")
w("c09_match_branch_part_index", W + """
sub f(a: !Vec[W], b: !Vec[W], c: Bool)
  match (a if c else b)[0].e
    .a(r0)
      s = ?r0.v[..]
      for i in 0..10
        !a.push(mkw(1))
      print(s[0])
    .b => pass

sub main()
  x: Vec[W] = Vec()
  !x.push(mkw(3))
  y: Vec[W] = Vec()
  !y.push(mkw(3))
  f(!x, !y, true)
""")
w("c10_optchain_writeview_param", G := "struct G\n  e: E\n" + """
fun f(o: !(G?)) -> Int?
  match o?.e
    .a(r0)
      s = ?r0.v[..]
      o = none
      print(s[0])
    .b => pass
  1

sub main()
  g: G? = G(e: mk(1))
  _ = f(!g)
""")
w("c11_catch_part", "struct G\n  e: E\n" + """
fun tg(g: !G, ok: Bool) -> (!G)!
  return Bad.nope if not ok
  g

sub f(a: !G, b: !G)
  match (tg(!a, false) catch |_| b).e
    .a(r0)
      s = ?r0.v[..]
      b.e = mk(5)
      print(s[0])
    .b => pass

sub main()
  x = G(e: mk(1))
  y = G(e: mk(2))
  f(!x, !y)
""")
