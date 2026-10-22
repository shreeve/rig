R=/Users/shreeve/Data/Code/rig-rv-docs/bin/rig
probe(){ echo "== $1"; printf "$2" > $1.rig; $R run $1.rig 2>&1 | head -4; }
mkdir -p al; printf 'pub struct Wrap[T]\n  pub v: T\n\npub type IW = Wrap[Int]\npub type Byte = U8\n' > al/lib.rig
printf 'use lib\n\ntype W = lib.Wrap[Int]\n\nsub main\n  w = W(v: 3)\n  x = lib.IW(v: 4)\n  print(w.v, x.v, lib.Byte.max)\n' > al/main.rig
echo "== alias"; $R run al/main.rig 2>&1 | head -4
probe label_any 'sub main\n  :blk if true\n    print(1)\n'
probe opt_opt 'sub main\n  x: Int?? = none\n  print(x)\n'
mkdir -p sd/util; printf 'pub fun f() -> Int\n  1\n' > sd/util/m.rig; printf 'use util.m\n\nsub main\n  print(m.f())\n' > sd/main.rig
echo "== subdir"; $R run sd/main.rig 2>&1 | head -3
probe fnconst 'fun inc(n: Int) -> Int\n  n + 1\n\nF: fun(Int) -> Int = inc\n\nsub main\n  print(F(1))\n'
probe fnconst2 'fun inc(n: Int) -> Int\n  n + 1\n\nf = inc\n\nsub main\n  print(f(1))\n'
probe errdefer_inf 'sub main\n  errdefer print(1)\n  print(2)\n'
probe errdefer_inf2 'fun f() -> Int\n  errdefer print(1)\n  2\n\nsub main\n  print(f())\n'
probe box_print 'struct P\n  x: Int\n\nsub main\n  b = Box(P(x: 1))\n  s = Box("hi")\n  print(b, s)\n  print("hi")\n'
probe noop_arm 'enum E\n  a\n  b\n\nsub main\n  e: E = .a\n  match e\n    .a => print(1)\n    .b =>\n'
probe noop_pass 'enum E\n  a\n  b\n\nsub main\n  e: E = .a\n  match e\n    .a => print(1)\n    .b => pass\n'
