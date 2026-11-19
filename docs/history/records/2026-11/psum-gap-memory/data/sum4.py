import sys, statistics, collections
s = collections.defaultdict(list); chk = collections.defaultdict(set); order = []
for l in open(sys.argv[1]):
    k, cfg, arm, row, ns, c = l.split()
    s[cfg, row, arm].append(int(ns)); chk[cfg, row].add(c)
    if (cfg, row) not in order: order.append((cfg, row))
print("checks differ:", {k: v for k, v in chk.items() if len(v) != 1} or "none")
arms = sys.argv[2].split() if len(sys.argv) > 2 else ["main", "aa", "new", "rayon"]
print("| config | row | " + " | ".join(arms) + " | " + " | ".join(a + "/main" for a in arms[1:]) + " |")
for cfg, row in sorted(order):
    m = statistics.median(s[cfg, row, "main"])
    cell = lambda a: "%.3f (%.3f-%.3f)" % (statistics.median(s[cfg, row, a]) / 1e6, min(s[cfg, row, a]) / 1e6, max(s[cfg, row, a]) / 1e6) if s[cfg, row, a] else "-"
    print("| %s | %s | " % (cfg, row) + " | ".join(cell(a) for a in arms) + " | " + " | ".join(("%.3f" % (statistics.median(s[cfg, row, a]) / m)) if s[cfg, row, a] else "-" for a in arms[1:]) + " | n=%d" % len(s[cfg, row, "main"]))
