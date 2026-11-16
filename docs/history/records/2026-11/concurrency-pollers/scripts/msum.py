#!/usr/bin/env python3
"""msum.py RAW...: per rate and variant, medians over rounds of req/s,
p50, p99, p99.9 and server cores, and the count of runs."""
import json, sys, statistics, collections
rows = [json.loads(l) for f in sys.argv[1:] for l in open(f) if l.strip()]
d = collections.defaultdict(list)
order = []
for r in rows:
    d[(r["rate"], r["variant"])].append(r)
    if r["variant"] not in order: order.append(r["variant"])
def ms(x): return "%.2f ms" % (x / 1000) if x >= 1000 else "%d us" % x
print("| offered | arm | runs | req/s | p50 | p99 | p99.9 | server cores |")
print("|---|---|---|---|---|---|---|---|")
for rate in sorted({r["rate"] for r in rows}):
    for v in order:
        rs = d.get((rate, v))
        if not rs: continue
        m = lambda k: statistics.median(r[k] for r in rs)
        print("| %d | %s | %d | %d | %s | %s | %s | %.2f |" % (rate, v, len(rs), m("achieved"), ms(m("p50")), ms(m("p99")), ms(m("p999")), m("server_cores")))
