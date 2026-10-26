import re, sys
best = {}; cur = None
for line in open(sys.argv[1]):
    m = re.match(r"== (\S+) (\S+) round", line)
    if m: cur = (m.group(1), m.group(2)); continue
    if cur is None: continue
    b, n = cur
    if b == "json":
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(c) == 4 and c[1].isdigit():
            for v, x in (("safe", c[2]), ("fast", c[3])):
                k = ("json", c[0] + " " + v, n); best[k] = max(best.get(k, 0), int(x))
    else:
        m = re.match(r"(\S+)\s+(\S+(?:\s\d+)?)\s+([\d.]+)\s+([\d.]+)", line)
        if m and m.group(1) in ("int","string","pair","small"):
            for v, x in (("safe", m.group(3)), ("fast", m.group(4))):
                k = ("hash", m.group(1)+" "+m.group(2)+" "+v, n); best[k] = min(best.get(k, 1e9), float(x))
rows = sorted({(k[0], k[1]) for k in best}, key=lambda r: list((k[0],k[1]) for k in best).index(r))
print("| bench | case | base | branch | branch vs base |"); print("|---|---|---:|---:|---|")
for b, c in rows:
    x, y = best[(b, c, "base")], best[(b, c, "br")]
    if b == "json": d = (y / x - 1) * 100; w = "%.1f%% %s" % (abs(d), "faster" if d > 0 else "slower") if abs(d) >= 0.05 else "same"
    else: d = (x / y - 1) * 100; w = "%.1f%% %s" % (abs(d), "faster" if d > 0 else "slower") if abs(d) >= 0.05 else "same"
    print("| %s | %s | %s | %s | %s |" % (b, c, x, y, w))
