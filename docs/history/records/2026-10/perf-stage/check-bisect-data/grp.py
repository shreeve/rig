#!/usr/bin/env python3
"""grp.py BASE.syms:CYCLES V.syms:CYCLES ...: each profile's samples by
function group (the groups of the bisect), as cycles (the share of the
run's measured cycles), and each variant's cycles against the first."""
import sys, json, collections, os
W = os.path.dirname(os.path.abspath(__file__))
store = set(json.load(open(os.path.join(W, "groups", "g-store.json") if os.path.exists(os.path.join(W, "groups")) else os.path.join(W, "g-store.json")))["checker.zig"])
def group(s):
    if s.startswith("checker."):
        n = s.split(".")[-1].split("__")[0]
        return "store" if n in store else "checker"
    for p, g in (("ast.", "ast"), ("parser.", "ast"), ("lexer.", "ast"), ("binder.", "binder"),
                 ("rig.ordered", "map"), ("rig.unordered", "map"), ("rig.", "runtime"), ("[unknown]", "unknown")):
        if s.startswith(p): return g
    return "other"
res = []
for a in sys.argv[1:]:
    f, cyc = a.rsplit(":", 1)
    c = collections.Counter(group(l.strip()) for l in open(f) if l.strip())
    tot = sum(c.values())
    res.append((f, float(cyc), {g: n / tot for g, n in c.items()}))
gs = sorted(set(g for _, _, d in res for g in d), key=lambda g: -res[0][2].get(g, 0))
print("| group | " + " | ".join(f"{os.path.basename(f)} share" for f, _, _ in res) + " | " + " | ".join(f"{os.path.basename(f)} cycles saved, % of base" for f, _, _ in res[1:]) + " |")
print("|---" * (1 + 2 * len(res) - 1) + "|")
b = res[0]
for g in gs:
    row = [g] + [f"{100*d.get(g,0):.1f}%" for _, _, d in res]
    row += [f"{100*(b[1]*b[2].get(g,0) - c*d.get(g,0))/b[1]:.2f}%" for _, c, d in res[1:]]
    print("| " + " | ".join(row) + " |")
