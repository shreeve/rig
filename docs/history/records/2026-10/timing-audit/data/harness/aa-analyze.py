#!/usr/bin/env python3
"""time-ab A/A: each copy (c, d) against s at one checker and at
four, per project: wall median and fastest, user+kernel cycles, peak RSS,
whether outputs matched. Usage: analyze.py times.txt"""
import statistics as st, sys
runs = {}
order = []
for line in open(sys.argv[1]):
    if " round=" not in line: continue
    f = line.split(); d = dict(x.split("=", 1) for x in f[1:] if "=" in x)
    k = (f[0], d["v"])
    if f[0] not in order: order.append(f[0])
    runs.setdefault(k, []).append(d)
def pct(a, b, more="more", less="less"):
    if abs(a / b - 1) < 0.0005: return "the same"
    return f"{abs(a / b - 1) * 100:.1f}% {more if a > b else less}"
print("| project | checkers | arm | base wall median ms | arm wall median ms | wall median | wall fastest | user+kernel cycles | peak RSS | outputs |")
print("|---|---|---|---:|---:|---|---|---|---|---|")
for p in order:
    for c, arm in [(c, arm) for c in "14" for arm in "cd"]:
        b, e = runs[(p, "s" + c)], runs[(p, arm + c)]
        w = lambda r: [int(x["duration_time"]) / 1e6 for x in r]
        cy = lambda r: st.median(int(x["cycles/u"]) + int(x["cycles/k"]) for x in r)
        rss = lambda r: st.median(int(x["rss_kb"]) for x in r)
        same = all(x["same"] == "1" for x in b + e)
        print(f"| {p} | {c} | {arm} | {st.median(w(b)):.1f} | {st.median(w(e)):.1f} | {pct(st.median(w(e)), st.median(w(b)))} | {pct(min(w(e)), min(w(b)))} | {pct(cy(e), cy(b), 'more', 'fewer')} | {pct(rss(e), rss(b))} | {'same' if same else 'DIFFER'} |")
