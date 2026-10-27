import subprocess, sys, collections
# ab.py N EXE...: run each EXE N times interleaved; per EXE and benchmark, the fastest ns; checks must agree.
n = int(sys.argv[1]); exes = sys.argv[2:]
best = collections.defaultdict(dict); checks = {}
for i in range(n):
    for e in exes:
        out = subprocess.run(["taskset", "-c", "6-9", e], check=True, capture_output=True, text=True).stdout
        for line in out.split("\n"):
            f = line.split()
            if len(f) < 3: continue
            name, ns, chk = f[0], float(f[1]), f[2]
            if checks.setdefault(name, chk) != chk: print("CHECK DIFFERS", e, name)
            best[e][name] = min(best[e].get(name, 1e30), ns)
names = list(best[exes[0]].keys())
print("%-10s" % "bench" + "".join("%26s" % e.split("/")[-2] + "/" + e.split("/")[-1] for e in exes))
for nm in names:
    print("%-10s" % nm + "".join("%26.1f" % best[e][nm] for e in exes))
