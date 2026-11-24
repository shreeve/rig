#!/usr/bin/env python3
# groups.py A.tsv B.tsv: self samples by area, and the parser/lexer/ast functions, A against B (per-run normalized).
import collections, sys
def load(p):
    t = 0; d = collections.Counter()
    for l in open(p):
        f = l.rstrip('\n').split('\t')
        if f[0] == 'total': t = int(f[1])
        if f[0] == 'real': d[f[3]] = int(f[1])
    return t, d
ta, a = load(sys.argv[1]); tb, b = load(sys.argv[2])
na, nb = float(sys.argv[3]), float(sys.argv[4])   # runs in each
def grp(n):
    for p, g in (('parser.', 'parser'), ('lexer.', 'lexer (scanner)'), ('binder.', 'binder'), ('ast.', 'ast')):
        if n.startswith(p): return g
    if n.startswith(('rig.', '__rig_std', 'hash.', 'mem.', 'sort.')): return 'rig runtime / std'
    if n.startswith('_') or n in ('read', 'open', 'close', 'mmap', 'munmap', 'madvise', 'write'): return 'system (libc, kernel)'
    return 'other Trig'
ga = collections.Counter(); gb = collections.Counter()
for k, v in a.items(): ga[grp(k)] += v
for k, v in b.items(): gb[grp(k)] += v
print('ms per run (1 sample = 1 ms): checked %.0f, ceiling %.0f' % (ta / na, tb / nb))
print('| area | checked ms/run | ceiling ms/run | less time |')
print('|---|---:|---:|---:|')
for g in sorted(ga, key=lambda g: -ga[g]):
    x, y = ga[g] / na, gb[g] / nb
    print('| %s | %.1f | %.1f | %.0f%% |' % (g, x, y, 100 * (x - y) / x if x else 0))
print()
print('| function | checked ms/run | ceiling ms/run |')
print('|---|---:|---:|')
n = 0
for k, v in a.most_common():
    if k.startswith(('parser.', 'lexer.', 'ast.')):
        print('| %s | %.2f | %.2f |' % (k, v / na, b[k] / nb)); n += 1
        if n >= 25: break
