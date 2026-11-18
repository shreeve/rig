#!/usr/bin/env python3
"""board.py ROUNDS OUT.json: rig (main), aa (rebuild), lay (layout control),
rayon; workers 1 and 10; rotated turns each round. Each run prints psum and
qsort rows; a JSON of every sample is written to OUT."""
import subprocess, sys, json, os, time
S = os.path.dirname(os.path.abspath(__file__))
progs = {"rig": S + "/rig_main", "aa": S + "/rig_aa", "lay": S + "/rig_lay",
         "rayon": S + "/rayon/target/release/fork-rayon"}
rounds, out = int(sys.argv[1]), sys.argv[2]
names = list(progs)
data = []  # (round, workers, prog, row, ns, check)
print("start", time.strftime("%H:%M:%S"), subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(), flush=True)
print(subprocess.run("ps -Ao pcpu,comm -r | head -8", shell=True, capture_output=True, text=True).stdout, flush=True)
for k in range(rounds):
    ws = [1, 10] if k % 2 == 0 else [10, 1]
    line = []
    for w in ws:
        turn = names[k % 4:] + names[:k % 4]
        env = dict(os.environ, RIG_WORKERS=str(w), RAYON_NUM_THREADS=str(w))
        for n in turn:
            o = subprocess.run([progs[n]], capture_output=True, text=True, timeout=600, check=True, env=env).stdout
            for row in o.splitlines():
                name, ns, chk = row.split()
                data.append((k + 1, w, n, name, int(ns), chk))
                line.append("%s/%d %s %.2f" % (n, w, name, int(ns) / 1e6))
    print("round %d: %s" % (k + 1, ", ".join(line)), flush=True)
print("end", time.strftime("%H:%M:%S"), subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(), flush=True)
json.dump(data, open(out, "w"))
