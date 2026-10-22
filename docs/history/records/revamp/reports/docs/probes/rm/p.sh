R=/Users/shreeve/Data/Code/rig-rv-docs/bin/rig
probe(){ echo "== $1"; printf "$2" > $1.rig; $R run $1.rig 2>&1 | head -4; }
probe bool_param 'struct R[T, b: Bool]\n  v: T\n\nsub main\n  r = R[Int, true](v: 1)\n  print(r.v)\n'
probe arr_own 'sub main\n  a: [2]Vec[Int] = [Vec(), Vec()]\n  print(a[0].len)\n'
probe clo_own 'sub main\n  f: *fun(Vec[Int]) -> Int = *|v: Vec[Int]| v.len\n  print(f(Vec()))\n'
probe str_match 'sub main\n  s = "a"\n  match s\n    "a" => print(1)\n    _ => print(2)\n'
probe str_cat 'sub main\n  s = "a"\n  t = s + "b"\n  print(t)\n'
probe bytes_print 'sub main\n  a: [2]U8 = [104, 105]\n  b: []U8 = ?a\n  print(b)\n'
probe label_val 'sub main\n  x = :l for i in 0..3\n    break :l i if i == 1\n  else\n    9\n  print(x)\n'
probe ct_arith 'fun f[n: Int]() -> Int\n  a: [n * 2]Int = [0 of n * 2]\n  a.len\n\nsub main\n  print(f[3]())\n'
probe enum_drop 'enum E\n  a\n  b\n\n  drop(!self)\n    print(1)\n\nsub main\n  e: E = .a\n  print(e == .a)\n'
probe gen_drop 'struct W[T]\n  v: T\n\n  drop(!self)\n    print(1)\n\nsub main\n  w = W(v: 1)\n  print(w.v)\n'
probe tryblk 'sub main\n  try\n    print(1)\n'
