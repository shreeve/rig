import os, sys
P = sys.argv[1]
def w(name, body):
    open(os.path.join(P, name + ".rig"), "w").write(body.strip("\n") + "\n")
w("h01_for_prop_local_opt_writevec", """
fun f(v: !Vec[Int]) -> Int?
  o: (!Vec[Int])? = !v
  n = 0
  for x in o?
    if !o as w
      for i in 0..100
        !w.push(i)
    n += x
  print(n)
  1

sub main()
  v: Vec[Int] = Vec()
  for i in 0..5
    !v.push(i + 1)
  _ = f(!v)
""")
w("h02_for_branch_writeparam_fields", """
struct H
  v: !Vec[Int]

sub f(h1: !H, h2: !H, c: Bool)
  n = 0
  for x in (h1.v if c else h2.v)
    for i in 0..100
      !h1.v.push(i)
    n += x
  print(n)

sub main()
  v: Vec[Int] = Vec()
  for i in 0..5
    !v.push(i + 1)
  u: Vec[Int] = Vec()
  h1 = H(v: !v)
  h2 = H(v: !u)
  f(!h1, !h2, true)
""")
w("h03_for_coalesce_place_and_lend", """
fun f(v: !Vec[Int], d: !Vec[Int]) -> Int?
  o: (!Vec[Int])? = !v
  n = 0
  for x in o ?? !d
    if !o as w
      for i in 0..100
        !w.push(i)
    n += x
  print(n)
  1

sub main()
  v: Vec[Int] = Vec()
  for i in 0..5
    !v.push(i + 1)
  d: Vec[Int] = Vec()
  _ = f(!v, !d)
""")
w("h04_for_write_branch_bare", """
sub f(a: !Vec[Int], b: !Vec[Int], c: Bool)
  for x in !(a if c else b)
    x += 1
  print(a)

sub main()
  v: Vec[Int] = Vec()
  !v.push(1)
  u: Vec[Int] = Vec()
  f(!v, !u, true)
""")
