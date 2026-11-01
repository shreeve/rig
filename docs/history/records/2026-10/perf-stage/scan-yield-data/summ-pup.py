#!/usr/bin/env python3
"""summ-pup.py TIMES: per project and variant, from ecount.sh's lines:
wall fastest and median, instructions min, cycles fastest and median,
peak RSS median; each against the first variant seen. Fails if any run
differed in output."""
import re, sys, statistics as st
d = {}; order = []; projs = []
for l in open(sys.argv[1]):
    if l.startswith('#'): continue
    m = dict(re.findall(r'(\w+)=(\S+)', l)); p = l.split()[0]
    if m.get('same') != '1': sys.exit('output differs: ' + l)
    if p not in projs: projs.append(p)
    if m['v'] not in order: order.append(m['v'])
    d.setdefault((p, m['v']), []).append((int(m['ns']), int(m['cycles']), int(m['instructions']), int(m['rss_kb'])))
def pct(a, b, up, down):
    if a == b: return 'level'
    s = a / b
    return '%.2f%% %s' % (((s - 1) if s >= 1 else (1 / s - 1)) * 100, up if s >= 1 else down)
ref = order[0]
print('| project | variant | runs | wall fastest | wall median | vs %s (median) | instructions (min) | vs %s | cycles fastest | cycles median | vs %s (median) | peak RSS median |' % (ref, ref, ref))
print('|---|---|---:|---:|---:|---|---:|---|---:|---:|---|---:|')
for p in projs:
    a = d[(p, ref)]
    for v in order:
        b = d.get((p, v))
        if not b: continue
        c = lambda xs, k: [x[k] for x in xs]
        print('| %s | %s | %d | %.2f ms | %.2f ms | %s | %.4fG | %s | %.4fG | %.4fG | %s | %.1f MB |' % (p, v, len(b),
            min(c(b, 0)) / 1e6, st.median(c(b, 0)) / 1e6, '' if v == ref else pct(st.median(c(a, 0)), st.median(c(b, 0)), 'faster', 'slower'),
            min(c(b, 2)) / 1e9, '' if v == ref else pct(min(c(a, 2)), min(c(b, 2)), 'fewer', 'more'),
            min(c(b, 1)) / 1e9, st.median(c(b, 1)) / 1e9, '' if v == ref else pct(st.median(c(a, 1)), st.median(c(b, 1)), 'fewer', 'more'),
            st.median(c(b, 3)) / 1024))
