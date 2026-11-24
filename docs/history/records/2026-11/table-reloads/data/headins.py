#!/usr/bin/env python3
# headins.py HEAD_TXT DIS: what instruction each ld_head sample's IP points at: a load or not, and a load from the
# Checker's store heads (disp in [LO,HI) on a base register), by checker functions only if CKONLY.
import sys, re, collections, bisect, os
txt, dis = sys.argv[1], sys.argv[2]; lo, hi = int(sys.argv[3], 16), int(sys.argv[4], 16)
S = [int(l.split()[0], 16) for l in open(txt)]
want = set(S); ins = {}; prev = {}; fstart = []; last = None
for l in open(dis, errors='replace'):
    h = re.match(r'^([0-9a-f]+) <(.*)>:', l)
    if h: fstart.append((int(h.group(1), 16), h.group(2))); last = None; continue
    m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', l)
    if m:
        a = int(m.group(1), 16); t = m.group(2)
        if a in want: ins[a] = t; prev[a] = last
        last = t
fstart.sort(); fa = [x[0] for x in fstart]
def fn(ip):
    i = bisect.bisect_right(fa, ip) - 1
    return fstart[i][1] if i >= 0 else '?'
if os.environ.get('CKONLY'): S = [s for s in S if fn(s).startswith('checker.') or fn(s).startswith('rigx_checker')]
memsrc = re.compile(r'^(\w+)\s+(-?0x[0-9a-f]+)?\((%\w+)(,%\w+)?(,\d)?\),')
def kind(t):
    if t is None: return 'none'
    m = memsrc.match(t)
    if not m or m.group(1).startswith('lea'): return 'other'
    d = m.group(2)
    if d and m.group(4) is None and lo <= int(d, 16) < hi: return 'store-head load'
    return 'load'
c = collections.Counter(); cp = collections.Counter()
for ip in S: c[kind(ins.get(ip))] += 1; cp[kind(prev.get(ip))] += 1
n = len(S)
print(f'{n} samples. at IP:', {k: f'{100*v/n:.1f}%' for k, v in c.most_common()})
print('   at the instruction before IP:', {k: f'{100*v/n:.1f}%' for k, v in cp.most_common()})
