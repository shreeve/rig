#!/usr/bin/env python3
# hot.py DIS TSV [N] [REGEX]: the N hottest functions by self samples (TSV from leaf.py, 'real' rows),
# with each one's instructions, conditional branches, and branches to a panic by kind.
import sys, re, collections
sys.argv, dis = sys.argv, sys.argv[1]
import importlib.util
spec = importlib.util.spec_from_file_location('panics', __file__.replace('hot.py', 'panics.py'))
saved = sys.argv; sys.argv = [saved[0], dis]; P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P); sys.argv = saved
by = {}
for name, n, b, k in P.out: by.setdefault(name.lstrip('_'), (n, b, k))
total = 0; rows = []
for line in open(sys.argv[2]):
    f = line.rstrip('\n').split('\t')
    if f[0] == 'total': total = int(f[1])
    if f[0] == 'real': rows.append((int(f[1]), f[3]))
N = int(sys.argv[3]) if len(sys.argv) > 3 else 30
pat = re.compile(sys.argv[4]) if len(sys.argv) > 4 else None
shown = 0
for s, name in rows:
    if pat and not pat.search(name): continue
    n, b, k = by.get(name.lstrip('_'), (0, 0, collections.Counter()))
    ks = ', '.join('%s %d' % (re.sub(r'^(zig\.|_rig\.runtime\.)', '', a), c) for a, c in k.most_common(5))
    print('%5d %5.2f%% %-60s ins %6d br %5d panic %5d  %s' % (s, 100.0 * s / total, name[:60], n, b, sum(k.values()), ks))
    shown += 1
    if shown >= N: break
