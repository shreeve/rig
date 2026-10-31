#!/usr/bin/env python3
"""fdiff.py A.tsv A.ips B.tsv B.ips: samples a run by outermost function
(the symbol perf names) in A and B, scaled to A's total, and the
functions whose share changed most."""
import sys, collections
def load(tsv, ips):
    n = sum(1 for l in open(ips) if l.strip()); c = collections.Counter(); inner = collections.Counter()
    for l in open(tsv):
        k, f, fn, outer = l.rstrip('\n').split('\t'); c[outer] += int(k); inner[(f, fn)] += int(k)
    return n, c, inner
na, a, ia = load(sys.argv[1], sys.argv[2]); nb, b, ib = load(sys.argv[3], sys.argv[4])
print(f'# A {na} samples, B {nb}: B has {100*(nb/na-1):+.1f}% (E-core, noisy)')
print('# by outermost function, share of A\'s samples: A, B, B - A')
top = sorted(set(a) | set(b), key=lambda f: -(a[f]))[:20]
for f in top: print(f'{100*a[f]/na:6.2f}% {100*b[f]/na:6.2f}% {100*(b[f]-a[f])/na:+6.2f}%  {f[:70]}')
print('# by innermost frame, largest changes')
ch = sorted(set(ia) | set(ib), key=lambda k: (ib[k] - ia[k]))
for k in ch[:15] + ch[-5:]: print(f'{100*ia[k]/na:6.2f}% {100*ib[k]/na:6.2f}% {100*(ib[k]-ia[k])/na:+6.2f}%  {k[0]} {k[1][:60]}')
