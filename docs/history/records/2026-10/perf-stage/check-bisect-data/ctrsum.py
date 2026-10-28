#!/usr/bin/env python3
"""ctrsum.py CTR BASE: each counter's median per variant, as a change
against BASE (negative: fewer), per project."""
import sys, collections, statistics
d = collections.defaultdict(list); vs = []
for l in open(sys.argv[1]):
    f = l.split(); p = f[0]; v = f[2][2:]; k, val = f[3].split("=")
    if v not in vs: vs.append(v)
    d[(p, v, k.split("/")[1])].append(float(val))
base = sys.argv[2]
for p in ("ts-pattern", "zod3"):
    ks = sorted(set(k for (pp, v, k) in d if pp == p))
    print(f"\n{p}\n| counter | {base} | " + " | ".join(v for v in vs if v != base) + " |")
    print("|---" * (len(vs) + 1) + "|")
    for k in ks:
        m = statistics.median(d[(p, base, k)])
        print(f"| {k} | {m/1e6:.1f}M | " + " | ".join(f"{100*(statistics.median(d[(p, v, k)])/m-1):+.1f}%" for v in vs if v != base) + " |")
