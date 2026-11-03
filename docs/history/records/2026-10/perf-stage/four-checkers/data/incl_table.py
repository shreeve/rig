#!/usr/bin/env python3
"""incl_table.py: inclusive cost per operation on checker 0 (same files both sides)."""
import json, collections, os, statistics as st
D = os.environ.get('CK0', '.') + '/'  # the folder of the counting outputs (*.out)
def load(f):
    d = collections.defaultdict(collections.Counter)
    for l in open(D + f):
        if l.startswith('CK0 '):
            _, k, i, v = l.split(); d[int(k)][int(i)] += int(v)
    return d
t = load('ts4b.out')[0]
s4 = load('tsrs4f.out'); s = s4[max(s4, key=lambda k: s4[k][0])]
def calls(c, op):
    return {'relations': c[60], 'relation cache': c[62], 'instantiation': c[0],
            'object/conditional/reference instantiation': c[44] + c[52] + c[54], 'mapper_map': c[20],
            'get_type_of_symbol': c[63], 'resolve_structured_type_members': c[64], 'infer_types': c[65],
            'infer_from_types': c[66], 'get_signatures_of_type': c[67], 'union construction': c[69],
            'intersection construction': c[70]}.get(op)
# exact totals at four checkers and sampled totals per run (instr, cycles)
EX = {'plain': (9.4889e9, 5.560e9), 'pgo': (8.382e9, 5.058e9), 'tsrsf': (8.603e9, 5.257e9)}
samp = collections.defaultdict(list)
for l in open(D + 'sampled.txt'):
    v, i, a, b = l.split(); samp[v].append((int(a), int(b)))
res = {}
for v in EX:
    d = json.load(open(D + f'{v}.json')); n = d['runs']
    si = EX[v][0] / st.mean(a for a, b in samp[v]); sc = EX[v][1] / st.mean(b for a, b in samp[v])
    res[v] = {'n': n, 'si': si, 'sc': sc, 'd': d}
def val(v, ev, op):
    r = res[v]; k = 'instr' if ev == 'i' else 'cycles'
    x = r['d']['incl'][k].get(op, 0) if op != '*' else r['d']['total'][k]
    return x / r['n'] * (r['si'] if ev == 'i' else r['sc'])
ops = ['relations', 'relation cache', 'instantiation', 'object/conditional/reference instantiation', 'mapper_map',
       'get_type_of_symbol', 'resolve_structured_type_members', 'infer_types', 'infer_from_types',
       'get_signatures_of_type', 'resolved signatures', 'property lookup', 'union construction', 'intersection construction']
print('| operation | calls Trig / tsrs | Trig PGO cyc/call | Trig plain cyc/call | tsrs cyc/call | PGO vs tsrs | Trig PGO instr/call | tsrs instr/call | Trig PGO incl. cycles | tsrs incl. cycles |')
print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for op in ['*'] + ops:
    ct, cs = (calls(t, op), calls(s, op)) if op != '*' else (None, None)
    pc, lc, sc_ = val('pgo', 'c', op), val('plain', 'c', op), val('tsrsf', 'c', op)
    pi, si_ = val('pgo', 'i', op), val('tsrsf', 'i', op)
    if ct and cs and sc_:
        print(f'| {op} | {ct:,} / {cs:,} | {pc/ct:,.0f} | {lc/ct:,.0f} | {sc_/cs:,.0f} | {100*(pc/ct)/(sc_/cs)-100:+.0f}% | {pi/ct:,.0f} | {si_/cs:,.0f} | {pc/1e6:,.0f}M | {sc_/1e6:,.0f}M |')
    else:
        rel = f'{100*pc/sc_-100:+.0f}% (incl.)' if sc_ else 'n/a'
        print(f'| {"checker 0, all" if op == "*" else op} | {"-" if not ct else f"{ct:,} / {cs:,}"} | {"-" if not ct else f"{pc/ct:,.0f}"} | {"-" if not ct else f"{lc/ct:,.0f}"} | - | {rel} | - | - | {pc/1e6:,.0f}M | {sc_/1e6:,.0f}M |')
print()
print('hash-table leaf samples (share of checker 0), by owning operation:')
for v in ('pgo', 'plain', 'tsrsf'):
    d = res[v]['d']
    for k in ('cycles', 'instr'):
        tot = d['total'][k]; m = d['maptot'][k]
        own = sorted(d['mapown'][k].items(), key=lambda x: -x[1])[:6]
        print(f'  {v} {k}: {100*m/tot:.1f}% of {tot} samples; ' + ', '.join(f'{o} {100*c/tot:.1f}%' for o, c in own))
