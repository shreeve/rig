import re, sys
best = {}; builds = []
cur = None
for line in open(sys.argv[1]):
    m = re.match(r"== (\S+)", line)
    if m:
        cur = m.group(1); builds.append(cur) if cur not in builds else None; continue
    c = [x.strip() for x in line.strip().strip("|").split("|")]
    if len(c) == 4 and c[1].isdigit():
        for v, x in (("safe", c[2]), ("fast", c[3])):
            k = (c[0], v, cur); best[k] = max(best.get(k, 0), int(x))
files = sorted({k[0] for k in best}, key=lambda f: list(k[0] for k in best).index(f))
print("| file | mode | " + " | ".join(builds) + " | " + " | ".join("%s vs base" % b for b in builds[1:]) + " |")
print("|---|---|" + "---:|" * (2 * len(builds) - 1))
for f in files:
    for v in ("safe", "fast"):
        b0 = best[(f, v, "base")]
        print("| %s | %s | " % (f, v) + " | ".join(str(best[(f, v, b)]) for b in builds) + " | " + " | ".join("%+.1f%%" % ((best[(f, v, b)] / b0 - 1) * 100) for b in builds[1:]) + " |")
