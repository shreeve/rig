# fam2.py PROJECT TRIG_MCYC TSRS_MCYC: families by source function (inline
# frames from chains.py), both builds. "source-self" is the innermost source
# function's family; "nearest-named" walks out from the leaf to the first
# frame in a named checker family, so code inlined differently, or library
# code called for it, counts to the family it serves.
import sys, json, re, collections, os
H = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(H, "fam.py")).read().split("def load(v):")[0])
p, tc, sc = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
NAMED = [a for a, _ in AREAS]
CR = {"tsrs_scanner": "lex", "tsrs_parser": "parse", "tsrs_binder": "bind", "tsrs_ast": "ast (tree access, parents)"}
ALLOC = re.compile(r"rig\.alloc|compiler_rt\.mem|memcpy|memmove|memset|mi_|malloc|\bfree|__mem|dealloc|realloc")
def clean(n): return re.sub(r"__func_\d+|__struct_\d+", "", n)
def fam(e, trig):
    name, crate = clean(e[0]), e[1]
    if crate == "lib": return "alloc + memcpy" if ALLOC.search(name) else "runtime/std (maps, hash, interner)"
    if trig: return family(name, True)
    if crate in CR: return CR[crate]
    if crate != "tsrs_checker": return "program, paths, output"
    m = name.split("<")[0] if not name.startswith("<") else name
    m = method(m)
    for a, pat in AREAS:
        if re.search(pat, m): return a
    return "check: other"
def key(e): return clean(e[0]).split("<")[0].split("::")[-1].split(".")[-1] if not e[0].startswith("<") else clean(e[0]).split("::")[-1]
out = {}
for v, cyc in (("trig", tc), ("tsrs", sc)):
    d = json.load(open(os.path.join(H, "%s.%s.json" % (p, v)))); trig = v == "trig"
    tot = sum(x for x, _ in d)
    selfc, near, fself, incl, nearfn = (collections.Counter() for _ in range(5))
    for per, frames in d:
        leaf = frames[0][0] if frames and frames[0] else ["?", "?"]
        lf = fam(leaf, trig); selfc[lf] += per; fself[(lf, key(leaf) if leaf[1] != "lib" or trig else "lib:" + key(leaf))] += per
        nf = None
        for f in frames:
            for e in f:
                g = fam(e, trig)
                if g in NAMED: nf = g; nearfn[(g, key(e))] += per; break
            if nf: break
        near[nf or lf] += per
        seen = set()
        for f in frames:
            for e in f:
                if e[1] == "lib": continue
                k = key(e)
                if k not in seen: seen.add(k); incl[k] += per
    s_ = lambda x: x / tot * cyc
    out[v] = dict(self={k: s_(x) for k, x in selfc.items()}, near={k: s_(x) for k, x in near.items()},
                  fself=[[k[0], k[1], s_(x)] for k, x in fself.most_common(600)],
                  nearfn=[[k[0], k[1], s_(x)] for k, x in nearfn.most_common(600)],
                  incl={k: s_(x) for k, x in incl.most_common(4000)}, samples=len(d))
json.dump(out, open(os.path.join(H, "%s.fam2.json" % p), "w"))
print("%s: samples Trig %d, tsrs %d; Mcycles a run Trig %.0f, tsrs %.0f" % (p, out["trig"]["samples"], out["tsrs"]["samples"], tc, sc))
print("| family | Trig source-self | tsrs source-self | Trig nearest-named | tsrs nearest-named | nearest gap, % of Trig |")
print("|---|---:|---:|---:|---:|---:|")
ks = set(out["trig"]["near"]) | set(out["tsrs"]["near"]) | set(out["trig"]["self"]) | set(out["tsrs"]["self"])
for k in sorted(ks, key=lambda k: -(out["trig"]["near"].get(k, 0) - out["tsrs"]["near"].get(k, 0))):
    a, b = out["trig"]["self"].get(k, 0), out["tsrs"]["self"].get(k, 0); c, d_ = out["trig"]["near"].get(k, 0), out["tsrs"]["near"].get(k, 0)
    print("| %s | %.0f | %.0f | %.0f | %.0f | %+.1f%% |" % (k, a, b, c, d_, 100 * (c - d_) / tc))
