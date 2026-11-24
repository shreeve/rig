#!/usr/bin/env python3
"""agg.py DIR: medians over the rounds batch.sh wrote (DIR/round*.json,
DIR/walls.txt), per stream and per project, and the projected gain."""
import glob, json, os, statistics, sys

d = sys.argv[1]
rounds = [json.load(open(f)) for f in sorted(glob.glob(os.path.join(d, "round*.json")))]
arms = rounds[0]["arms"]
traces = list(rounds[0]["traces"])
med = {t: {a: statistics.median(r["traces"][t]["ns"][a] for r in rounds) for a in arms} for t in traces}
ops = {t: rounds[0]["traces"][t]["ops"] for t in traces}
meta = {}
for t in traces:
    p = os.path.join(sys.argv[2], t + ".json") if len(sys.argv) > 2 else None
    meta[t] = json.load(open(p)) if p and os.path.exists(p) else {}

walls = {}
for line in open(os.path.join(d, "walls.txt")):
    f = line.split()
    walls.setdefault(f[0], []).append(float(f[3].split("=")[1]))

# The disjoint streams of each project: its five sites, and its top maps
# outside them (a site file that is a map file's copy stands in by the map).
DISJOINT = {
    "Compiler-Unions": ["site1", "site2", "site3", "site4", "site5"],
    "typeorm": ["site1", "site2", "map1", "site4", "site5", "map2", "map5"],
    "webpack": ["site1", "site2", "site3", "map1", "site5", "map3", "map4", "map5"],
    "supabase-studio": ["site1", "site2", "map4", "site4", "site5"],
}
COVER = {"Compiler-Unions": 0.791, "typeorm": 0.492, "webpack": 0.506, "supabase-studio": 0.577}

show = [a for a in arms if not a.endswith("'")]
w = 12
print(f"pup E-core 18, {len(rounds)} rounds: ns per op, median; ratio to rig-map")
print(f"{'stream':28} {'ops':>9} {'walks':>6} " + "".join(f"{a:>{w}}" for a in show))
for t in traces:
    m = meta.get(t, {})
    print(f"{t[:-4]:28} {ops[t]:9} {m.get('iter', '-'):>6} " + "".join(f"{med[t][a] / ops[t]:{w}.2f}" for a in show))
    print(f"{'':28} {'':9} {'':6} " + "".join(f"{med[t][a] / med[t]['rig-map']:{w - 1}.2f}x" for a in show))
aa = [abs(med[t]["hb-fx"] / med[t]["hb-fx'"] - 1) * 100 for t in traces if "hb-fx'" in arms]
if aa:
    print(f"\nA/A hb-fx vs hb-fx': median {statistics.median(aa):.1f}%, max {max(aa):.1f}% over streams")

print("\nper project: the disjoint streams; wall = b1r Trig at c1 on E-core 18, median of", {p: len(v) for p, v in walls.items()})
for p, names in DISJOINT.items():
    ts = [f"{p}/{n}.rpl" for n in names if f"{p}/{n}.rpl" in med]
    wall_ns = statistics.median(walls[p]) * 1e6 if p in walls else None
    tot = {a: sum(med[t][a] for t in ts) for a in show}
    print(f"\n{p}: {len(ts)} streams, {sum(ops[t] for t in ts)} ops, {COVER[p] * 100:.1f}% of keyed ops; wall {wall_ns / 1e6 if wall_ns else float('nan'):.1f} ms")
    for a in show:
        saved = tot["rig-map"] - tot[a]
        line = f"  {a:12} {tot[a] / 1e6:8.2f} ms replay"
        if wall_ns:
            line += f"   saved vs rig-map {saved / 1e6:+7.2f} ms = {saved / wall_ns * 100:+6.2f}% of wall; scaled to all keyed ops {saved / COVER[p] / wall_ns * 100:+6.2f}%"
        print(line)
