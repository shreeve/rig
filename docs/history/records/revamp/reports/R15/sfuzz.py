import random, subprocess, os, sys
random.seed(int(sys.argv[1])); N = int(sys.argv[2])
env = dict(os.environ, RIG_OUT_DIR=os.path.abspath("out2"))
os.makedirs("sfz", exist_ok=True)
def bound():
    return random.choice(["", "", "0", "1", "2", "n", "n - 1", "s.len", "b.len - 2", "(n + 1)"])
def rng():
    return bound() + ".." + bound()
bases_w = ["a", "b", "s", "v", "g.arr", "grid[1]", "vs[0].arr"]
def slc(depth=0):
    base = random.choice(bases_w)
    e = random.choice(["!", "?"]) + base + "[" + rng() + "]"
    return e
def stmt():
    c = random.randint(0, 12)
    if c == 0: return "x = %s\n  print(x.len)" % slc()
    if c == 1: return "%s.fill(%s)" % ("!" + random.choice(bases_w) + random.choice(["", "[" + rng() + "]"]), random.choice(["0", "n", "7"]))
    if c == 2: return "!%s[%s].copy(%s)" % (random.choice(bases_w), rng(), slc())
    if c == 3: return "!%s.swap(%s, %s)" % (random.choice(bases_w), bound() or "0", bound() or "1")
    if c == 4: return "print(%s.read[%s, %s](%s))" % (random.choice(["b", "t", "u", "\"abcdefgh\"", "?b[1..]", "bv"]), random.choice(["U8", "U16", "I32", "U64", "F32", "F64", "Int", "Float", "I8"]), random.choice([".big", ".little", "Endian.big", "E"]), bound() or "0")
    if c == 5: return "!%s.write[%s, %s](%s, %s)" % (random.choice(["b", "u", "bv", "b[1..]"]), random.choice(["U8", "U16", "I32", "U64", "F32", "F64", "I16"]), random.choice([".big", ".little", "E"]), bound() or "0", random.choice(["1", "n", "2.5", "-1"]))
    if c == 6: return "x = %s\n  x[%s] = %s\n  print(x)" % (slc(), bound() or "0", random.choice(["1", "n"]))
    if c == 7: return "for e in %s\n    e = 3" % slc()
    if c == 8: return "sink(%s)" % slc()
    if c == 9: return "print(total(%s))" % slc()
    if c == 10: return "y = !s[%s]\n  z = !y[%s]\n  z[0] = 1\n  print(s)" % (rng(), rng())
    if c == 11: return "!s.copy(%s)" % slc()
    return "print(%s)" % slc()
pre = """struct G
  arr: [3]Int
struct H
  arr: [3]Int
E =! Endian.little
fun total(xs: []Int) -> Int
  t = 0
  for x in xs
    t += x
  t
sub sink(xs: ![]Int)
  for x in !xs
    x += 1
sub f(s: ![]Int, t: []U8, n: Int)
  a = [1, 2, 3]
  b: [8]U8 = [8 of 1]
  b2: [8]U8 = [8 of 2]
  u = !b2[..]
  g = G(arr: [4, 5, 6])
  grid = [[1, 2, 3], [4, 5, 6]]
  vs: Vec[H] = Vec()
  !vs.push(H(arr: [7, 8, 9]))
  v: Vec[Int] = Vec()
  !v.push(1)
  !v.push(2)
  bv: Vec[U8] = Vec()
  !bv.push(1)
"""
post = """
  print(u.len)
  print(a, b, s, t.len, n, g.arr, grid, vs.len, v, bv, b2)
sub main()
  a0 = [0, 1, 2, 3]
  b0: [4]U8 = [0, 1, 2, 3]
  f(!a0[..], ?b0[..], 2)
  print(a0)
"""
bad = acc = 0
for i in range(N):
    body = "\n".join("  " + stmt() for _ in range(random.randint(1, 3)))
    src = pre + body + post
    p = "sfz/c%d_%d.rig" % (int(sys.argv[1]), i)
    open(p, "w").write(src)
    r = subprocess.run(["gtimeout", "10", "/Users/shreeve/Data/Code/rig/bin/rig", "check", p], capture_output=True, text=True, env=env)
    out = r.stdout + r.stderr
    if r.returncode not in (0, 1) or "panic" in out or "thread " in out:
        bad += 1; print("CRASH", p, out[:500]); continue
    if r.returncode == 1:
        if ": error:" not in out: bad += 1; print("NODIAG", p, out[:300])
        os.remove(p); continue
    acc += 1
    r2 = subprocess.run(["gtimeout", "120", "/Users/shreeve/Data/Code/rig/bin/rig", "run", p], capture_output=True, text=True, env=env)
    o2 = r2.stdout + r2.stderr
    if r2.returncode != 0 and "panic:" not in o2:
        bad += 1; print("ACCEPT-BUT-FAIL", p); print(o2[:1200]); continue
    if "panic:" in o2 and not any(k in o2 for k in ["out of range", "out of bounds", "different lengths", "overflow"]):
        bad += 1; print("ODD-PANIC", p, o2[:600]); continue
    if "leak" in o2.lower():
        bad += 1; print("LEAK", p, o2[:600]); continue
    os.remove(p)
print("done bad", bad, "accepted", acc)
