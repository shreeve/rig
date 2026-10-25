import re, sys
best = {}; cur = None; order = []; builds = []
lower_better = True
for line in open(sys.argv[1]):
    m = re.match(r"== (\S+) (\S+) round", line)
    if m:
        cur = (m.group(1), m.group(2))
        if m.group(2) not in builds: builds.append(m.group(2))
        continue
    if cur is None or cur[0] == "json": continue
    m = re.match(r"(\w+)\s+([\d.]+) (\S+)", line)
    if m and m.group(1) not in ("rig-fast",):
        name = m.group(1).strip(); v = float(m.group(2)); unit = m.group(3)
        k = (cur[0], name)
        if k not in order: order.append(k)
        hib = "req/s" in unit
        d = best.setdefault(k, {"unit": unit, "hib": hib})
        if cur[1] not in d: d[cur[1]] = v
        else: d[cur[1]] = max(d[cur[1]], v) if hib else min(d[cur[1]], v)
print("| bench | case | unit | " + " | ".join(builds) + " | i1 vs base | both vs base |")
print("|---|---|---|" + "---:|" * (len(builds) + 2))
for k in order:
    d = best[k]
    def rel(b):
        r = d[b] / d["base"]
        return "%.1f%% %s" % (abs(r - 1) * 100, ("faster" if (r > 1) == d["hib"] else "slower")) if r != 1 else "same"
    print("| %s | %s | %s | " % (k[0], k[1], d["unit"]) + " | ".join("%g" % d[b] for b in builds) + " | %s | %s |" % (rel("i1"), rel("both")))
