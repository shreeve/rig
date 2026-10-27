#!/usr/bin/env python3
"""hbab.py REPS NAME=EXE ...: bench/hash's rig-fast programs, each built by
another Rig, run interleaved REPS times (the order reversed every other
round), the fastest of each row; and each one's peak bytes an entry for
one map of 4,000,000 Int keys (`mem` less `mem0`, the least of REPS).
Prints each build's time against the first's, the geometric mean over
hbsum.py's groups of rows (under 1.00 is faster), the big and 4M rows,
and every row over 3% slower. With PIN="taskset -c 6" each run is pinned."""
import math, os, re, shlex, subprocess, sys
reps = int(sys.argv[1])
specs = [a.split("=", 1) for a in sys.argv[2:]]
pin = shlex.split(os.environ.get("PIN", ""))
def run(exe):
    p = subprocess.run(pin + [exe], check=True, capture_output=True, text=True)
    rows = {}
    for line in (p.stdout + p.stderr).splitlines():
        keys, op, ns, check = line.split()
        rows[(keys, op)] = (int(ns), check)
    return rows
def peak(exe, arg):
    p = subprocess.Popen(pin + [exe, arg], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, status, use = os.wait4(p.pid, 0)
    if status != 0: sys.exit(f"{exe} {arg}: exit status {status}")
    return use.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
best, mem, checks = {}, {}, {}
for r in range(reps):
    for name, exe in (specs if r % 2 == 0 else specs[::-1]):
        for k, (ns, c) in run(exe).items():
            if checks.setdefault(k, c) != c: sys.exit(f"checksums differ: {k} {name}")
            best.setdefault(name, {})[k] = min(ns, best.get(name, {}).get(k, ns))
        b = (peak(exe, "mem") - peak(exe, "mem0")) / 4_000_000
        mem[name] = min(b, mem.get(name, b))
    print(f"round {r + 1}", file=sys.stderr, flush=True)
names = [n for n, _ in specs]
base, others = names[0], names[1:]
rows = [k for k in best[base] if all(k in best[n] for n in names)]
def group(k):
    n, op = k
    if n.startswith("big"): return "Big values: insert" if op == "insert" else "Big values: other"
    if n.startswith("str"): return "Text: insert, remove" if op in ("insert", "remove") else "Text: hit, miss"
    if re.search(r"(3000000|4000000)$", n): return "Int: 3M and 4M rows"
    if op in ("insert", "remove", "turnover", "half"): return "Int: insert, remove, turnover"
    return "Int: lookups, iterate"
order = ["Int: insert, remove, turnover", "Int: lookups, iterate", "Int: 3M and 4M rows", "Text: insert, remove", "Text: hit, miss", "Big values: insert", "Big values: other"]
def gm(ks, n): return math.exp(sum(math.log(best[n][k] / best[base][k]) for k in ks) / len(ks))
print("| bytes an entry, 4M Int keys | " + " | ".join(names) + " |")
print("|---|" + "---:|" * len(names))
print("| peak RSS, mem less mem0 | " + " | ".join(f"{mem[n]:.1f}" for n in names) + " |")
print()
print("| rows | n | " + " | ".join(others) + " |")
print("|---|---:|" + "---:|" * len(others))
for g in order + ["All"]:
    ks = rows if g == "All" else [k for k in rows if group(k) == g]
    if ks: print(f"| {g} | {len(ks)} | " + " | ".join(f"{gm(ks, n):.3f}" for n in others) + " |")
print()
print("| row (ns) | " + " | ".join(names) + " |")
print("|---|" + "---:|" * len(names))
for k in rows:
    if k[0].startswith("big") or re.search(r"4000000$", k[0]):
        print(f"| {k[0]} {k[1]} | " + " | ".join(f"{best[n][k] / 1e6:.2f}" for n in names) + " |")
print()
print(f"rows slower than {base} by more than 3%:")
for n in others:
    for k in rows:
        r = best[n][k] / best[base][k]
        if r > 1.03: print(f"  {n} {k[0]} {k[1]} {best[base][k] / 1e6:.2f} -> {best[n][k] / 1e6:.2f} ({(r - 1) * 100:.1f}% slower)")
