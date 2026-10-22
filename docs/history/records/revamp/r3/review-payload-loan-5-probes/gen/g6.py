import os, sys
P = sys.argv[1]
PRE = open(os.path.join(os.path.dirname(__file__), "pre.rig")).read()
def w(name, body):
    open(os.path.join(P, name + ".rig"), "w").write(PRE + body.strip("\n") + "\n")
w("f01_readonly_prop_readview_optional", """
fun f(a: ?((!E)?)) -> Int?
  match a?
    .a(r) => print(r.n)
    .b => pass
  1

sub main()
  e = mk(1)
  o: (!E)? = !e
  _ = f(?o)
""")
w("f02_readonly_errunion_local", """
fun f(e: !E) -> Int!
  r: (!E)! = tryw(!e, true)
  match r!
    .a(x) => print(x.n)
    .b => pass
  1

sub main()
  e = mk(1)
  _ = f(!e) catch |_| 0
""")
w("f03_readonly_branch_of_readlends", """
struct H
  w: !E

sub f(h1: ?H, h2: ?H, c: Bool)
  match (?h1.w if c else ?h2.w)
    .a(r) => print(r.n)
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  h1 = H(w: !e)
  h2 = H(w: !d)
  f(?h1, ?h2, false)
""")
w("f04_readonly_branch_readview_fields", """
struct H
  w: !E

sub f(h1: ?H, h2: ?H, c: Bool)
  match (h1.w if c else h2.w)
    .a(r) => print(r.n)
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  h1 = H(w: !e)
  h2 = H(w: !d)
  f(?h1, ?h2, false)
""")
w("f05_readonly_coalesce_local_opt_readlend", """
sub main()
  e = mk(1)
  d = mk(2)
  o: (!E)? = !e
  match (?o)? 
    .a(r) => print(r.n)
    .b => pass
""")
w("f06_readonly_prop_local_opt", """
fun f(e: !E) -> Int?
  o: (!E)? = !e
  match o?
    .a(r) => print(r.n)
    .b => pass
  1

sub main()
  e = mk(1)
  _ = f(!e)
""")
w("f07_alt_if_as_then_match", """
fun f(e: !E) -> Int?
  o: (!E)? = !e
  if o as x
    match x
      .a(r) => print(r.n)
      .b => pass
  if !o as x
    match !x
      .a(r) => r.n = 9
      .b => pass
  print(o)
  1

sub main()
  e = mk(1)
  _ = f(!e)
""")
w("f08_branch_owned_struct_holding_wv_readonly", """
struct W
  w: !E

sub f(e: !E, d: !E, c: Bool)
  a = W(w: !e)
  b = W(w: !d)
  match (a if c else b).w
    .a(r) => print(r.n)
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  f(!e, !d, true)
""")
w("f09_catch_bare_local_readonly", """
fun f(e: !E, d: !E) -> Int!
  w = !d
  match tryw(!e, false) catch w
    .a(x) => print(x.n)
    .b => pass
  1

sub main()
  e = mk(1)
  d = mk(2)
  _ = f(!e, !d) catch |_| 0
""")
