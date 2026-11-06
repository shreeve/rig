#!/usr/bin/env python3
# time-trig.py ROUNDS MODE OUT.csv ARM=BIN...: interleaved, shuffled per round
import os, random, re, subprocess, sys, time, hashlib
S = os.path.dirname(os.path.abspath(__file__))
rounds = int(sys.argv[1]); mode = sys.argv[2]; out = sys.argv[3]
arms = [a.split("=", 1) for a in sys.argv[4:]]
projects = os.environ.get("PROJECTS", "mitt,neverthrow,tiny-invariant,superstruct,zod3,ts-pattern").split(",")
extra = ["--singleThreaded"] if mode == "1" else []
f = open(out, "a")
digests = {}
def load():
    return os.getloadavg()[0]
for r in range(rounds):
    for p in projects:
        order = arms[:]
        random.shuffle(order)
        for name, b in order:
            cmd = ["/usr/bin/time", "-l", b, "-p", "tsconfig.trig.json", "--noEmit"] + extra
            l = load()
            t0 = time.perf_counter()
            pr = subprocess.run(cmd, cwd=os.path.join(S, "projects", p), capture_output=True, timeout=120)
            w = (time.perf_counter() - t0) * 1000
            err = pr.stderr.decode()
            def g(pat):
                m = re.search(r"(\d+)\s+" + pat, err)
                return int(m.group(1)) if m else -1
            ins, cyc, rss, foot = g("instructions retired"), g("cycles elapsed"), g("maximum resident set size"), g("peak memory footprint")
            d = hashlib.sha1(pr.stdout + bytes([pr.returncode & 255])).hexdigest()[:12]
            digests.setdefault(p, {}).setdefault(name, set()).add(d)
            f.write(f"{mode},{r},{p},{name},{w:.3f},{cyc},{ins},{rss},{foot},{pr.returncode},{d},{l:.2f}\n"); f.flush()
    print(f"round {r} done, load {load():.2f}", flush=True)
for p, m in digests.items():
    print(p, {k: sorted(v) for k, v in m.items()})
