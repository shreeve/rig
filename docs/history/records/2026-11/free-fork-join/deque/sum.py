#!/usr/bin/env python3
"""sum.py OUT.json BASE [GROUP]: per (workers, row), each arm group's
median (arms named NAMEk pooled by NAME, as placements), the paired median
ratio to BASE per round with its interquartile range, and peak RSS."""
import json, sys, re, statistics as st, collections
data = json.load(open(sys.argv[1])); base = sys.argv[2]
grp = lambda n: re.sub(r'\d+$', '', n)
by = collections.defaultdict(list); rss = collections.defaultdict(list); rounds = collections.defaultdict(lambda: collections.defaultdict(list))
for k, w, n, row, ns, chk, r in data:
    g = grp(n); by[(w, row, g)].append(ns); rss[(w, g)].append(r); rounds[(w, row, k)][g].append(ns)
for key in sorted(by):
    w, row, g = key
    m = st.median(by[key]); unit = "%.1f ns/join" % (m / 4095) if row.startswith('nil') else "%.3f ms" % (m / 1e6)
    line = "%2d %-8s %-8s %16s  n=%d" % (w, row, g, unit, len(by[key]))
    if g != base:
        rs = sorted(st.median(d[g]) / st.median(d[base]) for (ww, rr, k), d in rounds.items() if ww == w and rr == row and g in d and base in d)
        if rs: line += "  /%s %.3f [%.3f-%.3f]" % (base, st.median(rs), rs[len(rs)//4], rs[(3*len(rs))//4])
    print(line)
for key in sorted(rss): print("rss %2d %-8s %8.1f MiB" % (key[0], key[1], st.median(rss[key]) / 1048576))
