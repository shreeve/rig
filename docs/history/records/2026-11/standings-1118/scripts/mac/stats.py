#!/usr/bin/env python3
import json, sys, statistics as st
for f in sys.argv[1:]:
    d = json.load(open(f))
    checks = {}
    for r, w, n, row, ns, c in d: checks.setdefault(row, set()).add(c)
    print("##", f.split("/")[-1], "checks", {k: sorted(v) for k, v in checks.items()})
    t = {}
    for r, w, n, row, ns, c in d: t[(w, row, n, r)] = ns / 1e6
    rounds = sorted({r for r, *_ in d})
    print("| row | workers | Rig median / fastest ms | Rayon median / fastest ms | Rig/Rayon paired median [range] | A/A rebuild [range] | A/A layout [range] | Rig wins |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for row in ("psum", "qsort"):
        for w in (1, 10):
            g = lambda n: [t[(w, row, n, r)] for r in rounds]
            rig, ray, aa, lay = g("rig"), g("rayon"), g("aa"), g("lay")
            rr = [a / b for a, b in zip(rig, ray)]
            ra = [a / b for a, b in zip(aa, rig)]
            rl = [a / b for a, b in zip(lay, rig)]
            fmt = lambda x: "%.3f [%.3f-%.3f]" % (st.median(x), min(x), max(x))
            wins = sum(1 for x in rr if x < 1)
            print("| %s | %d | %.2f / %.2f | %.2f / %.2f | %s | %s | %s | %d of %d |" % (
                row, w, st.median(rig), min(rig), st.median(ray), min(ray), fmt(rr), fmt(ra), fmt(rl), wins, len(rr)))
            print("<!-- lay med/fast %.2f/%.2f aa %.2f/%.2f -->" % (st.median(lay), min(lay), st.median(aa), min(aa)))
