import sys, statistics, collections
t = collections.defaultdict(list); c = collections.defaultdict(lambda: collections.defaultdict(list)); chk = collections.defaultdict(set)
for line in open(sys.argv[1]):
    k, name, res, cnt = line.rstrip("\n").split("|")
    for r in res.split():
        f = r.split(":")
        if len(f) == 2: t[name].append(int(f[0])); chk["bw"].add(f[1])
        else: t[name + " " + f[0]].append(int(f[1])); chk[f[0]].add(f[2])
    for kv in cnt.split():
        if "=" not in kv: continue
        key, v = kv.split("=")
        if v.isdigit() and "atom" not in key: c[name][key.replace("cpu_core/", "").strip("/")].append(int(v))
print("checks", {k: sorted(v) for k, v in chk.items()})
mb = (1 << 25) * 8 / 1e6
for name in sorted(t):
    v = t[name]; m = statistics.median(v)
    gbs = " %.1f GB/s" % (mb / (m / 1e6)) if "qsort" not in name else ""
    print("%-28s n=%2d median %8.2f ms (%.2f-%.2f)%s" % (name, len(v), m / 1e6, min(v) / 1e6, max(v) / 1e6, gbs))
for name in sorted(c):
    print("%-16s " % name + "  ".join("%s %s" % (k, "{:,}".format(int(statistics.median(v)))) for k, v in sorted(c[name].items())))
