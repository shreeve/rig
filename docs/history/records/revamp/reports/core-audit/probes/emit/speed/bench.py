#!/usr/bin/env python3
"""bench.py BIN CMD runs file...: min-of-runs CPU ms per phase."""
import subprocess, sys, os, collections
binp, cmd, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
files = sys.argv[4:]
env = dict(os.environ, RIG_TIME='1', RIG_OUT_DIR=os.path.abspath('out-bench'))
results = {}
order = []
for f in files:
    best = {}
    for r in range(runs):
        p = subprocess.run([binp, cmd, f], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if p.returncode != 0 and 'RIG_TIME' not in p.stderr:
            print(f, 'FAILED', p.stderr[:500]); break
        for line in p.stderr.splitlines():
            if not line.startswith('RIG_TIME') or 'wall_ms' in line: continue
            parts = line.split()
            name, wall, cpu = parts[1], float(parts[2]), float(parts[3])
            if name not in order: order.append(name)
            best[name] = min(best.get(name, 1e18), cpu)
    lines = sum(1 for _ in open(f))
    results[f] = (lines, best)
hdr = ['phase'] + [str(results[f][0]) for f in files]
print('| ' + ' | '.join(hdr) + ' |')
print('|' + '---|' * len(hdr))
for name in order:
    print('| ' + name + ' | ' + ' | '.join('%.1f' % results[f][1].get(name, 0) for f in files) + ' |')
