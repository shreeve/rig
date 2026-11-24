#!/usr/bin/env python3
# agg.py STDERR: RIG_TABLE_RSS=1 lines per Trig field (names.py): count, Rss, AnonHugePages, by AnonHugePages.
import sys, collections, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from names import name
M = 1 << 20
def kv(rest): return dict(w.split('=', 1) for w in rest.split(' ') if '=' in w)
tables, maps, totals, peak = [], [], {}, ''
for line in open(sys.argv[1], errors='replace'):
    if not line.startswith('rig-table-rss: '): continue
    kind, _, rest = line.rstrip('\n')[len('rig-table-rss: '):].partition(' ')
    if kind == 'table': tables.append(kv(rest))
    elif kind in ('segment', 'other'): d = kv(rest); d['kind'] = kind; maps.append(d)
    elif kind == 'total': d = kv(rest); totals[d['kind']] = d
    elif kind == 'peak': peak = rest.split()[-2]
bytid = collections.defaultdict(list)
for t in tables: bytid[t['tid']].append(t)
for rs in bytid.values():
    rs.sort(key=lambda t: int(t['seq']))
    for k, t in enumerate(rs): t['field'] = name(len(rs), k)
agg = collections.OrderedDict()
for t in tables:
    a = agg.setdefault(t['field'], dict(type=t['name'].split('.')[-1], n=int(t['n']), reserved=int(t['reserved']), count=0, rss=0, huge=0, asked=0, dropped=0))
    a['count'] += 1; a['rss'] += int(t['rss']); a['huge'] += int(t['anonhuge']); a['asked'] += int(t['asked']); a['dropped'] += int(t['dropped'])
print(f"peak RSS {int(peak)/1024:.0f} MiB; threads reserving Tables: {len(bytid)} ({', '.join(str(len(v)) for v in bytid.values())} each); Tables: {len(tables)}, {sum(int(t['dropped']) for t in tables)} measured as dropped, the rest at exit")
print()
print("| Table | element, n | reserved MiB | count | Rss MiB | AnonHuge MiB |")
print("|---|---|---:|---:|---:|---:|")
rest = [0, 0, 0]
for f, a in sorted(agg.items(), key=lambda kv: (-kv[1]['huge'], -kv[1]['rss'])):
    if a['huge'] == 0 and a['rss'] < M // 2: rest[0] += a['count']; rest[1] += a['rss']; rest[2] += 1; continue
    print(f"| {f} | {a['type']}, {a['n']} | {a['reserved']/M:.0f} | {a['count']} | {a['rss']/M:.1f} | {a['huge']/M:.1f} |")
print(f"| {rest[2]} more fields, each under 0.5 MiB | | | {rest[0]} | {rest[1]/M:.1f} | 0.0 |")
st = sum(int(t['rss']) for t in tables); sh = sum(int(t['anonhuge']) for t in tables)
print(f"| **all Tables** | | | {len(tables)} | {st/M:.1f} | {sh/M:.1f} |")
print()
for k in ('tablemaps', 'segments', 'other', 'all'):
    d = totals.get(k, {})
    print(f"- at exit, {k}: Rss {int(d.get('rss',0))/M:.1f} MiB, AnonHuge {int(d.get('anonhuge',0))/M:.1f} MiB" + (f", {d['hg_maps']} maps asking for huge pages" if 'hg_maps' in d else ''))
for m in maps:
    if m['kind'] == 'segment': print(f"  - segment map base={m['base']} len={int(m['len'])/M:.0f} MiB: Rss {int(m['rss'])/M:.1f}, AnonHuge {int(m['anonhuge'])/M:.1f}, hg={m['hg']}")
