#!/usr/bin/env python3
"""Split failing packed programs into one program per case.
Usage: split.py <module> <root> <seed>"""
import importlib, json, os, random, sys

mod = importlib.import_module(sys.argv[1])
root = sys.argv[2]
seed = int(sys.argv[3])
out = root + "_split"
os.makedirs(out, exist_ok=True)
bad = set()
for l in open(os.path.join(root, "results.jsonl")):
    r = json.loads(l)
    if r["outcome"] not in ("ok", "rejected", "ok_panic"):
        bad.add(r["id"])
n = 0
for pid in sorted(bad):
    exp = json.load(open(os.path.join(root, pid, "expect.json")))
    for i in exp.get("cases", []):
        rr = random.Random(seed * 1000003 + i)
        decls, sub, o = mod.make_case(rr, i)
        src = "\n".join(mod.PRELUDE + decls) + "\n" + sub + "\nsub main\n  t%d()\n" % i
        d = os.path.join(out, "s%05d" % i)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        json.dump({"kind": "out", "out": "\n".join(o) + "\n", "area": sys.argv[1], "from": pid},
                  open(os.path.join(d, "expect.json"), "w"))
        n += 1
print("split", len(bad), "programs into", n, "cases")
