#!/usr/bin/env python3
"""shares.py DIR FUNC...: each FUNC's inclusive share (anywhere on the stack,
once a sample) and self share (the leaf) of the LBR samples of Trig's user
cycles in DIR (lbr.trig.N.txt.gz), by exact function name."""
import sys, gzip, glob, collections
D = sys.argv[1]; want = sys.argv[2:]
n = 0; inc = collections.Counter(); own = collections.Counter()
def flush(chain):
    global n
    if not chain: return
    n += 1
    for k in set(chain) & set(want): inc[k] += 1
    if chain[0] in want: own[chain[0]] += 1
for p in sorted(glob.glob(f'{D}/lbr.trig.*.txt.gz')):
    chain = []
    for line in gzip.open(p, 'rt', errors='replace'):
        if not line.strip():
            flush(chain); chain = []; continue
        if line.startswith(('\t', ' ')):
            parts = line.split()
            if len(parts) >= 2: chain.append(parts[1])
    flush(chain)
print(f'{D}: {n} samples')
for k in want:
    print(f'| {k} | {100*inc[k]/n:.1f}% | {100*own[k]/n:.1f}% |')
