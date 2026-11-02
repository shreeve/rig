#!/usr/bin/env python3
"""time-ab-sum.py RUNS: summarize time-ab.sh's run lines by project and arm,
split by whether the Table huge-page gate was open (gate=1: more than 64
free 2 MiB blocks just before the run). The gate alone moves ts-pattern's
peak RSS by about 10 MiB, so a memory change is judged within one side of
the split, never across it.

For each project, arm and gate: the runs, the median of wall time, user
cycles, user instructions and peak RSS, the median free 2 MiB blocks, and
the median huge pages faulted in. A run whose output differs from its
arm's first (same=0) is left out. A run logged before time-ab.sh recorded
the gate counts under "?"."""
import sys
from collections import defaultdict
from statistics import median

FIELDS = [("duration_time", "wall ms", 1e-6), ("cycles/u", "cycles/u M", 1e-6),
          ("instructions/u", "instr/u M", 1e-6), ("rss_kb", "rss MiB", 1 / 1024)]

runs = defaultdict(list)
order = []
for line in open(sys.argv[1]):
    if line.startswith("#") or " round=" not in line:
        continue
    words = line.split()
    kv = dict(w.split("=", 1) for w in words[1:] if "=" in w)
    if kv.get("same") == "0":
        continue
    key = (words[0], kv["v"])
    if key not in order:
        order.append(key)
    runs[key + (kv.get("gate", "?"),)].append(kv)


def med(rows, k, scale, fmt="{:.2f}"):
    vals = [float(r[k]) for r in rows if k in r]
    return fmt.format(median(vals) * scale) if vals else "-"


head = ["project", "arm", "gate", "runs"] + [n for _, n, _ in FIELDS] + ["free 2M", "thp"]
print("| " + " | ".join(head) + " |")
print("|" + "---|" * len(head))
projs = list(dict.fromkeys(p for p, _ in order))
for proj, arm in sorted(order, key=lambda k: (projs.index(k[0]), k[1])):
    for gate, label in (("1", "open"), ("0", "shut"), ("?", "?")):
        rows = runs.get((proj, arm, gate))
        if not rows:
            continue
        cells = [proj, arm, label, str(len(rows))]
        cells += [med(rows, k, s) for k, _, s in FIELDS]
        cells += [med(rows, "huge2m", 1, "{:.0f}"), med(rows, "thp", 1, "{:.0f}")]
        print("| " + " | ".join(cells) + " |")
