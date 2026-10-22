import os, sys
P = sys.argv[1]
PRE = open(os.path.join(os.path.dirname(__file__), "pre.rig")).read()
def w(name, body):
    open(os.path.join(P, name + ".rig"), "w").write(PRE + body.strip("\n") + "\n")
PUSH = """          for i in 0..100
            !r.v.push(i)"""
w("e01_vec_get_writeview_two_writers", """
fun f(v: ?Vec[!E]) -> Int?
  match v.get(0)?
    .a(r0)
      s = ?r0.v[..]
      match v.get(0)?
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
  1

sub main()
  e = mk(1)
  v: Vec[!E] = Vec()
  !v.push(!e)
  _ = f(?v)
""" % PUSH)
w("e02_vec_get_writeview_write_readview", """
fun f(v: ?Vec[!E]) -> Int?
  match v.get(0)?
    .a(r) => r.n = 42
    .b => pass
  1

sub main()
  e = mk(1)
  v: Vec[!E] = Vec()
  !v.push(!e)
  _ = f(?v)
  print(e)
""")
w("e03_vec_get_as_writeview", """
sub f(v: ?Vec[!E])
  if v.get(0) as w
    match !w
      .a(r) => r.n = 43
      .b => pass

sub main()
  e = mk(1)
  v: Vec[!E] = Vec()
  !v.push(!e)
  f(?v)
  print(e)
""")
w("e04_vec_get_as_two_writers_uaf", """
sub f(v: ?Vec[!E])
  if v.get(0) as w0
    match w0
      .a(r0)
        s = ?r0.v[..]
        if v.get(0) as w
          match !w
            .a(r)
              for i in 0..100
                !r.v.push(i)
            .b => pass
        print(s[0])
      .b => pass

sub main()
  e = mk(1)
  v: Vec[!E] = Vec()
  !v.push(!e)
  f(?v)
""")
w("e05_vec_get_bind_local", """
sub f(v: ?Vec[!E])
  o = v.get(0)
  if o as w
    match !w
      .a(r) => r.n = 44
      .b => pass

sub main()
  e = mk(1)
  v: Vec[!E] = Vec()
  !v.push(!e)
  f(?v)
  print(e)
""")
w("e06_vec_get_handle", """
sub main()
  e = mk(1)
  v: Vec[!E] = Vec()
  !v.push(!e)
  h = *v
  match h.get(0)?
    .a(r) => r.n = 45
    .b => pass
""")
w("e07_vec_writeview_owner_live", """
fun f(v: !Vec[!E]) -> Int?
  match v.get(0)?
    .a(r0)
      s = ?r0.v[..]
      match !v[0]
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
  1

sub main()
  e = mk(1)
  v: Vec[!E] = Vec()
  !v.push(!e)
  _ = f(!v)
""" % PUSH)
w("e08_for_write_vec_of_writeviews", """
sub main()
  e = mk(1)
  d = mk(2)
  v: Vec[!E] = Vec()
  !v.push(!e)
  !v.push(!d)
  for x in !v
    match !x
      .a(r) => r.n = 50
      .b => pass
  print(v)
""")
w("e09_cell_of_writeview", """
sub main()
  e = mk(1)
  c = Cell(!e)
  match c.get()
    .a(r) => r.n = 46
    .b => pass
  print(e)
""")
w("e10_vec_get_readview_wrap", """
struct H
  w: !E

fun f(v: ?Vec[H]) -> Int?
  match v.get(0)?.w
    .a(r) => r.n = 47
    .b => pass
  1

sub main()
  e = mk(1)
  v: Vec[H] = Vec()
  !v.push(H(w: !e))
  _ = f(?v)
  print(e)
""")
