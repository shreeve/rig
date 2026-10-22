import os, sys
P = sys.argv[1]
PRE = open(os.path.join(os.path.dirname(__file__), "pre.rig")).read()
PUSH = """          for i in 0..100
            !r.v.push(i)"""
def w(name, body):
    open(os.path.join(P, name + ".rig"), "w").write(PRE + body.strip("\n") + "\n")
def uaf(name, decls, params, subject, writer, call):
    w(name, decls + """
sub f(%s)
  match %s
    .a(r0)
      s = ?r0.v[..]
      %s
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
%s
""" % (params, subject, writer, PUSH, call))

H = "struct H\n  w: !E\n"
uaf("b01_branch_part_of_writeparams", H, "h1: !H, h2: !H, c: Bool", "(h1 if c else h2).w", "match !h1.w",
    "  e = mk(1)\n  d = mk(2)\n  h1 = H(w: !e)\n  h2 = H(w: !d)\n  f(!h1, !h2, true)")
uaf("b02_branch_part_of_owned_locals", H, "c: Bool", "(h1 if c else h2).w", "match !h1.w",
    "  f(true)")
# b02 needs locals inside f: rewrite manually
w("b02_branch_part_of_owned_locals", H + """
sub f(e: !E, d: !E, c: Bool)
  h1 = H(w: !e)
  h2 = H(w: !d)
  match (h1 if c else h2).w
    .a(r0)
      s = ?r0.v[..]
      match !h1.w
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  f(!e, !d, true)
""" % PUSH)
G = "struct G\n  w: !E\n"
w("b03_optional_chain_local", G + """
fun f(e: !E) -> Int?
  o: G? = G(w: !e)
  match o?.w
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
  _ = f(!e)
""")
w("b03b_optional_chain_local_write", G + """
fun f(e: !E) -> Int?
  o: G? = G(w: !e)
  match o?.w
    .a(r) => r.n = 5
    .b => pass
  1

sub main()
  e = mk(1)
  _ = f(!e)
  print(e)
""")
w("b04_optional_chain_readview", "struct K\n  o: G?\n" + G + """
fun f(k: ?K) -> Int?
  match k.o?.w
    .a(r) => r.n = 5
    .b => pass
  1

sub main()
  e = mk(1)
  k = K(o: G(w: !e))
  _ = f(?k)
  print(k.o)
""")
uaf("b05_nested_branch", "", "a: !E, b: !E, d: !E, c: Bool, c2: Bool", "(!d if c else (a if c2 else b))", "match !a",
    "  e = mk(1)\n  x = mk(2)\n  y = mk(3)\n  f(!e, !x, !y, false, true)")
uaf("b06_paren_place", "", "a: !E, b: !E, c: Bool", "((a) if c else (b))", "match !a",
    "  e = mk(1)\n  x = mk(2)\n  f(!e, !x, true)")
GG = "struct GG\n  g: G\n" + G
uaf("b07_field_of_field", GG, "h: !GG, k: !GG, c: Bool", "(h.g.w if c else k.g.w)", "match !h.g.w",
    "  e = mk(1)\n  d = mk(2)\n  h = GG(g: G(w: !e))\n  k = GG(g: G(w: !d))\n  f(!h, !k, true)")
w("b08_for_branch_writevecs", """
sub f(a: !Vec[Int], b: !Vec[Int], c: Bool)
  for x in (a if c else b)
    !a.push(x)
    if a.len > 200
      break
  print(a.len)

sub main()
  v: Vec[Int] = Vec()
  !v.push(1)
  u: Vec[Int] = Vec()
  f(!v, !u, true)
""")
w("b08b_for_branch_writevecs_view", """
sub f(a: !Vec[Int], b: !Vec[Int], c: Bool)
  for x in (a if c else b)
    s = ?a[..]
    print(s[0])
  for x in ?(a if c else b)
    !a.push(x)
    if a.len > 200
      break
  print(a.len)

sub main()
  v: Vec[Int] = Vec()
  !v.push(1)
  u: Vec[Int] = Vec()
  f(!v, !u, true)
""")
w("b09_branch_part_writeview_struct", """
struct W
  e: E

sub f(a: !W, b: !W, c: Bool)
  match (a if c else b).e
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
w("b09b_branch_part_writeview_vec_for", """
struct W
  v: Vec[Int]

sub f(a: !W, b: !W, c: Bool)
  for x in (a if c else b).v
    !a.v.push(x)
    if a.v.len > 200
      break
  print(a.v.len)

sub main()
  x = W(v: Vec())
  !x.v.push(1)
  y = W(v: Vec())
  f(!x, !y, true)
""")
w("b10_vec_of_writeviews_index", """
sub f(v: !Vec[!E], c: Bool)
  match (v[0] if c else v[1])
    .a(r) => r.n = 4
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  v: Vec[!E] = Vec()
  !v.push(!e)
  !v.push(!d)
  f(!v, true)
  print(e)
""")
w("b11_as_branch_part_optional", """
struct G2
  o: (!E)?

fun f(a: !G2, b: !G2, c: Bool) -> Int?
  if (a if c else b).o as x
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
  1

sub main()
  e = mk(1)
  d = mk(2)
  x = G2(o: !e)
  y = G2(o: !d)
  _ = f(!x, !y, true)
""")
w("b12_as_optchain_local", G + """
fun f(e: !E) -> Int?
  o: G? = G(w: !e)
  if o?.w as x
    pass
  1

sub main()
  e = mk(1)
  _ = f(!e)
""")
w("b13_match_branch_of_calls_readviews", """
struct H
  w: !E

fun rw(h: ?H) -> ?E
  h.w

sub f(h1: ?H, h2: ?H, c: Bool)
  match (rw(h1) if c else rw(h2))
    .a(r) => print(r.n)
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  h1 = H(w: !e)
  h2 = H(w: !d)
  f(?h1, ?h2, true)
""")
w("b14_coalesce_optional_readview_param", """
fun f(o: ?((!E)?), d: !E) -> Int?
  match o ?? !d
    .a(r) => r.n = 4
    .b => pass
  1

sub main()
  e = mk(1)
  d = mk(2)
  o: (!E)? = !e
  _ = f(?o, !d)
  print(e)
""")
