#!/usr/bin/env python3
"""refills.py TRACE: per K/V type, how far each fill of a map goes between
clears (its largest length), and how many tables of slots each would build
or grow through (first table 32, doubling at 7/8)."""
import sys, numpy as np, collections
path = sys.argv[1]
names = {}
for line in open(path + ".types"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 4: names[int(p[0])] = (p[1], p[2], p[3])
dt = np.dtype([("op", "u1"), ("hit", "u1"), ("width", "<u2"), ("id", "<u4"), ("vbytes", "<u4"), ("len", "<u4"), ("hash", "<u8"), ("key", "V24")])
r = np.memmap(path, dtype=dt, mode="r")
op = r["op"] & 7; ids = r["id"]; ln = r["len"]
# a fill ends at a clear (3) or drop (5); its peak is the largest len seen
CLEAR, DROP = 3, 5
peak = collections.defaultdict(int)
fills = collections.defaultdict(list)
order = np.lexsort((np.arange(len(r)), ids))
cur_id = None; cur = 0
for i in order:
    t = int(ids[i]); o = int(op[i]); L = int(ln[i])
    if t != cur_id:
        if cur_id is not None: fills[cur_id].append(cur)
        cur_id = t; cur = 0
    if o in (CLEAR, DROP):
        fills[t].append(cur); cur = 0
    else:
        cur = max(cur, L)
if cur_id is not None: fills[cur_id].append(cur)
def builds(n):
    if n <= 8: return 0
    s = 32; b = 1
    while s - s // 8 < n: s *= 2; b += 1
    return b
bytype = collections.defaultdict(lambda: collections.Counter())
for t, fs in fills.items():
    nm = names.get(t, ("?", "?", "?"))
    key = f"{nm[2]} {nm[0]} -> {nm[1]}"
    for f in fs:
        c = bytype[key]; c["fills"] += 1
        if f > 8: c["past8"] += 1
        c["tables"] += builds(f)
        if f > 28: c["past28"] += 1
        if f > 64: c["past64"] += 1
for k, c in sorted(bytype.items(), key=lambda e: -e[1]["tables"])[:15]:
    print(f"{c['fills']:9d} fills {c['past8']:8d} past 8 {c['past28']:7d} past 28 {c['past64']:7d} past 64 {c['tables']:8d} tables built  {k}")
