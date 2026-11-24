#!/usr/bin/env python3
# summary.py TSV BASE ARM: medians per project and mode; ARM against BASE.
import sys, statistics, collections
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1])][1:]
base, arm = sys.argv[2], sys.argv[3]
d = collections.defaultdict(list); shas = collections.defaultdict(set)
for r in rows:
    d[(r[2], r[3], r[1])].append(r); shas[(r[2], r[3])].add(r[10])
def med(k, i, f=float): return statistics.median(f(x[i]) for x in d[k])
print('| project | mode | runs | %s instructions | %s instructions | fewer instructions | %s cycles | %s cycles | fewer cycles | %s wall s | %s wall s | faster (wall) | stdout |' % (base, arm, base, arm, base, arm))
print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|')
keys = []
for r in rows:
    k = (r[2], r[3])
    if k not in keys: keys.append(k)
for p, m in keys:
    kb, ka = (p, m, base), (p, m, arm)
    ib, ia = med(kb, 7), med(ka, 7); cb, ca = med(kb, 8), med(ka, 8); wb, wa = med(kb, 4), med(ka, 4)
    print('| %s | %s | %d/%d | %.3fB | %.3fB | %.1f%% | %.3fB | %.3fB | %.1f%% | %.3f | %.3f | %.1f%% | %s |' % (p, m, len(d[kb]), len(d[ka]), ib / 1e9, ia / 1e9, 100 * (ib - ia) / ib,
          cb / 1e9, ca / 1e9, 100 * (cb - ca) / cb, wb, wa, 100 * (wb - wa) / wb, 'identical' if len(shas[(p, m)]) == 1 else 'DIFFER %s' % sorted(shas[(p, m)])))
