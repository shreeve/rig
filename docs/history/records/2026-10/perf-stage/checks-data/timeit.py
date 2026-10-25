#!/usr/bin/env python3
# timeit.py ROUNDS OUT.tsv VARIANT...: interleaved runs on core 6 (perf stat
# itself pinned), every variant on every project each round; checks that
# each variant's output matches base's.
import sys, subprocess, hashlib, os, time
S = '/zfs/worktrees/rig/perf-checks'
P = '/zfs/trig-pup/runs/trig/misc/projects'
rounds = int(sys.argv[1]); out = sys.argv[2]; variants = sys.argv[3:]
projects = ['tiny-invariant', 'zod3', 'ts-pattern']
def core7():
    for l in open('/proc/stat'):
        if l.startswith('cpu7 '):
            v = list(map(int, l.split()[1:])); return sum(v) - v[3] - v[4], sum(v)
digest = {}
f = open(out, 'a')
b0 = core7()
for r in range(rounds):
    for p in projects:
        order = variants[r % len(variants):] + variants[:r % len(variants)]
        for v in order:
            st = f'{S}/data/stat.tmp'
            cmd = ['taskset','-c','6','perf','stat','-x,','-o',st,'-e','cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/branches/u,duration_time','--',
                   f'{S}/bins/{v}','-p','tsconfig.trig.json','--noEmit','--singleThreaded']
            for attempt in range(5):
                c0 = core7()
                res = subprocess.run(cmd, cwd=f'{P}/{p}', capture_output=True)
                c1 = core7()
                busy7 = 100.0 * (c1[0]-c0[0]) / max(1, c1[1]-c0[1])
                if busy7 < 2.0: break
                time.sleep(5)
            h = hashlib.md5(res.stdout + res.stderr + str(res.returncode).encode()).hexdigest()
            digest.setdefault((p, v), set()).add(h)
            vals = {}
            for l in open(st):
                parts = l.strip().split(',')
                if len(parts) > 3 and parts[0].replace('.','').isdigit():
                    vals[parts[2].split('/')[1] if '/' in parts[2] else parts[2]] = parts[0]
            f.write('\t'.join([str(r), p, v, vals.get('instructions',''), vals.get('cycles',''), vals.get('branches',''), vals.get('duration_time',''), h, '%.1f' % busy7]) + '\n'); f.flush()
b1 = core7()
print('core 7 busy share during the runs: %.2f%%' % (100.0 * (b1[0]-b0[0]) / max(1, b1[1]-b0[1])))
for (p, v), hs in sorted(digest.items()):
    base = digest.get((p, 'base'))
    print(p, v, 'same as base' if hs == base else 'DIFFERS', len(hs))
