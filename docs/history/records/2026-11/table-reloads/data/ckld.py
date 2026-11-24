#!/usr/bin/env python3
# ckld.py LOADS_TXT DIS CHECKER_FIELDS STORE_FIELDS STORE_OFF: share of sampled loads that read the Checker object, by field.
import sys, re, collections, bisect
txt, dis, cf, sf, soff = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5], 16)
S = [tuple(int(x, 16) for x in l.split()[:2]) for l in open(txt)]
ins = {}; fstart = []
want = {ip for ip, _ in S}
for l in open(dis, errors='replace'):
    h = re.match(r'^([0-9a-f]+) <(.*)>:', l)
    if h: fstart.append((int(h.group(1), 16), h.group(2))); continue
    m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', l)
    if m:
        a = int(m.group(1), 16)
        if a in want: ins[a] = m.group(2)
fstart.sort(); fa = [x[0] for x in fstart]
def fn(ip):
    i = bisect.bisect_right(fa, ip) - 1
    return fstart[i][1] if i >= 0 else '?'
ck = lambda ip: 'checker' in fn(ip).split('.')[0] or fn(ip).startswith('rigx_checker')
import os
if os.environ.get('CKONLY'): S = [s for s in S if ck(s[0])]
# Checker base: samples whose instruction reads disp(soff)(%reg) with no index
cand = collections.Counter()
for ip, ad in S:
    t = ins.get(ip, '')
    m = re.match(r'mov\s+0x([0-9a-f]+)\((%\w+)\),', t)
    if m and int(m.group(1), 16) == soff: cand[ad - soff] += 1
base, nb = cand.most_common(1)[0]
print(f'checker base {base:#x} ({nb} samples of the types head; other candidates {cand.most_common(4)[1:]})')
fields = []
for l in open(cf):
    o, n = l.split(); fields.append((int(o, 16), n))
for l in open(sf):
    o, n = l.split(); fields.append((soff + int(o, 16), 'store.' + n))
fields.sort(); offs = [f[0] for f in fields]
size = 0x4000
tot = len(S); inck = collections.Counter(); n = 0
for ip, ad in S:
    if base <= ad < base + size:
        o = ad - base; i = bisect.bisect_right(offs, o) - 1
        nm = fields[i][1] if i >= 0 else '?'
        if nm.startswith('store.'): nm = 'store.* (Table heads)' if True else nm
        inck[nm] += 1; n += 1
print(f'{tot} load samples; {n} ({100*n/tot:.1f}%) read the Checker object')
for k, v in inck.most_common(25): print(f'{100*v/tot:6.2f}%  {k}')
if os.environ.get('BYFN'):
    want = os.environ['BYFN'].split(',')
    byf = collections.Counter()
    for ip, ad in S:
        if base <= ad < base + size:
            o = ad - base; i = bisect.bisect_right(offs, o) - 1
            nm = fields[i][1] if i >= 0 else '?'
            key = 'store' if nm.startswith('store.') else nm
            if key in want: byf[(key, fn(ip))] += 1
    for k, v in byf.most_common(30): print(f'{100*v/tot:6.2f}%  {k}')
