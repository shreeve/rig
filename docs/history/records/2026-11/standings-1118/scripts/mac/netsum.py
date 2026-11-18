#!/usr/bin/env python3
"""bb/netsum.py OUT [BASE] [--trips N]: per arm and benchmark: every round, median, min (µs a trip),
paired ratio to BASE (median [min-max]), and CPU and context switches a trip when the program ran one benchmark."""
import sys, json, statistics
CALLS = {"pingpong": 20000, "echo": 100000, "connect": 500}
args = [a for a in sys.argv[1:] if not a.startswith("--")]
trips = None
for a in sys.argv[1:]:
    if a.startswith("--trips="): trips = int(a.split("=")[1])
rows = [json.loads(l) for l in open(args[0])]
for r in rows:
    if "state" in r: print(("end " if r.get("end") else "start ") + r["at"] + " " + r["state"].strip().replace("\n", " |"))
rows = [r for r in rows if "arm" in r and "ns" in r]
arms = []
for r in rows:
    if r["arm"] not in arms: arms.append(r["arm"])
base = args[1] if len(args) > 1 else arms[0]
names = []
for r in rows:
    for n in r["ns"]:
        if n not in names: names.append(n)
def per(r, n):
    v = r["ns"][n]; k = trips or CALLS.get(n, 1)
    return sum(v) / len(v) / k / 1e3
for n in names:
    print("\n## %s (µs each)" % n)
    byround = {}
    for r in rows:
        if n in r["ns"]: byround.setdefault(r["round"], {})[r["arm"]] = per(r, n)
    print("| arm | median | min | max | /%s paired median [min-max] | rounds |" % base)
    print("|---|---:|---:|---:|---|---|")
    for a in arms:
        xs = [byround[k][a] for k in sorted(byround) if a in byround[k]]
        if not xs: continue
        ratios = [byround[k][a] / byround[k][base] for k in sorted(byround) if a in byround[k] and base in byround[k]]
        rt = "%.3f [%.3f-%.3f]" % (statistics.median(ratios), min(ratios), max(ratios)) if ratios else ""
        print("| %s | %.2f | %.2f | %.2f | %s | %s |" % (a, statistics.median(xs), min(xs), max(xs), rt, " ".join("%.2f" % x for x in xs)))
one = all(len(r["ns"]) == 1 for r in rows)
if one:
    n = names[0]
    print("\n## per trip, whole process (median): user µs, system µs, CPU µs, cores, voluntary csw, involuntary csw")
    print("| arm | user | sys | cpu | cores | vcsw | ivcsw |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for a in arms:
        rs = [r for r in rows if r["arm"] == a]
        k = lambda r: (trips or CALLS.get(n, 1)) * len(r["ns"][n])
        med = lambda f: statistics.median(f(r) for r in rs)
        print("| %s | %.2f | %.2f | %.2f | %.2f | %.3f | %.3f |" % (a, med(lambda r: r["user"] * 1e6 / k(r)), med(lambda r: r["sys"] * 1e6 / k(r)), med(lambda r: (r["user"] + r["sys"]) * 1e6 / k(r)), med(lambda r: (r["user"] + r["sys"]) / (sum(r["ns"][n]) / 1e9)), med(lambda r: r["vcsw"] / k(r)), med(lambda r: r["ivcsw"] / k(r))))
