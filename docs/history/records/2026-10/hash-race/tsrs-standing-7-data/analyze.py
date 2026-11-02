#!/usr/bin/env python3
"""analyze.py RUNS...: standing-7's tables from time-ab.sh's run lines.

Arms: trig (Trig main PGO), aa (a byte-identical copy), nolib (Trig main
without lib.esnext.d.ts's three references tsrs 0.18.0 lacks), tsrs (tsrs
0.18.0 as shipped), tsrsg (tsrs in Go's mode: --checkerAssignment go
--noLazyMembers); suffix 1 is one checker on P-core 6, 4 is four on P-cores
0, 6, 8 and 10. Prints: every arm's medians, peak RSS split by the Table
huge-page gate; the lead comparison of trig against both tsrs modes; the
like-for-like lib comparison; the A/A spread."""
import sys, statistics as st, collections
rows, projs = collections.defaultdict(list), []
for path in sys.argv[1:]:
    for line in open(path):
        if line.startswith('#') or ' round=' not in line: continue
        f = line.split(); d = dict(x.split('=', 1) for x in f[1:] if '=' in x)
        if f[0] not in projs: projs.append(f[0])
        rows[(f[0], d['v'])].append(d)
ORDER = ['ts-pattern', 'zod3', 'mitt', 'neverthrow', 'superstruct', 'tiny-invariant']
projs = [p for p in ORDER if p in projs] + [p for p in projs if p not in ORDER]
med = lambda r, k, f=st.median: f(float(x[k]) for x in r)
wall = lambda r, f=st.median: med(r, 'duration_time', f) / 1e6
cyc = lambda r: med(r, 'cycles/u') / 1e6
ins = lambda r: med(r, 'instructions/u') / 1e6
rss = lambda r: med(r, 'rss_kb') / 1024
def gates(r):
    return {g: [x for x in r if x.get('gate') == g] for g in '10'}
def major(r):  # the gate state most runs had, and its runs
    g = gates(r); k = '1' if len(g['1']) >= len(g['0']) else '0'
    return k, g[k]
def pct(a, b, less='less', more='more'):
    q = a / b - 1
    if abs(q) < 0.0005: return 'the same'
    return f'{abs(q) * 100:.1f}% {more if q > 0 else less}'
def speed(a, b): return pct(a, b, 'faster', 'slower')
def rssc(r):
    g = gates(r)
    return ' / '.join(f"{len(g[k])}: {rss(g[k]):.1f}" if g[k] else f"0: -" for k in '10')

print('## Every arm\n')
print('Medians. Peak RSS in MiB by the Table huge-page gate, as "runs: median", open / shut.\n')
print('| project | arm | n | wall ms | fastest ms | user cycles M | user instr M | peak RSS MiB, all | open / shut | output |')
print('|---|---|---:|---:|---:|---:|---:|---:|---|---|')
for p in projs:
    for v in ['trig1', 'aa1', 'nolib1', 'tsrs1', 'tsrsg1', 'trig4', 'aa4', 'nolib4', 'tsrs4', 'tsrsg4']:
        r = rows.get((p, v))
        if not r: continue
        same = 'same' if all(x['same'] == '1' for x in r) else 'DIFF'
        ex = ','.join(sorted(set(x['exit'] for x in r)))
        print(f"| {p} | {v} | {len(r)} | {wall(r):.1f} | {wall(r, min):.1f} | {cyc(r):.1f} | {ins(r):.1f} | {rss(r):.1f} | {rssc(r)} | {same}, exit {ex} |")

for c in '14':
    print(f'\n## Trig against tsrs, {c} checker{"s" if c == "4" else ""}\n')
    print('Trig main against tsrs as shipped and in Go\'s mode. Trig\'s peak RSS is the median of the gate state most of its runs had; tsrs\'s over all its runs.\n')
    print('| project | Trig ms | tsrs ms | tsrsg ms | wall vs tsrs | wall vs tsrsg | cycles vs tsrs | cycles vs tsrsg | Trig RSS (gate, runs) | tsrs RSS | tsrsg RSS | RSS vs tsrs | RSS vs tsrsg |')
    print('|---|---:|---:|---:|---|---|---|---|---|---:|---:|---|---|')
    for p in projs:
        t, s, g = rows.get((p, 'trig' + c)), rows.get((p, 'tsrs' + c)), rows.get((p, 'tsrsg' + c))
        if not (t and s and g): continue
        k, tm = major(t)
        print(f"| {p} | {wall(t):.1f} | {wall(s):.1f} | {wall(g):.1f} | {speed(wall(t), wall(s))} | {speed(wall(t), wall(g))} | {pct(cyc(t), cyc(s), 'fewer')} | {pct(cyc(t), cyc(g), 'fewer')} | {rss(tm):.1f} ({'open' if k == '1' else 'shut'}, {len(tm)}/{len(t)}) | {rss(s):.1f} | {rss(g):.1f} | {pct(rss(tm), rss(s))} | {pct(rss(tm), rss(g))} |")

print('\n## Like for like: Trig without the three lib files\n')
print('| project | checkers | nolib ms | vs Trig main | vs tsrsg | vs tsrs | cycles vs Trig main | cycles vs tsrsg | RSS vs Trig main (same gate) |')
print('|---|---|---:|---|---|---|---|---|---|')
for p in projs:
    for c in '14':
        n, t, s, g = (rows.get((p, a + c)) for a in ('nolib', 'trig', 'tsrs', 'tsrsg'))
        if not (n and t and s and g): continue
        k, tm = major(t); nm = gates(n)[k]
        rc = pct(rss(nm), rss(tm)) + f" ({'open' if k == '1' else 'shut'})" if nm else '-'
        print(f"| {p} | {c} | {wall(n):.1f} | {speed(wall(n), wall(t))} | {speed(wall(n), wall(g))} | {speed(wall(n), wall(s))} | {pct(cyc(n), cyc(t), 'fewer')} | {pct(cyc(n), cyc(g), 'fewer')} | {rc} |")

print('\n## A/A: the copy against Trig main\n')
print('| project | checkers | wall | fastest | cycles | instructions |')
print('|---|---|---|---|---|---|')
for p in projs:
    for c in '14':
        a, t = rows.get((p, 'aa' + c)), rows.get((p, 'trig' + c))
        if not (a and t): continue
        print(f"| {p} | {c} | {speed(wall(a), wall(t))} | {speed(wall(a, min), wall(t, min))} | {pct(cyc(a), cyc(t), 'fewer')} | {pct(ins(a), ins(t), 'fewer')} |")
