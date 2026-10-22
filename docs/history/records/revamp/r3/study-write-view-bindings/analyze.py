import json, sys, re, collections, os
res = [json.loads(l) for l in open(sys.argv[1])]
CONF = {'12': {1,2}, '3': {3}, '4': {4}, '34': {3,4}, '123': {1,2,3}, '124': {1,2,4}, '1234': {1,2,3,4}, '3p': {'3p'}, '123p': {1,2,'3p'}, '123p4': {1,2,'3p',4}}
def hits(r, use_only=False):
    """set of rules a program hits; '3p' = rule 3 with a place leaf"""
    s = set(); kinds = collections.defaultdict(set)
    for line in r['rules']:
        p = line.split()
        rule = int(p[0][1:]); kinds[rule].add(p[1])
        if rule == 3 and 'placeleaf' in line: kinds['3p'].add(p[1])
    for k, ks in kinds.items():
        if use_only and k in (1, 2) and ks <= {'field'}: continue
        s.add(k)
    return s
def group(r):
    i = r['id']
    if i.startswith('doc/'): return 'doc/' + i.split('/')[1]
    if i.startswith('matrix/'): return 'matrix/' + i.split('/')[1].split('.')[0]
    if i.startswith('hdr/'): return 'hdr'
    if i.startswith('study/probes/'): return 'probes/' + i.split('/')[2]
    p = i.split('/')
    if p[0] == 'test': return 'test/' + p[1]
    return p[0]
for r in res:
    r['H'] = hits(r); r['HU'] = hits(r, True); r['acc'] = r['rc'] == 0; r['g'] = group(r)
def rejected_by(r, conf, use=False):
    return bool((r['HU'] if use else r['H']) & CONF[conf])

def fallout():
    print("## Fallout: programs accepted on main that each config rejects")
    groups = sorted(set(r['g'] for r in res))
    hdr = ['group', 'acc main', 'acc 12', 'r3 rej (of main-acc)', 'r3 new over 12', 'r3p new over 12', 'r4 rej', 'r4 new over 12', 'r34 new over 12']
    print('| ' + ' | '.join(hdr) + ' |'); print('|' + '---|' * len(hdr))
    tot = collections.Counter()
    for g in groups:
        rs = [r for r in res if r['g'] == g and r['acc']]
        a12 = [r for r in rs if not rejected_by(r, '12')]
        row = [len(rs), len(a12),
               sum(1 for r in rs if 3 in r['H']), sum(1 for r in a12 if 3 in r['H']), sum(1 for r in a12 if '3p' in r['H']),
               sum(1 for r in rs if 4 in r['H']), sum(1 for r in a12 if 4 in r['H']),
               sum(1 for r in a12 if r['H'] & {3, 4})]
        for k, v in zip(hdr[1:], row): tot[k] += v
        if any(row): print(f'| {g} | ' + ' | '.join(map(str, row)) + ' |')
    print('| **all** | ' + ' | '.join(str(tot[k]) for k in hdr[1:]) + ' |')

def lst(conf_rule, gfilter, newover12=True):
    out = []
    for r in res:
        if not r['acc'] or not gfilter(r['g']): continue
        if newover12 and rejected_by(r, '12'): continue
        if conf_rule in r['H']: out.append(r)
    return out

if __name__ == '__main__':
    fallout()
