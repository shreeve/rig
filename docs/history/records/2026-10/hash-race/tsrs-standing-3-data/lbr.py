#!/usr/bin/env python3
"""lbr.py DIR [FUNC...]: reads diag.sh's LBR profiles of Trig's user cycles
(lbr.trig.N.txt.gz) and prints each function's share of the samples
inclusive (anywhere on the stack, counted once a sample) and self, the top
60 by inclusive share; then for each FUNC named, its callers and callees."""
import sys, gzip, glob, collections
D = sys.argv[1]; want = sys.argv[2:]
incl = collections.Counter(); self_ = collections.Counter(); n = 0; runs = 0
callers = collections.defaultdict(collections.Counter); callees = collections.defaultdict(collections.Counter)
def flush(chain):
    global n
    if not chain: return
    n += 1
    self_[chain[0]] += 1
    for f in set(chain): incl[f] += 1
    for i, f in enumerate(chain):
        if f in want:
            callers[f][chain[i + 1] if i + 1 < len(chain) else '(root)'] += 1
            callees[f][chain[i - 1] if i > 0 else '(self)'] += 1
for p in sorted(glob.glob(f'{D}/lbr.trig.*.txt.gz')):
    runs += 1; chain = None
    for line in gzip.open(p, 'rt', errors='replace'):
        if not line.strip():
            flush(chain); chain = None; continue
        if not line[0].isspace():
            flush(chain); chain = []; continue
        parts = line.split(None, 2)
        if chain is not None and len(parts) >= 2 and parts[1] != '[unknown]':
            chain.append(parts[1])
    flush(chain)
print(f'{runs} runs, {n} samples ({n / runs:.1f} a run)')
print('| function | inclusive | self |')
print('|---|---:|---:|')
for f, c in incl.most_common(60):
    print(f'| {f} | {100 * c / n:.1f}% | {100 * self_[f] / n:.1f}% |')
for f in want:
    print(f'\n{f}: inclusive {100 * incl[f] / n:.1f}%, self {100 * self_[f] / n:.1f}%')
    print('  callers: ' + ', '.join(f'{k} {100 * c / n:.2f}%' for k, c in callers[f].most_common(8)))
    print('  callees: ' + ', '.join(f'{k} {100 * c / n:.2f}%' for k, c in callees[f].most_common(8)))
