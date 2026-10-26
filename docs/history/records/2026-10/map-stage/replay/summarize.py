#!/usr/bin/env python3
"""summarize.py FILE...: the fastest of each (label, design) by cycles,
from bench.sh's lines, dropping runs whose sibling core was over 5% busy,
with the median of the per-round differences against `today`."""
import re, sys, collections, statistics
runs = collections.defaultdict(list)   # (label, design) -> [(round, cycles, instr, ns, peak)]
dropped = 0; total = 0
for path in sys.argv[1:]:
    for line in open(path):
        m = re.search(r"^(\S+) round=(\d+) design=(\S+) sibling_busy=([\d.]+) RESULT .*cycles=(\d+) instructions=(\d+) ns=(\d+) mismatches=(\d+) peak_bytes=(\d+)", line)
        if not m: continue
        total += 1
        label, rnd, d, sib, cyc, ins, ns, mis, peak = m.groups()
        assert mis == "0", line
        if float(sib) > 0.05: dropped += 1; continue
        runs[(label, d)].append((int(rnd), int(cyc), int(ins), int(ns), int(peak)))
print(f"{total} runs, {dropped} dropped for a busy sibling")
labels = sorted({l for l, _ in runs})
for label in labels:
    print(f"\n{label}")
    base = {r: c for r, c, *_ in runs.get((label, "today"), [])}
    noop = min((c for _, c, *_ in runs.get((label, "noop"), [])), default=None)
    print(f"  {'design':<11} {'n':>3} {'cycles (min)':>14} {'instr (min)':>14} {'ms (min)':>9} {'peak MB':>8} {'vs today':>10} {'median diff':>12} {'less noop':>11}")
    t = min((c for _, c, *_ in runs.get((label, "today"), [])), default=None)
    for (l, d), rs in sorted(runs.items(), key=lambda e: e[0][1]):
        if l != label: continue
        c = min(x[1] for x in rs); i = min(x[2] for x in rs); ns = min(x[3] for x in rs); pk = rs[0][4]
        diffs = [x[1] - base[x[0]] for x in rs if x[0] in base]
        md = statistics.median(diffs) / 1e6 if diffs and d != "today" else 0
        vs = f"{(c - t) / 1e6:+.1f}M" if t else "-"
        ln = f"{(c - noop) / 1e6:.1f}M" if noop is not None else "-"
        print(f"  {d:<11} {len(rs):>3} {c / 1e6:>13.1f}M {i / 1e6:>13.1f}M {ns / 1e6:>9.1f} {pk / 1e6:>8.1f} {vs:>10} {md:>+11.1f}M {ln:>11}")
