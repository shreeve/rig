#!/usr/bin/env python3
"""summ.py TIMES BASE: medians per project and variant of time.sh's lines,
each against BASE and against tsrs (wall), and any output that differed."""
import sys, statistics, collections
rows = collections.defaultdict(lambda: collections.defaultdict(list))
bad = collections.Counter(); rounds = collections.Counter(); order = []
for l in open(sys.argv[1]):
    if l.startswith("#"): continue
    f = l.split(); proj = f[0]; kv = dict(x.split("=", 1) for x in f[1:])
    v = kv["v"]
    if (proj, v) not in rounds: order.append((proj, v))
    for k in ("ns", "cycles", "instructions", "rss_kb"):
        try: rows[(proj, v)][k].append(float(kv[k]))
        except ValueError: pass
    if kv["same"] != "1": bad[(proj, v)] += 1
    rounds[(proj, v)] += 1
base = sys.argv[2]
def med(p, v, k): return statistics.median(rows[(p, v)][k])
for proj in ("ts-pattern", "zod3"):
    vs = [v for (p, v) in order if p == proj]
    if not vs: continue
    print(f"\n{proj}")
    print(f"| variant | rounds | wall median ms | wall fastest | cycles G | instructions G | peak RSS MB | vs {base}: faster / fewer cycles / fewer instructions | vs tsrs, wall |")
    print("|---|---:|---:|---:|---:|---:|---:|---|---:|")
    for v in vs:
        r = rows[(proj, v)]
        cells = [v, str(rounds[(proj, v)]), f"{med(proj,v,'ns')/1e6:.1f}", f"{min(r['ns'])/1e6:.1f}", f"{med(proj,v,'cycles')/1e9:.3f}", f"{med(proj,v,'instructions')/1e9:.3f}", f"{med(proj,v,'rss_kb')/1024:.0f}"]
        if v != base and (proj, base) in rows:
            cells.append(" / ".join(f"{100*(1-med(proj,v,k)/med(proj,base,k)):.2f}%" for k in ("ns", "cycles", "instructions")))
        else: cells.append("")
        cells.append(f"{med(proj,v,'ns')/med(proj,'tsrs','ns'):.3f}x" if (proj, "tsrs") in rows and v != "tsrs" else "")
        if bad[(proj, v)]: cells[0] += f" (output differed {bad[(proj, v)]}x)"
        print("| " + " | ".join(cells) + " |")
