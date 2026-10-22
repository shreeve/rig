import json, sys, collections
exec(open('analyze.py').read().split("if __name__")[0])
sites = sorted(set(p for r in res for p in r['probes']))
confs = ['12', '123', '124', '1234', '123p4']
print('| Site | main acc | main rej | ' + ' | '.join(f'left {c} (acc/rej)' for c in confs) + ' |')
print('|---|---|---|' + '---|' * len(confs))
for s in sites:
    rs = [r for r in res if s in r['probes']]
    ma = sum(r['acc'] for r in rs); mr = len(rs) - ma
    cells = []
    for c in confs:
        left = [r for r in rs if not (r['H'] & CONF[c])]
        a = sum(r['acc'] for r in left); cells.append(f'{a}/{len(left) - a}' + (' **DEAD**' if not left else ''))
    print(f'| {s} | {ma} | {mr} | ' + ' | '.join(cells) + ' |')
