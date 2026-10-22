#!/usr/bin/env python3
"""Generate cases one by one, check each standalone, pack the accepted ones
into programs. Usage: casepack.py <module> <outroot> <ncases> <seed> [per_prog]"""
import importlib, json, os, random, subprocess, sys, collections, re
from multiprocessing import Pool

RIG = "/Users/shreeve/Data/Code/rig/bin/rig"
mod = importlib.import_module(sys.argv[1])
root = sys.argv[2]
N = int(sys.argv[3]); seed = int(sys.argv[4]); per = int(sys.argv[5]) if len(sys.argv) > 5 else 12
os.makedirs(root, exist_ok=True)
tmp = os.path.join(root, ".chk"); os.makedirs(tmp, exist_ok=True)


def mk(i):
    r = random.Random(seed * 1000003 + i)
    decls, sub, out = mod.make_case(r, i)
    return i, decls, sub, out


def chk(args):
    i, decls, sub, out = args
    src = "\n".join(mod.PRELUDE + decls) + "\n" + sub + "\nsub main\n  t%d()\n" % i
    f = os.path.join(tmp, "c%d.rig" % i)
    open(f, "w").write(src)
    p = subprocess.run([RIG, "check", f], capture_output=True, timeout=30)
    err = p.stderr.decode("utf8", "replace")
    return i, decls, sub, out, p.returncode, err, src


if __name__ == "__main__":
    cases = [mk(i) for i in range(N)]
    acc, rej = [], collections.Counter()
    rejlog = open(os.path.join(root, "rejected.txt"), "w")
    crash = open(os.path.join(root, "check_crash.txt"), "w")
    with Pool(10) as p:
        for i, decls, sub, out, rc, err, src in p.imap_unordered(chk, cases, chunksize=10):
            if rc == 0:
                acc.append((i, decls, sub, out))
            elif re.search(r"\.rig:\d+:\d+: error:", err) and rc == 1 and "internal error" not in err \
                    and not re.search(r"^thread \d+ panic", err, re.M):
                m = re.search(r"error: (.*)", err)
                key = re.sub(r"`[^`]*`", "X", m.group(1))
                rej[key] += 1
                rejlog.write("=" * 60 + "\n" + src + "\n--\n" + err[:1500] + "\n")
            else:
                crash.write("=" * 60 + "\n" + src + "\n--\n" + err[-3000:] + "\n")
    acc.sort()
    print("accepted", len(acc), "rejected", sum(rej.values()))
    for k, v in rej.most_common(25):
        print(" ", v, k)
    r = random.Random(seed)
    r.shuffle(acc)
    for pi in range(0, len(acc), per):
        group = acc[pi:pi + per]
        decls = list(mod.PRELUDE)
        subs, calls, out = [], [], []
        for i, d, sub, o in group:
            decls += d
            subs.append(sub)
            calls.append("  t%d()" % i)
            out += o
        src = "\n".join(decls) + "\n" + "\n".join(subs) + "\nsub main\n" + "\n".join(calls) + "\n"
        d = os.path.join(root, "p%05d" % (pi // per))
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "main.rig"), "w").write(src)
        json.dump({"kind": "out", "out": "\n".join(out) + "\n", "area": sys.argv[1],
                   "cases": [g[0] for g in group]}, open(os.path.join(d, "expect.json"), "w"))
