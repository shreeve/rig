#!/usr/bin/env python3
# weighted.py DIS TSV [REGEX]: panic-branch kinds weighted by where time goes: each function's
# branches to a panic of each kind, per instruction, times its self samples.
import sys, re, collections, importlib.util
spec = importlib.util.spec_from_file_location('panics', __file__.replace('weighted.py', 'panics.py'))
saved = sys.argv; sys.argv = [saved[0], saved[1]]; P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P); sys.argv = saved
by = {name.lstrip('_'): (n, k) for name, n, b, k in P.out}
pat = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
w = collections.Counter(); covered = 0; total = 0
for line in open(sys.argv[2]):
    f = line.rstrip('\n').split('\t')
    if f[0] != 'real': continue
    s, name = int(f[1]), f[3]
    if pat and not pat.search(name): continue
    total += s
    if name not in by or by[name][0] == 0: continue
    covered += s; n, k = by[name]
    for kind, c in k.items(): w[kind] += s * c / n
t = sum(w.values())
print('samples %d, in disassembled functions %d; weighted panic branches per instruction %.3f' % (total, covered, t / max(covered, 1)))
for kind, v in w.most_common(10): print('  %5.1f%% %s' % (100 * v / t, kind))
