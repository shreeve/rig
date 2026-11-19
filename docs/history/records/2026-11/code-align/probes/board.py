#!/usr/bin/env python3
"""board.py ROUNDS WORKERS OUT.json NAME=PROG...: run every program each
round in rotating order, at each worker count in WORKERS (comma list,
order alternating by round), keeping every output line; checks each
program's sums (psum, qsort) against the first seen. Run it inside
tools/mac-claim."""
import json, os, subprocess, sys, time
rounds, workers, out = int(sys.argv[1]), [int(w) for w in sys.argv[2].split(",")], sys.argv[3]
progs = dict(a.split("=", 1) for a in sys.argv[4:])
names = list(progs)
data, sums = [], {}
def state(tag):
    print(tag, time.strftime("%H:%M:%S"), subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(), flush=True)
state("start")
for k in range(rounds):
    ws = workers if k % 2 == 0 else workers[::-1]
    for w in ws:
        r = k % len(names)
        env = dict(os.environ, RIG_WORKERS=str(w))
        for n in names[r:] + names[:r]:
            o = subprocess.run([progs[n]], capture_output=True, text=True, timeout=600, check=True, env=env).stdout
            for l in o.splitlines():
                p = l.split()
                if len(p) == 3:
                    if sums.setdefault(p[0], p[2]) != p[2]:
                        sys.exit("bad sum: %s %s %s" % (n, l, sums[p[0]]))
            data.append((k + 1, w, n, o.splitlines()))
    json.dump(data, open(out, "w"))
state("end")
print("sums", sums)
