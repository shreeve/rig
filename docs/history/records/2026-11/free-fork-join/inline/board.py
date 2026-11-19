#!/usr/bin/env python3
"""board.py ROUNDS OUT.json NAME=PROG...: each round runs every program at
each worker count in WORKERS (default "1 10"), the counts alternating in
order and the programs rotating. Each program prints `ROW NS CHECK` lines;
peak RSS comes from /usr/bin/time -l. Samples go to OUT.json."""
import json, os, re, subprocess, sys, time
rounds, out = int(sys.argv[1]), sys.argv[2]
progs = dict(a.split("=", 1) for a in sys.argv[3:])
names = list(progs)
counts = [int(x) for x in os.environ.get("WORKERS", "1 10").split()]
data = []
print("start", time.strftime("%H:%M:%S"), subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(), flush=True)
for k in range(rounds):
    order = counts if k % 2 == 0 else counts[::-1]
    for w in order:
        r = k % len(names)
        env = dict(os.environ, RIG_WORKERS=str(w), RAYON_NUM_THREADS=str(w), CEIL_WORKERS=str(w)) if w else dict(os.environ)
        for n in names[r:] + names[:r]:
            p = subprocess.run(["/usr/bin/time", "-l", progs[n]], capture_output=True, text=True, timeout=600, env=env)
            if p.returncode != 0:
                sys.exit("%s/%d failed: %s" % (n, w, p.stderr[-2000:]))
            m = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
            rss = int(m.group(1)) if m else 0
            for row in p.stdout.splitlines():
                parts = row.split()
                if len(parts) != 3 or not parts[1].isdigit():
                    continue
                data.append((k + 1, w, n, parts[0], int(parts[1]), parts[2], rss))
    print("round", k + 1, time.strftime("%H:%M:%S"), flush=True)
    json.dump(data, open(out, "w"))
print("end", time.strftime("%H:%M:%S"), subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(), flush=True)
