"""time.py's method (calibrate to ~MS ms, interleave REPS rounds, same order), keeping every sample."""
import json, os, sys
sys.argv = [sys.argv[0], sys.argv[1], "1"] + sys.argv[3:] if False else sys.argv
W = os.environ["WT"]
sys.path.insert(0, os.path.join(W, "bench/json/timers"))
variants = sys.argv[1].split(","); reps = int(sys.argv[2]); outp = sys.argv[3]
# import time.py's helpers without running its main body
src = open(os.path.join(W, "bench/json/timers/time.py")).read()
head = src.split("size = {f:")[0].replace("variants = sys.argv[1]", "variants = VARIANTS").replace("reps = int(sys.argv[2]) if len(sys.argv) > 2 else 7", "reps = REPS")
g = {"__file__": os.path.join(W, "bench/json/timers/time.py"), "VARIANTS": sys.argv[1], "REPS": reps}
exec(head, g)
FILES, run, DATA, MS = g["FILES"], g["run"], g["DATA"], g["MS"]
size = {f: os.path.getsize(os.path.join(DATA, f + ".json")) for f in FILES}
counts = {}
for f in FILES:
    for v in variants:
        run(f, v, 2)
        ns, _ = run(f, v, 3)
        counts[f, v] = max(2, int(MS * 1e6 / max(ns / 3, 1)))
samples = {}
for r in range(reps):
    for f in FILES:
        for v in variants:
            n = counts[f, v]
            samples.setdefault(f + "|" + v, []).append(run(f, v, n)[0] / n)
    json.dump({"size": size, "counts": {k[0]+"|"+k[1]: c for k, c in counts.items()}, "samples": samples, "rounds": r + 1}, open(outp, "w"))
print("done", reps, "rounds")
