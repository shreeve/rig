import sys, statistics as st, collections
d = collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(list)))
order = collections.defaultdict(list)
bad = 0
for l in open(sys.argv[1]):
    if l.startswith('#') or '=' not in l: continue
    p = l.split()[0]
    kv = dict(x.split('=') for x in l.split()[1:])
    v = kv['v']
    if v not in order[p]: order[p].append(v)
    if kv['same'] != '1' or kv['exit'] not in ('0', '2'): bad += 1
    for k in ('ns', 'cycles', 'instructions', 'rss_kb'): d[p][v][k].append(float(kv[k]))
print('runs whose output differs from base or that failed:', bad)
for p in d:
    vs = order[p]; b = vs[0]
    print('%s, %d rounds' % (p, len(d[p][b]['ns'])))
    for k in ('ns', 'cycles', 'instructions', 'rss_kb'):
        s = '  %-12s' % k
        for v in vs:
            x = d[p][v][k]; s += '  %s: med %.5g min %.5g' % (v, st.median(x), min(x))
        for v in vs[1:]:
            m0, n0 = st.median(d[p][b][k]), min(d[p][b][k]); m1, n1 = st.median(d[p][v][k]), min(d[p][v][k])
            s += '   %s vs %s: med %+.2f%% min %+.2f%%' % (v, b, 100 * (m1 / m0 - 1), 100 * (n1 / n0 - 1))
        print(s)
