#!/usr/bin/env python3
# cmp.py REPS EXE...: run each exe interleaved, fastest per (keys, op); first is the base.
import sys, subprocess
reps = int(sys.argv[1]); exes = sys.argv[2:]
best = {e: {} for e in exes}; chk = {}
for r in range(reps):
    for e in exes[r % len(exes):] + exes[:r % len(exes)]:
        p = subprocess.run([e], capture_output=True, text=True, check=True)
        for l in (p.stdout + p.stderr).splitlines():
            k, op, ns, c = l.split()
            best[e][(k, op)] = min(best[e].get((k, op), 1 << 62), int(ns))
            chk.setdefault((k, op), set()).add(c)
bad = [k for k, v in chk.items() if len(v) > 1]
print('checksums', 'agree' if not bad else 'DIFFER %s' % bad)
base = exes[0]
for key in best[base]:
    b = best[base][key]
    print('%-8s %-14s' % key, ' '.join('%s %8d (%s)' % (e.split('/')[-1], best[e][key], ('%.1f%% faster' % (100*(b-best[e][key])/b)) if best[e][key] <= b else ('%.1f%% slower' % (100*(best[e][key]-b)/b))) for e in exes))
