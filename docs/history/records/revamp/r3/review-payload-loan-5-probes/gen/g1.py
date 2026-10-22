import os, sys
P = sys.argv[1]
PRE = """struct Res
  n: Int
  v: Vec[Int]

enum E
  a(r: Res)
  b

error Bad
  nope

fun mk(n: Int) -> E
  v: Vec[Int] = Vec()
  !v.push(n)
  E.a(r: Res(n: n, v: <v))

fun getw(e: !E) -> !E
  e

fun tryw(e: !E, ok: Bool) -> (!E)!
  return Bad.nope if not ok
  e

fun optw(e: !E, ok: Bool) -> (!E)?
  return none if not ok
  e

fun id[T](x: T) -> T
  x

"""
PUSH = """          for i in 0..100
            !r.v.push(i)"""
def w(name, body):
    open(os.path.join(P, name + ".rig"), "w").write(PRE + body.strip("\n") + "\n")

# A: makesWriteView accepts a call/move leaf that is really a read or copy
w("a01_call_arg_readview_field", """
struct H
  w: !E

sub f(h: ?H)
  match h.w
    .a(r0)
      s = ?r0.v[..]
      match getw(h.w)
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
  e = mk(1)
  h = H(w: !e)
  f(?h)
""" % PUSH)
w("a02_call_arg_bare_param_live", """
sub f(a: !E)
  match a
    .a(r0)
      s = ?r0.v[..]
      match getw(a)
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
  e = mk(1)
  f(!e)
""" % PUSH)
w("a03_generic_id_readview_field", """
struct H
  w: !E

sub f(h: ?H)
  match h.w
    .a(r0)
      s = ?r0.v[..]
      match id(h.w)
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
  e = mk(1)
  h = H(w: !e)
  f(?h)
""" % PUSH)
w("a04_generic_id_bare_param", """
sub f(a: !E)
  match a
    .a(r0)
      s = ?r0.v[..]
      match id(a)
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
  e = mk(1)
  f(!e)
""" % PUSH)
w("a04b_generic_id_bare_param_write_only", """
sub f(h: ?H)
  match id(h.w)
    .a(r) => r.n = 77
    .b => pass

struct H
  w: !E

sub main()
  e = mk(1)
  h = H(w: !e)
  f(?h)
  print(e)
""")
w("a05_method_readself_returns_field", """
struct H
  w: !E

  fun gw(?self) -> !E
    self.w

sub main()
  e = mk(1)
  h = H(w: !e)
  match h.gw()
    .a(r) => r.n = 5
    .b => pass
  print(h.w)
""")
w("a05b_method_writeself_on_readview", """
struct H
  w: !E

  fun gw(!self) -> !E
    !self.w

sub f(h: ?H)
  match h.gw()
    .a(r) => r.n = 5
    .b => pass

sub main()
  e = mk(1)
  h = H(w: !e)
  f(?h)
  print(e)
""")
w("a05c_method_writeself_ok", """
struct H
  w: !E

  fun gw(!self) -> !E
    !self.w

sub main()
  e = mk(1)
  h = H(w: !e)
  match (!h).gw()
    .a(r)
      for i in 0..3
        !r.v.push(i)
    .b => pass
  print(h.w)
""")
w("a05d_method_writeself_live_owner", """
struct H
  w: !E

  fun gw(!self) -> !E
    !self.w

sub main()
  e = mk(1)
  h = H(w: !e)
  match (!h).gw()
    .a(r0)
      s = ?r0.v[..]
      match (!h).gw()
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
""" % PUSH)
w("a06_closure_returns_capture_twice", """
sub main()
  e = mk(1)
  f = |!e| !e
  match f()
    .a(r0)
      s = ?r0.v[..]
      match f()
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
""" % PUSH)
w("a06b_closure_returns_capture_bare", """
sub main()
  e = mk(1)
  f = |!e| e
  match f()
    .a(r0)
      s = ?r0.v[..]
      match f()
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
""" % PUSH)
w("a06c_closure_readcap_returns_field", """
struct H
  w: !E

sub main()
  e = mk(1)
  h = H(w: !e)
  f = |?h| h.w
  match f()
    .a(r) => r.n = 9
    .b => pass
  print(h.w)
""")
w("a06d_closure_then_owner_write", """
sub main()
  e = mk(1)
  f = |!e| !e
  match f()
    .a(r0)
      s = ?r0.v[..]
      match !e
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
""" % PUSH)
w("a07_move_field_of_writeparam", """
struct H
  w: !E

sub f(h: !H, d: !E, c: Bool)
  match (<h.w if c else !d)
    .a(r) => r.n = 3
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  h = H(w: !e)
  f(!h, !d, true)
  print(e)
""")
w("a07b_move_optfield_readview", """
struct H
  o: (!E)?

sub f(h: ?H)
  match (<h.o)?
    .a(r) => r.n = 3
    .b => pass

sub main()
  e = mk(1)
  h = H(o: !e)
  f(?h)
  print(e)
""")
w("a07c_move_optfield_handle", """
struct H
  o: (!E)?

sub f(h: *H) -> Int?
  match (<h.o)?
    .a(r) => r.n = 3
    .b => pass
  1

sub main()
  e = mk(1)
  h = *H(o: !e)
  _ = f(h)
  print(e)
""")
w("a07d_move_optfield_writeparam_live", """
struct H
  o: (!E)?

sub f(h: !H) -> Int?
  match (<h.o)?
    .a(r0)
      s = ?r0.v[..]
      if !h.o as w
        match !w
          .a(r)
%s
          .b => pass
      print(s[0])
    .b => pass
  1

sub main()
  e = mk(1)
  h = H(o: !e)
  _ = f(!h)
  print(e)
""" % PUSH.replace("\n", "\n  ").replace("          for", "            for",1))
w("a08_loop_value_bare_param", """
sub f(a: !E)
  x = while true
    break a
  match x
    .a(r0)
      s = ?r0.v[..]
      match !a
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
  e = mk(1)
  f(!e)
""" % PUSH)
w("a09_match_value_bare_param", """
sub f(a: !E, b: !E, k: Int)
  x = match k
    0 => a
    _ => b
  match x
    .a(r0)
      s = ?r0.v[..]
      match !a
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  f(!e, !d, 0)
""" % PUSH)
w("a10_coalesce_call_place_mixed", """
struct H
  w: !E

sub f(x: !E, h: ?H)
  match optw(x, false) ?? h.w
    .a(r) => r.n = 77
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  h = H(w: !d)
  f(!e, ?h)
  print(d)
""")
w("a11_propagate_call_ok", """
fun f(x: !E) -> Int!
  match tryw(x, true)!
    .a(r)
      for i in 0..3
        !r.v.push(i)
    .b => pass
  1

sub main()
  e = mk(1)
  _ = f(!e) catch |_| 0
  print(e)
""")
w("a12_propagate_none_call_live", """
fun f(x: !E) -> Int?
  match optw(x, true)?
    .a(r0)
      s = ?r0.v[..]
      match !x
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
  1

sub main()
  e = mk(1)
  _ = f(!e)
""" % PUSH)
w("a13_catch_block_handler_place", """
struct H
  w: !E

sub f(x: !E, h: ?H)
  match (tryw(x, false) catch |_| h.w)
    .a(r) => r.n = 77
    .b => pass

sub main()
  e = mk(1)
  d = mk(2)
  h = H(w: !d)
  f(!e, ?h)
  print(d)
""")
w("a14_call_returning_readview_wrapped", """
struct H
  w: !E

fun peek(h: ?H) -> ?E
  h.w

sub f(h: ?H)
  match peek(h)
    .a(r) => r.n = 3
    .b => pass

sub main()
  e = mk(1)
  h = H(w: !e)
  f(?h)
""")
w("a15_getw_of_handle_field", """
struct H
  w: !E

sub f(h: *H)
  match getw(h.w)
    .a(r) => r.n = 3
    .b => pass

sub main()
  e = mk(1)
  h = *H(w: !e)
  f(h)
  print(e)
""")
w("a16_getw_of_local_writeview_twice", """
sub main()
  e = mk(1)
  w = !e
  match getw(w)
    .a(r0)
      s = ?r0.v[..]
      match getw(w)
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
""" % PUSH)
w("a17_move_local_then_use", """
sub main()
  e = mk(1)
  d = mk(2)
  w = !e
  c = true
  match (<w if c else !d)
    .a(r0)
      s = ?r0.v[..]
      match !e
        .a(r)
%s
        .b => pass
      print(s[0])
    .b => pass
""" % PUSH)
