import os, sys
P = sys.argv[1]
PRE = open(os.path.join(os.path.dirname(__file__), "pre.rig")).read()
def w(name, body):
    open(os.path.join(P, name + ".rig"), "w").write(PRE + body.strip("\n") + "\n")
PUSH = """          for i in 0..100
            !r.v.push(i)"""
W = "struct W\n  e: E\n"
w("d01_branch_of_lends_part_live", W + """
sub f(a: !W, b: !W, c: Bool)
  match (!a if c else !b).e
    .a(r0)
      s = ?r0.v[..]
      match !a.e
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
  x = W(e: mk(1))
  y = W(e: mk(2))
  f(!x, !y, true)
""" % PUSH)
w("d02_branch_of_lends_part_write", W + """
sub f(a: !W, b: !W, c: Bool)
  match (!a if c else !b).e
    .a(r)
      for i in 0..3
        !r.v.push(i)
    .b => pass

sub main()
  x = W(e: mk(1))
  y = W(e: mk(2))
  f(!x, !y, true)
  print(x.e)
""")
w("d03_optchain_through_writeparam", "struct G\n  w: !E\n\nstruct H\n  o: G?\n" + """
fun f(h: !H) -> Int?
  match h.o?.w
    .a(r0)
      s = ?r0.v[..]
      if !h.o as g
        match !g.w
          .a(r)
            for i in 0..100
              !r.v.push(i)
          .b => pass
      print(s[0])
    .b => pass
  1

sub main()
  e = mk(1)
  h = H(o: G(w: !e))
  _ = f(!h)
""")
w("d04_coalesce_part_owned_locals", "struct G\n  w: !E\n" + """
fun f(e: !E, d: !E) -> Int?
  o: G? = G(w: !e)
  g2 = G(w: !d)
  match (o ?? g2).w
    .a(r0)
      s = ?r0.v[..]
      if !o as g
        match !g.w
          .a(r)
            for i in 0..100
              !r.v.push(i)
          .b => pass
      print(s[0])
    .b => pass
  1

sub main()
  e = mk(1)
  d = mk(2)
  _ = f(!e, !d)
""")
w("d05_as_optchain_part", "struct G\n  o: (!E)?\n" + """
fun f(e: !E) -> Int?
  og: G? = G(o: !e)
  if og?.o as x
    match x
      .a(r0)
        s = ?r0.v[..]
        if !og as g
          if !g.o as y
            match !y
              .a(r)
                for i in 0..100
                  !r.v.push(i)
              .b => pass
        print(s[0])
      .b => pass
  1

sub main()
  e = mk(1)
  _ = f(!e)
""")
w("d06_for_optchain_part_vec", "struct G\n  v: !Vec[Int]\n" + """
fun f(v: !Vec[Int]) -> Int?
  og: G? = G(v: !v)
  n = 0
  for x in og?.v
    if !og as g
      for i in 0..100
        !g.v.push(i)
    n += x
  print(n)
  1

sub main()
  v: Vec[Int] = Vec()
  for i in 0..5
    !v.push(i + 1)
  _ = f(!v)
""")
w("d07_branch_part_index_writeviews", W + """
sub f(a: !Vec[W], b: !Vec[W], c: Bool)
  match (a if c else b)[0].e
    .a(r0)
      s = ?r0.v[..]
      for _ in 0..10
        !a.push(W(e: mk(1)))
      print(s[0])
    .b => pass

sub main()
  x: Vec[W] = Vec()
  !x.push(W(e: mk(3)))
  y: Vec[W] = Vec()
  !y.push(W(e: mk(3)))
  f(!x, !y, true)
""")
w("d08_branch_part_readviews_ok", W + """
sub f(a: ?W, b: ?W, c: Bool)
  match (a if c else b).e
    .a(r) => print(r.n)
    .b => pass

sub main()
  x = W(e: mk(1))
  y = W(e: mk(2))
  f(?x, ?y, true)
""")
w("d09_branch_part_writeviews_readonly", W + """
sub f(a: !W, b: !W, c: Bool)
  match (a if c else b).e
    .a(r) => print(r.n)
    .b => pass

sub main()
  x = W(e: mk(1))
  y = W(e: mk(2))
  f(!x, !y, true)
""")
w("d10_branch_part_writeviews_reassign_param", W + """
sub f(a: !W, b: !W, c: Bool)
  match (a if c else b).e
    .a(r0)
      s = ?r0.v[..]
      a.e = mk(9)
      print(s[0])
    .b => pass

sub main()
  x = W(e: mk(1))
  y = W(e: mk(2))
  f(!x, !y, true)
""")
w("d11_branch_part_local_writeview", W + """
sub main()
  x = W(e: mk(1))
  y = W(e: mk(2))
  a = !x
  b = !y
  c = true
  match (a if c else b).e
    .a(r0)
      s = ?r0.v[..]
      a.e = mk(9)
      print(s[0])
    .b => pass
""")
w("d12_branch_part_capture", W + """
sub main()
  x = W(e: mk(1))
  y = W(e: mk(2))
  c = true
  g = |!x, !y|
    match (x if c else y).e
      .a(r0)
        s = ?r0.v[..]
        x.e = mk(9)
        print(s[0])
      .b => pass
  g()
""")
