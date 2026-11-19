import sys, statistics, collections
s = collections.defaultdict(list); chk = collections.defaultdict(set); arms = []
for l in open(sys.argv[1]):
    k, cfg, arm, row, ns, c = l.split()
    s[cfg, row, arm].append(int(ns)); chk[row].add(c)
    if arm not in arms: arms.append(arm)
base = sys.argv[2] if len(sys.argv) > 2 else arms[0]
print("checks", {r: sorted(v) for r, v in chk.items()})
for cfg in ("w1", "w12"):
    for row in ("psum", "qsort"):
        b = statistics.median(s[cfg, row, base])
        for a in arms:
            v = s[cfg, row, a]; m = statistics.median(v)
            print("%-4s %-5s %-10s n=%2d %8.2f ms (%.2f-%.2f)  %s/%s %.3f" % (cfg, row, a, len(v), m / 1e6, min(v) / 1e6, max(v) / 1e6, a, base, m / b))
