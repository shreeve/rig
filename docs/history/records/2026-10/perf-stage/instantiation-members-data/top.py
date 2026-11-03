import json, sys, collections
p, fam_ = sys.argv[1], sys.argv[2]; n = int(sys.argv[3]) if len(sys.argv) > 3 else 22
o = json.load(open("%s.fam2.json" % p))
a = collections.Counter({k: x for f, k, x in o["trig"]["nearfn"] if f == fam_}); b = collections.Counter({k: x for f, k, x in o["tsrs"]["nearfn"] if f == fam_})
print("%s %s: Trig %.0f tsrs %.0f" % (p, fam_, sum(a.values()), sum(b.values())))
for k in sorted(set(a) | set(b), key=lambda k: -max(a[k], b[k]))[:n]:
    print("  %7.1f %7.1f %+7.1f  %s   incl %.0f / %.0f" % (a[k], b[k], a[k] - b[k], k, o["trig"]["incl"].get(k, 0), o["tsrs"]["incl"].get(k, 0)))
