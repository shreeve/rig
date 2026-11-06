#!/usr/bin/env python3
# paired.py CSV...: pooled fastest wall/min cycles, and the median per-round ratio to base, per arm
import sys, collections, statistics as st
d = collections.defaultdict(dict)
for f in sys.argv[1:]:
    for l in open(f):
        m, r, p, a, w, c, i, rss, foot, code, dg, ld = l.strip().split(",")
        d[(m, f, r, p)][a] = (float(w), int(c), int(i), int(foot))
order = ["mitt","neverthrow","tiny-invariant","superstruct","zod3","ts-pattern"]
print("| ck | project | rounds | arm | pooled fastest wall | pooled min cycles | median paired wall ratio | median paired cycles ratio | instr | peak footprint |")
print("|---|---|---|---|---|---|---|---|---|---|")
for m in sorted(set(k[0] for k in d)):
    for p in order:
        rs = [v for k, v in d.items() if k[0] == m and k[3] == p]
        for a in ["baseA", "signal"]:
            bw = min(x["base"][0] for x in rs); aw = min(x[a][0] for x in rs)
            bc = min(x["base"][1] for x in rs); ac = min(x[a][1] for x in rs)
            bi = min(x["base"][2] for x in rs); ai = min(x[a][2] for x in rs)
            bf = max(x["base"][3] for x in rs); af = max(x[a][3] for x in rs)
            pw = st.median(x[a][0]/x["base"][0] for x in rs); pc = st.median(x[a][1]/x["base"][1] for x in rs)
            print(f"| {m} | {p} | {len(rs)} | {a} | {100*(aw/bw-1):+.2f}% | {100*(ac/bc-1):+.2f}% | {100*(pw-1):+.2f}% | {100*(pc-1):+.2f}% | {100*(ai/bi-1):+.2f}% | {100*(af/bf-1):+.2f}% |")
