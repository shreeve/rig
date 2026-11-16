#!/usr/bin/env python3
"""analyze.py DIR: every stall the generator logged, by server, with the
canary's and the generator's own hiccups beside it, and for a traced Rig
run the server's events around it."""
import glob, os, sys, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import st
D = sys.argv[1]
detail = len(sys.argv) > 2
canary = []
for l in open(os.path.join(D, 'canary.log')):
    f = l.split()
    if f[1] in ('late', 'rtt'): canary.append((int(f[2]), f[1], int(f[3])))
print('canary hiccups (>2 ms):', len(canary))
for log in sorted(glob.glob(os.path.join(D, '*.log'))):
    name = os.path.basename(log)
    if name in ('canary.log', 'control.log', 'top.log'): continue
    m = re.match(r'(.*)-(\d+)\.log', name)
    variant, pid = m.group(1), m.group(2)
    S, other = st.gen(log)
    cl = st.clusters(S)
    rates = [(int(f[1]), int(f[2])) for f in other if f[0] == 'R']
    gens = [f for f in other if f[0] in 'TG']
    def rate_at(t):
        r = None
        for (t0, x) in rates:
            if t0 <= t: r = x
        return r
    for c in cl:
        worst = max(r['got'] - r['intended'] for r in c['reqs'])
        near = [x for x in canary if c['start'] - 100e6 <= x[0] <= c['end'] + 100e6]
        gnear = [x for x in gens if c['start'] - 100e6 <= int(x[1]) <= c['end'] + 100e6]
        late_send = max(r['sent'] - r['intended'] for r in c['reqs'])
        srv = max(r['first'] - r['sent'] for r in c['reqs'])
        print('%-9s pid %s rate %s: stall of %d requests, worst %.1f ms, span %.1f ms; worst send lateness %.1f ms, worst sent-to-first-byte %.1f ms; canary %s; generator %s' % (
            variant, pid, rate_at(c['start']), len(c['reqs']), worst / 1e6, (c['end'] - c['start']) / 1e6, late_send / 1e6, srv / 1e6,
            ['%s %.1fms@%+.0fms' % (k, v / 1e3, (t - c['start']) / 1e6) for (t, k, v) in near] or '-', [' '.join(x) for x in gnear] or '-'))
    if detail:
        for dump in sorted(glob.glob(os.path.join(D, 'dump-%s-*.bin' % pid))):
            for (lo, hi, evs, tf) in st.report(dump, S):
                st.timeline(evs, lo, hi)

# top's sample of the second each stall began, when top.log exists.
import time as _time
tp = os.path.join(D, 'top.log')
if os.path.exists(tp):
    samples, cur = {}, None
    for l in open(tp):
        if re.match(r'\d{4}/\d\d/\d\d \d\d:\d\d:\d\d', l): cur = l.split()[1]; samples[cur] = []; continue
        if cur and re.match(r'\d+\s+[\d.]+\s', l):
            f = l.split()
            if float(f[1]) >= 20: samples[cur].append('%s %s' % (f[-1] if len(f) < 6 else ' '.join(f[4:]), f[1]))
    print('\ntop at each stall (processes over 20% of a core, the second after):')
    for log in sorted(glob.glob(os.path.join(D, '*.log'))):
        name = os.path.basename(log)
        if name in ('canary.log', 'control.log', 'top.log'): continue
        S, _ = st.gen(log)
        for c in st.clusters(S):
            sec = _time.strftime('%H:%M:%S', _time.localtime(c['start'] / 1e9 + 1))
            print('  %-22s %s  %s' % (name, sec, samples.get(sec)))
