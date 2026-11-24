#!/usr/bin/env python3
# report.py CLASSIFIED.tsv CYCLES_PCT TITLE: the markdown tables of one profile's census: each category's
# share of the weighted check branches (all, and live: without the flag slow paths and the deliberate
# panics, which do not run), its share of c1 cycles (live share x CYCLES_PCT, the measured cost of all
# checks for that run), its branch count, and its top sites with their Rig source.
import sys, collections, os, importlib.util
spec = importlib.util.spec_from_file_location('rl', os.path.join(os.path.dirname(__file__), 'rigloc.py'))
rl = importlib.util.module_from_spec(spec); spec.loader.exec_module(rl)
path, cyc, title = sys.argv[1], float(sys.argv[2]), sys.argv[3]
ORDER = ['d', 'd-rec', 'b+', 'b-built', 'a', 'a+', 'c2n', 'c2r', 'c2p', 'e', 'hash', 'ctr', 'std', 'data', 'zig', 'cold', 'other', 'unk']
COLD = {'b-built', 'cold'}
w = collections.Counter(); n = collections.Counter(); kinds = collections.defaultdict(collections.Counter)
sites = collections.defaultdict(collections.Counter); helpers = collections.defaultdict(set)
for line in open(path):
    c, x, b, k, site, text, fns = line.rstrip('\n').split('\t')
    x = float(x); w[c] += x; n[c] += float(b); kinds[c][k] += x
    h = site.split('@')[0]; sites[c][h] += x; helpers[c].add(site)
T = sum(w.values()); L = sum(v for c, v in w.items() if c not in COLD)
print('### %s\n' % title)
print('| category | share of all check branches (weighted) | share of live | ~share of c1 cycles | branches | sites | kinds |')
print('|---|---:|---:|---:|---:|---:|---|')
for c in ORDER + sorted(set(w) - set(ORDER)):
    if c not in w: continue
    live = '' if c in COLD else '%.1f%%' % (100 * w[c] / L)
    cy = '~0' if c in COLD else '%.2f%%' % (cyc * w[c] / L)
    print('| %s | %.1f%% | %s | %s | %.0f | %d | %s |' % (c, 100 * w[c] / T, live, cy, n[c], len(helpers[c]),
          ', '.join('%s %.1f' % (k, 100 * v / T) for k, v in kinds[c].most_common(4))))
print('\nTop helpers per category (share of all weighted check branches; Rig source):\n')
for c in ORDER:
    if c not in w: continue
    top = ', '.join('`%s` %.2f%% (%s)' % (h.split('.', 1)[-1], 100 * v / T, rl.loc(h) or '?') for h, v in sites[c].most_common(6))
    print('- **%s**: %s' % (c, top))
print()
