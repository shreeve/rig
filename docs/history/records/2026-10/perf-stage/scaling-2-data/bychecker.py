#!/usr/bin/env python3
# bychecker.py DIR PROJ: from profile.sh's trig4 runs, each checker's
# samples in the check by kind of code and heaviest leaf, as shares of
# that checker's samples. At 4 cores a checker keeps its thread, so a
# sample is checker k's when its thread ran k's task.
import sys, glob, collections, re, gzip
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from profile import kind
D, proj = sys.argv[1], sys.argv[2]
HDR = re.compile(r'^\s*(.*?)\s+(-?\d+)/(-?\d+)\s+([\d.]+):\s+(?:\d+\s+)?(\S+):\s*(.*)$')
leaf = collections.defaultdict(collections.Counter); kinds = collections.defaultdict(collections.Counter); tot = collections.Counter()
for p in sorted(glob.glob(f'{D}/trig4.{proj}.*.txt.gz')):
    recs = []; cur = None
    for line in gzip.open(p, 'rt', errors='replace'):
        m = HDR.match(line)
        if m and not line.startswith('\t'):
            cur = [int(m[3]), float(m[4]), m[5], m[6], []]; recs.append(cur); continue
        f = re.match(r'^\s+([0-9a-f]+)\s+(.*)$', line)
        if f and cur is not None: cur[4].append((f[1], f[2].split('+0x')[0].strip()))
    k_of = {}; span = {}
    for tid, t, ev, tr, st in recs:
        if ev.endswith('_task'):
            k = int(re.search(r'k=(-?\d+)', tr)[1]); k_of[tid] = k; span[k] = [t, None]
        elif ev.endswith('_taskend') and tid in k_of:
            span[k_of[tid]][1] = t
    for tid, t, ev, tr, st in recs:
        if 'cycles' not in ev or tid not in k_of or not st: continue
        k = k_of[tid]; a, b = span[k]
        if b is None or not (a <= t <= b): continue
        tot[k] += 1; leaf[k][st[0][1]] += 1; kinds[k][kind(st)] += 1
for k in sorted(tot):
    n = tot[k]
    print(f"checker {k}: {n} samples; " + ', '.join(f"{c} {v / n:.1%}" for c, v in kinds[k].most_common()))
    print('   ' + '; '.join(f"{s} {v / n:.1%}" for s, v in leaf[k].most_common(10)))
