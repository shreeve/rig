#!/usr/bin/env python3
"""Interleaved board for the stable path against driftsort. Each outer
round runs every arm on every row in a fresh shuffled order; each run
prints its fastest of INNER rounds. A row's figure is the fastest of the
outer rounds, and the median beside it (ns per element).

dboard.py OUTER INNER OUT.tsv ARM=CMD... [--kinds k,..] [--sizes n,..] [--patterns p,..]

CMD is a command with {kind} {pat} {n} {inner} filled in, e.g.
  rust='rust/target/release/rsortbench {kind} {pat} {n} {inner} stable'
Rust's and Zig's kinds are int, str, rec; Rig's sint, sstr, rec: an
arm whose command starts with `rig:` maps int -> sint and str -> sstr
(the stable rows); one that starts with `rigu:` keeps the kind (`sort`,
the unstable rows).
"""
import random, statistics, subprocess, sys, time

args = sys.argv[1:]
opts = {"kinds": "rec,int,str", "sizes": "1024,4096,65536,1048576", "patterns": "rand,sorted,rev,dups"}
rest = []
while args:
    a = args.pop(0)
    if a.startswith("--"):
        opts[a[2:]] = args.pop(0)
    else:
        rest.append(a)
outer, inner, out = int(rest[0]), rest[1], rest[2]
arms = dict(a.split("=", 1) for a in rest[3:])
kinds = opts["kinds"].split(",")
sizes = [int(x) for x in opts["sizes"].split(",")]
pats = opts["patterns"].split(",")
RIGKIND = {"int": "sint", "str": "sstr", "rec": "rec", "reco": "reco"}


def cmd(arm, kind, pat, n):
    c = arms[arm]
    if c.startswith("rig:"):
        c, kind = c[4:], RIGKIND[kind]
    elif c.startswith("rigu:"):
        c = c[5:]
    elif kind == "reco":
        kind = "rec"
    return c.format(kind=kind, pat=pat, n=n, inner=inner).split()


vals = {}


def write():
    with open(out, "w") as f:
        f.write("kind\tpattern\tn\t" + "\t".join(f"{a}\t{a}-med" for a in arms) + "\n")
        for k in kinds:
            for p in pats:
                for n in sizes:
                    cells = []
                    for a in arms:
                        v = vals.get((k, p, n, a), [])
                        cells += [f"{min(v):.3f}" if v else "nan", f"{statistics.median(v):.3f}" if v else "nan"]
                    f.write(f"{k}\t{p}\t{n}\t" + "\t".join(cells) + "\n")


t0 = time.time()
for rnd in range(outer):
    jobs = [(a, k, p, n) for a in arms for k in kinds for p in pats for n in sizes]
    random.shuffle(jobs)
    for a, k, p, n in jobs:
        r = subprocess.run(cmd(a, k, p, n), capture_output=True, text=True)
        try:
            v = float(r.stdout.strip().split()[-1])
        except Exception:
            print("FAIL", a, k, p, n, r.stdout[-200:], r.stderr[-400:], file=sys.stderr)
            continue
        vals.setdefault((k, p, n, a), []).append(v)
    write()
    print(f"round {rnd + 1} done at {time.time() - t0:.0f}s", file=sys.stderr, flush=True)
print(open(out).read())
