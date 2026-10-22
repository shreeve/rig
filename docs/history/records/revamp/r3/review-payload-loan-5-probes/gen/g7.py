import os, sys
P = sys.argv[1]
PRE = open(os.path.join(os.path.dirname(__file__), "pre.rig")).read()
def w(name, body):
    open(os.path.join(P, name + ".rig"), "w").write(PRE + body.strip("\n") + "\n")
w("g01_as_writeview_param_of_opt_writeview", """
fun f(p: !((!E)?)) -> Int?
  if p as x
    match x
      .a(r0)
        s = ?r0.v[..]
        if !p as y
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
  o: (!E)? = !e
  _ = f(!o)
""")
w("g02_as_writeview_param_of_opt_writeview_write", """
fun f(p: !((!E)?)) -> Int?
  if p as x
    match !x
      .a(r) => r.n = 7
      .b => pass
  1

sub main()
  e = mk(1)
  o: (!E)? = !e
  _ = f(!o)
  print(o)
""")
w("g03_while_as_writeview_local_lend", """
fun f(e: !E) -> Int?
  o: (!E)? = !e
  p = !o
  while p as x
    match x
      .a(r0)
        s = ?r0.v[..]
        if !o as y
          match !y
            .a(r)
              for i in 0..100
                !r.v.push(i)
            .b => pass
        print(s[0])
      .b => pass
    break
  1

sub main()
  e = mk(1)
  _ = f(!e)
""")
w("g04_as_readview_param_of_opt_writeview", """
fun f(p: ?((!E)?)) -> Int?
  if p as x
    match x
      .a(r) => print(r.n)
      .b => pass
  1

sub main()
  e = mk(1)
  o: (!E)? = !e
  _ = f(?o)
""")
