#!/usr/bin/env python3
"""stats.py OUT.json [BASE]: median ns per (workers, program, row), the
check, peak RSS (MiB, median), and each program's paired median ratio to
BASE per round."""
import json, sys, statistics as st, collections
data = json.load(open(sys.argv[1])); base = sys.argv[2] if len(sys.argv) > 2 else None
by = collections.defaultdict(list); rss = collections.defaultdict(list); rounds = collections.defaultdict(dict)
for k, w, n, row, ns, chk, r in data:
    by[(w, row, n)].append(ns); rss[(w, n)].append(r); rounds[(w, row)].setdefault(k, {})[n] = ns
for key in sorted(by):
    w, row, n = key
    line = "%2d %-8s %-12s %10.3f ms  n=%d" % (w, row, n, st.median(by[key]) / 1e6, len(by[key]))
    if base and n != base:
        rs = [d[n] / d[base] for d in rounds[(w, row)].values() if n in d and base in d]
        if rs:
            rs.sort(); line += "  /%s %.3f [%.3f-%.3f]" % (base, st.median(rs), rs[len(rs) // 4], rs[(3 * len(rs)) // 4])
    print(line)
for key in sorted(rss):
    print("rss %2d %-12s %8.1f MiB" % (key[0], key[1], st.median(rss[key]) / 1048576))
