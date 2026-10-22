import os, sys
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
PRE = """struct Res
  n: Int
  v: Vec[Int]

enum E
  a(r: Res)
  b

fun mk(n: Int) -> E
  v: Vec[Int] = Vec()
  !v.push(n)
  E.a(r: Res(n: n, v: <v))

struct Q
  e: E
  o: E?
  v: Vec[Int]

struct W
  e: E
  o: E?
  v: Vec[Int]
  q: Q?

  fun ge(?self) -> ?E
    ?self.e

  fun gv(?self) -> ?Vec[Int]
    ?self.v

  fun go(?self) -> ?(E?)
    ?self.o

  fun gew(!self) -> !E
    !self.e

  fun gvw(!self) -> !Vec[Int]
    !self.v

struct H
  w: !W

fun mkv(n: Int) -> Vec[Int]
  v: Vec[Int] = Vec()
  for i in 0..n
    !v.push(i + 1)
  v

fun mkw(n: Int) -> W
  W(e: mk(n), o: mk(n + 10), v: mkv(n), q: Q(e: mk(n + 20), o: mk(n + 30), v: mkv(n)))

fun id[T](x: T) -> T
  x

"""
# free ops by target kind (place is `P`, the a-side place expression)
FREE = {
  'e': "{P}.e = mk(99)",
  'o': "{P}.o = none",
  'v': "for _ in 0..100\n{I}  !{P}.v.push(1)",
  'q': "{P}.q = none",
}
# shapes: name -> (subject template with {B} = branch text, kind of value (E, E?, Vec), which free)
SHAPES = [
  ('path_e',        '{B}.e', 'E', 'e'),
  ('path_o',        '{B}.o', 'O', 'o'),
  ('path_v',        '{B}.v', 'V', 'v'),
  ('paren2_e',      '(({B})).e', 'E', 'e'),
  ('paren2_v',      '(({B})).v', 'V', 'v'),
  ('unwrap_o',      '{B}.o?', 'E', 'o'),
  ('optq_e',        '{B}.q?.e', 'E', 'q'),
  ('optq_o',        '{B}.q?.o', 'O', 'q'),
  ('optq_v',        '{B}.q?.v', 'V', 'q'),
  ('optq_ou',       '{B}.q?.o?', 'E', 'q'),
  ('coal_o',        '({B}.o ?? mk(5))', 'E', 'o'),
  ('meth_ge',       '{B}.ge()', 'E', 'e'),
  ('meth_gv',       '{B}.gv()', 'V', 'v'),
  ('meth_go',       '{B}.go()', 'O', 'o'),
  ('meth_gew',      '(!{B}).gew()', 'E', 'e'),
  ('meth_gvw',      '(!{B}).gvw()', 'V', 'v'),
  ('lendr_e',       '?{B}.e', 'E', 'e'),
  ('lendr_o',       '?{B}.o', 'O', 'o'),
  ('lendr_v',       '?{B}.v', 'V', 'v'),
  ('lendw_e',       '!{B}.e', 'E', 'e'),
  ('lendw_o',       '!{B}.o', 'O', 'o'),
  ('lendw_v',       '!{B}.v', 'V', 'v'),
  ('lendr_q_e',     '?{B}.q?.e', 'E', 'q'),
  ('lendw_q_e',     '!{B}.q?.e', 'E', 'q'),
  ('generic_e',     'id({B}).e', 'E', 'e'),
  ('generic_v',     'id({B}).v', 'V', 'v'),
  ('nestbr_e',      '({B}.e if c else d)', 'E', 'e'),
  ('nestbr_v',      '({B}.v if c else dv)', 'V', 'v'),
  ('slice_v',       '?{B}.v[0..2]', 'S', 'v'),
]
LEAVES = {
  # name: (params, branch text, place text, call args setup)
  'wparam': ("a: !W, b: !W", "(a if c else b)", "a", "  f(!x, !y, true, mk(7), mkv(2))\n"),
  'holder': ("h1: H, h2: H", "(h1.w if c else h2.w)", "h1.w", None),
  'local':  ("xa: !W, xb: !W", "(a if c else b)", "a", None),
  'vec':    ("a: !Vec[W], b: !Vec[W]", "(a if c else b)[0]", "a[0]", None),
}
HEADERS = ['match', 'as', 'while_as', 'for']
def body(header, kind, subj, free, ind='  '):
  if header == 'match':
    if kind != 'E': return None
    return (f"{ind}match {subj}\n{ind}  .a(r)\n{ind}    s = ?r.v[..]\n" + "\n".join(ind+'    '+l for l in free.split("\n")) +
            f"\n{ind}    print(s[0])\n{ind}  .b => pass\n")
  if header in ('as', 'while_as'):
    if kind != 'O': return None
    kw = 'if' if header == 'as' else 'while'
    t = (f"{ind}{kw} {subj} as x\n{ind}  match x\n{ind}    .a(r)\n{ind}      s = ?r.v[..]\n" + "\n".join(ind+'      '+l for l in free.split("\n")) +
         f"\n{ind}      print(s[0])\n{ind}    .b => pass\n")
    if header == 'while_as': t += f"{ind}  break\n"
    return t
  if header == 'for':
    if kind not in ('V', 'S'): return None
    return (f"{ind}n = 0\n{ind}for x in {subj}\n" + "\n".join(ind+'  '+l for l in free.split("\n")) +
            f"\n{ind}  n += x\n{ind}print(n)\n")
count = 0
for lname, (params, br, place, _) in LEAVES.items():
  for sname, tmpl, kind, fk in SHAPES:
    for h in HEADERS:
      subj = tmpl.format(B=br)
      if lname == 'holder' and (sname.startswith('lendw') or sname.startswith('meth_g') and 'w' in sname[6:]):
        pass
      free = FREE[fk].format(P=place, I='')
      if sname.startswith('lendw') and h == 'for': subj = subj  # `for x in !...`
      b = body(h, kind, subj, free)
      if b is None: continue
      pre = ""
      if lname == 'local':
        pre = "  a = !xa\n  b = !xb\n"
      fn = f"fun f({params}, c: Bool, d: E, dv: Vec[Int]) -> Int?\n{pre}{b}  1\n\n"
      if lname == 'wparam' or lname == 'local':
        main = "sub main()\n  x = mkw(3)\n  y = mkw(3)\n  _ = f(!x, !y, true, mk(7), mkv(2))\n"
      elif lname == 'holder':
        main = "sub main()\n  x = mkw(3)\n  y = mkw(3)\n  h1 = H(w: !x)\n  h2 = H(w: !y)\n  _ = f(h1, h2, true, mk(7), mkv(2))\n"
      else:
        main = "sub main()\n  x: Vec[W] = Vec()\n  !x.push(mkw(3))\n  y: Vec[W] = Vec()\n  !y.push(mkw(3))\n  _ = f(!x, !y, true, mk(7), mkv(2))\n"
      name = f"g_{h}.{sname}.{lname}.rig"
      open(os.path.join(out, name), 'w').write(PRE + fn + main)
      count += 1
print(count)
