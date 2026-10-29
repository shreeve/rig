#!/usr/bin/env python3
"""sizes.py TRACE: per K/V type, how large each Map/Set gets and where its lookups land."""
import sys
import numpy as np
from collections import defaultdict
path = sys.argv[1]
dt = np.dtype([('op', 'u1'), ('hit', 'u1'), ('w', '<u2'), ('id', '<u4'), ('vb', '<u4'), ('len', '<u4'), ('h', '<u8'), ('key', 'V24')])
r = np.fromfile(path, dtype=dt)
op = r['op'] & 7
ids = r['id']; ln = r['len']
names = {}
for line in open(path + '.types'):
    i, k, v, kind = line.rstrip('\n').split('\t')
    names[int(i)] = f"{kind} {k} -> {v}"
n = int(ids.max()) + 1
maxlen = np.zeros(n, np.int64)
np.maximum.at(maxlen, ids, ln)
gets = np.bincount(ids[op == 0], minlength=n)
puts = np.bincount(ids[op == 1], minlength=n)
grows = np.bincount(ids[op == 6], minlength=n)
drops = np.bincount(ids[op == 5], minlength=n)
# the length when the last record of each id was written (for undropped maps, the end length)
last = np.zeros(n, np.int64)
order = np.argsort(ids, kind='stable')
sid = ids[order]
ends = np.r_[np.nonzero(np.diff(sid))[0], len(sid) - 1]
last[sid[ends]] = ln[order][ends]
bytype = defaultdict(list)
for i in range(1, n):
    if i in names: bytype[names[i]].append(i)
bins = [0, 1, 2, 3, 4, 5, 6, 8, 12, 16, 24, 32, 48, 64, 128, 1024, 1 << 40]
def label(a, b): return f"{a}" if b == a + 1 else f"{a}-{b-1}"
rows = sorted(bytype.items(), key=lambda kv: -len(kv[1]))
for name, idl in rows[:12]:
    idl = np.array(idl)
    print(f"\n{name}: {len(idl)} maps, gets {gets[idl].sum()}, puts {puts[idl].sum()}, grows {grows[idl].sum()}, dropped {np.count_nonzero(drops[idl])}")
    ml = maxlen[idl]
    h, _ = np.histogram(ml, bins=bins)
    print("  largest length:", ", ".join(f"{label(bins[k], bins[k+1])}: {h[k]}" for k in range(len(h)) if h[k]))
    # lookups by the length at the time
    sel = np.isin(ids, idl) & (op == 0)
    hl, _ = np.histogram(ln[sel], bins=bins)
    tot = hl.sum() or 1
    print("  gets by length then:", ", ".join(f"{label(bins[k], bins[k+1])}: {100*hl[k]/tot:.1f}%" for k in range(len(hl)) if hl[k]))
    alive = idl[drops[idl] == 0]
    ha, _ = np.histogram(last[alive], bins=bins)
    print(f"  never dropped: {len(alive)}; their end length:", ", ".join(f"{label(bins[k], bins[k+1])}: {ha[k]}" for k in range(len(ha)) if ha[k]))
    print("  entries at the end, never-dropped:", int(last[alive].sum()))
