import os, sys
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
pre = open(sys.argv[2]).read()
# bare branch: leaf types per header
BT = {'match': '!E', 'as': '!(E?)', 'while_as': '!(E?)', 'for': '!Vec[Int]'}
BTH = {'match': 'E', 'as': 'E?', 'while_as': 'E?', 'for': 'Vec[Int]'}
K = {'match': 'e', 'as': 'o', 'while_as': 'o', 'for': 'v'}
def free_bare(h, p):
  return {'match': f"{p} = mk(99)", 'as': f"{p} = none", 'while_as': f"{p} = none", 'for': f"for _ in 0..100\n  !{p}.push(1)"}[h]
def free_path(h, p):
  return {'match': f"{p}.e = mk(99)", 'as': f"{p}.o = none", 'while_as': f"{p}.o = none", 'for': f"for _ in 0..100\n  !{p}.v.push(1)"}[h]
def body(h, subj, free):
  ind = '  '
  if h == 'match':
    return (f"{ind}match {subj}\n{ind}  .a(r)\n{ind}    s = ?r.v[..]\n" + "\n".join(ind+'    '+l for l in free.split("\n")) +
            f"\n{ind}    print(s[0])\n{ind}  .b => pass\n")
  if h in ('as', 'while_as'):
    kw = 'if' if h == 'as' else 'while'
    t = (f"{ind}{kw} {subj} as x\n{ind}  match x\n{ind}    .a(r)\n{ind}      s = ?r.v[..]\n" + "\n".join(ind+'      '+l for l in free.split("\n")) +
         f"\n{ind}      print(s[0])\n{ind}    .b => pass\n")
    if h == 'while_as': t += f"{ind}  break\n"
    return t
  return (f"{ind}n = 0\n{ind}for x in {subj}\n" + "\n".join(ind+'  '+l for l in free.split("\n")) +
          f"\n{ind}  n += x\n{ind}print(n)\n")
def mkval(h):
  return {'match': 'mk(3)', 'as': 'mk(3)', 'while_as': 'mk(3)', 'for': 'mkv(3)'}[h]
n = 0
for h in ['match', 'as', 'while_as', 'for']:
  for sig in ['?', '!', '']:
    for form in ['bare', 'path', 'path2']:
      for leaf in ['wparam', 'local', 'holder']:
        if form == 'bare':
          T = BT[h]; TH = BTH[h]
          extra = ""
          if leaf == 'holder':
            extra = f"struct HB\n  w: {T}\n\n"
            params = "h1: HB, h2: HB"; br = "(h1.w if c else h2.w)"; place = "h1.w"
          elif leaf == 'local':
            params = f"xa: {T}, xb: {T}"; br = "(a if c else b)"; place = "a"
          else:
            params = f"a: {T}, b: {T}"; br = "(a if c else b)"; place = "a"
          subj = sig + br
          free = free_bare(h, place)
          if leaf == 'holder':
            setup = f"  x: {TH} = {mkval(h)}\n  y: {TH} = {mkval(h)}\n  _ = f(HB(w: !x), HB(w: !y), true)\n"
          else:
            setup = f"  x: {TH} = {mkval(h)}\n  y: {TH} = {mkval(h)}\n  _ = f(!x, !y, true)\n"
        else:
          extra = ""
          if leaf == 'holder':
            params = "h1: H, h2: H"; br = "(h1.w if c else h2.w)"; place = "h1.w"
            setup = "  x = mkw(3)\n  y = mkw(3)\n  _ = f(H(w: !x), H(w: !y), true)\n"
          else:
            params = "xa: !W, xb: !W" if leaf == 'local' else "a: !W, b: !W"
            br = "(a if c else b)"; place = "a"
            setup = "  x = mkw(3)\n  y = mkw(3)\n  _ = f(!x, !y, true)\n"
          if form == 'path2': br = '(' + br + ')'
          subj = sig + br + '.' + K[h]
          free = free_path(h, place)
        if sig == '' and form != 'bare': continue  # covered by PR
        loc = "  a = !xa\n  b = !xb\n" if leaf == 'local' else ""
        if leaf == 'local' and form == 'bare': pass
        prog = pre + extra + f"fun f({params}, c: Bool) -> Int?\n{loc}{body(h, subj, free)}  1\n\nsub main()\n{setup}"
        open(os.path.join(out, f"l_{h}.{'r' if sig=='?' else 'w' if sig=='!' else 'n'}.{form}.{leaf}.rig"), 'w').write(prog)
        n += 1
print(n)
