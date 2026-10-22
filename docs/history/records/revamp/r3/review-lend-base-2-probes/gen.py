#!/usr/bin/env python3
import os, sys, itertools
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
PRE = '''enum E
  a(n: Int)
  b

error Bad
  bad

fun double(n: Int) -> Int
  n * 2

fun yes(n: Int) -> Bool
  n > 0

struct Set
  items: Vec[Int]

  fun insert(!self, k: Int) -> Bool
    !self.items.push(k)
    true

struct Q
  n: Int

  sub bump(!self)
    self.n += 1

  fun get(?self) -> Int
    self.n

struct S
  x: Int
  o: Int?
  a: [2]Int
  v: Vec[Int]
  q: Q
  e: E
  f: fun(Int) -> Int
  g: fun(Int) -> Bool
  t: Text
  s: Set

fun mk(n: Int) -> S
  S(x: n, o: n, a: [n, n], v: Vec(), q: Q(n: n), e: E.a(n: n), f: double, g: yes, t: Text("t"), s: Set(items: Vec()))

fun pk(d: !S, k: Bool) -> (!S)?
  return none if k
  d

fun fl(d: !S, k: Bool) -> (!S)!
  return Bad.bad if k
  d

sub bump(n: !Int)
  n += 100

fun show(c: ?S) -> Int
  c.x * 1000 + c.a[1] * 100 + c.q.n * 10 + c.v.len
'''
WR = {
  'w': '(!c)', 'r': '(?c)', 'mw': '(<(!c))', 'mr': '(<(?c))',
  'bw': '(!c if k else !d)', 'br': '(?c if k else ?d)',
  'mbw': '(<(!c if k else !d))', 'mbr': '(<(?c if k else ?d))',
  'lbw': '(!(!c if k else !d))', 'co': '(pk(!d, k) ?? !c)', 'ca': '(fl(!d, k) catch !c)',
  'held': '(w)', 'mheld': '(<w)', 'pw': '(!pc)', 'mpw': '(<(!pc))',
}
OPS = {
  'set': ['B.x = 5'],
  'opset': ['B.x += 1'],
  'read': ['y = B.x', 'print(y)'],
  'readplus': ['y = B.x + 1', 'print(y)'],
  'typed': ['y: Int = B.x', 'print(y)'],
  'elemset': ['B.a[1] = 9'],
  'elemread': ['y = B.a[1] + 1', 'print(y)'],
  'push': ['!B.v.push(1)'],
  'vlen': ['y = B.v.len + 1', 'print(y)'],
  'asw': ['if !B.o as z', '  z += 1'],
  'ast': ['if <B.o as z', '  print(z)'],
  'take': ['y = <B.o', 'print(y)'],
  'bumpm': ['!B.q.bump()'],
  'bumpp': ['(!B.q).bump()'],
  'getm': ['y = B.q.get() + 1', 'print(y)'],
  'match': ['match !B.e', '  .a(n) => n += 1', '  .b => pass'],
  'for': ['for z in !B.a', '  z += 1'],
  'fcall': ['y = B.f(2) + 1', 'print(y)'],
  'gcall': ['if B.g(1)', '  print(7)'],
  'fprint': ['print(B.f(2))'],
  'bumpf': ['bump(!B.x)'],
  'textadd': ['!B.t.add("z")'],
  'insert': ['y = (!B.s).insert(1)', 'print(y)'],
  'whole': ['y = show(?B)', 'print(y)'],
  'slice': ['y = (?B.a[..])[1] + 1', 'print(y)'],
  'sliceset': ['(!B.a[..])[1] = 3'],
}
CTX = ['stmt', 'closure', 'tail', 'param']
n = 0
for (wn, w), (on, ops) in itertools.product(WR.items(), OPS.items()):
  for ctx in CTX:
    if ctx == 'closure' and len(ops) != 1: continue
    if ctx == 'tail' and not on in ('read','readplus','elemread','vlen','getm','fcall','take','insert','whole'): continue
    pcw = w.startswith('(!pc') or w.startswith('(<(!pc')
    if pcw and ctx != 'param': continue
    if ctx == 'param' and not pcw: continue
    body = [l.replace('B', w) for l in ops]
    lines = []
    fun = ''
    setup = ['c = mk(1)', 'd = mk(2)', 'k = c.x > 0', '_ = k']
    if wn in ('held', 'mheld'): setup.append('w = !c')
    if ctx == 'stmt':
      lines = setup + body
      lines.append('print(show(?c), show(?d))')
    elif ctx == 'closure':
      caps = '!c, !d, +k' if wn not in ('held','mheld') else '<w'
      if wn in ('held','mheld'):
        lines = setup + ['f = |' + caps + '| ' + body[0], '_ = f()', 'print(show(?d))']
      else:
        lines = setup + ['f = |' + caps + '| ' + body[0], '_ = f()', 'print(show(?c), show(?d))']
    elif ctx == 'tail':
      # function whose last value is the expression
      expr = body[0].split(' = ', 1)[1]
      ret = 'Bool' if on == 'insert' else ('Int?' if on == 'take' else 'Int')
      if wn in ('held','mheld'):
        fun = 'fun tl(c: !S, d: !S, k: Bool) -> ' + ret + '\n  _ = k\n  w = !c\n  ' + expr + '\n'
      else:
        fun = 'fun tl(c: !S, d: !S, k: Bool) -> ' + ret + '\n  _ = k\n  ' + expr + '\n'
      lines = ['c = mk(1)', 'd = mk(2)', 'kk = c.x > 0', 'print(tl(!c, !d, kk))', 'print(show(?c), show(?d))']
    elif ctx == 'param':
      fun = 'sub go(pc: !S)\n' + '\n'.join('  ' + l for l in body) + '\n'
      lines = ['c = mk(1)', 'go(!c)', 'print(show(?c))']
    src = PRE + '\n' + fun + '\nsub main()\n' + '\n'.join('  ' + l for l in lines) + '\n'
    with open(os.path.join(OUT, f'{wn}__{on}__{ctx}.rig'), 'w') as f: f.write(src)
    n += 1
print(n)
