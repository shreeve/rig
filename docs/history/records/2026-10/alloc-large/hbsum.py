#!/usr/bin/env python3
"""hbsum.py REPORT [BASE]: bench-hash's report summed as the prover's
table: each variant's time against BASE's, the geometric mean over a
group of rows (under 1.00 is faster), and every big row."""
import math, re, sys
lines = open(sys.argv[1]).read().splitlines()
head = lines[0].split()
vs = head[2:head.index("fastest")]
base = sys.argv[2] if len(sys.argv) > 2 else vs[0]
rows = {}
for l in lines[1:]:
    p = l.split()
    if len(p) < 2 + len(vs) or not re.match(r"^[a-z]+\d+$", p[0]): continue
    try: rows[(p[0], p[1])] = dict(zip(vs, map(float, p[2:2 + len(vs)])))
    except ValueError: pass
def group(k):
    n, op = k
    if n.startswith("big"): return "Big values: insert" if op == "insert" else "Big values: other"
    if n.startswith("str"): return "Text: insert, remove" if op in ("insert", "remove") else "Text: hit, miss"
    if re.search(r"(3000000|4000000)$", n): return "Int: 3M and 4M rows"
    if op in ("insert", "remove", "turnover", "half"): return "Int: insert, remove, turnover"
    return "Int: lookups, iterate"
groups = {}
for k in rows: groups.setdefault(group(k), []).append(k)
order = ["Int: insert, remove, turnover", "Int: lookups, iterate", "Int: 3M and 4M rows", "Text: insert, remove", "Text: hit, miss", "Big values: insert", "Big values: other"]
others = [v for v in vs if v != base]
print("| rows | n | " + " | ".join(v.split(":")[-1] for v in others) + " |")
print("|---|---:|" + "---:|" * len(others))
def gm(ks, v): return math.exp(sum(math.log(rows[k][v] / rows[k][base]) for k in ks) / len(ks))
for g in order + ["All"]:
    ks = list(rows) if g == "All" else groups.get(g, [])
    if not ks: continue
    print(f"| {g} | {len(ks)} | " + " | ".join(f"{gm(ks, v):.3f}" for v in others) + " |")
print()
print("| row | " + " | ".join(v.split(":")[-1] for v in vs) + " |")
print("|---|" + "---:|" * len(vs))
for k in rows:
    if k[0].startswith("big") or re.search(r"4000000$", k[0]):
        print(f"| {k[0]} {k[1]} | " + " | ".join(f"{rows[k][v]:.2f}" for v in vs) + " |")
print()
print("rows slower than BASE by more than 3%:")
for v in others:
    for k in rows:
        r = rows[k][v] / rows[k][base]
        if r > 1.03: print(f"  {v} {k[0]} {k[1]} {rows[k][base]:.2f} -> {rows[k][v]:.2f} ({(r-1)*100:.1f}% slower)")
