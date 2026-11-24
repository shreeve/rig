#!/usr/bin/env python3
# leaf.py OUT.tsv XML...: self samples per leaf function (and per leaf PC) from xctrace time-profile exports.
import sys, re, collections
import xml.etree.ElementTree as ET
fn = collections.Counter(); real = collections.Counter(); pcs = collections.Counter(); incl = collections.Counter(); total = 0
for path in sys.argv[2:]:
    frames = {}; bts = {}
    root = ET.parse(path).getroot()
    for row in root.iter('row'):
        bt = (row.find('tagged-backtrace') if row.find('tagged-backtrace') is not None else row.find('backtrace'))
        if bt is None: continue
        if 'ref' in bt.attrib: chain = bts[bt.attrib['ref']]
        else:
            chain = []
            for f in bt.findall('frame'):
                if 'ref' in f.attrib: chain.append(frames[f.attrib['ref']])
                else:
                    v = (f.attrib.get('name', '?'), f.attrib.get('addr', '0'))
                    frames[f.attrib['id']] = v; chain.append(v)
            bts[bt.attrib['id']] = chain
        if not chain: continue
        total += 1
        fn[chain[0][0]] += 1; pcs[chain[0]] += 1
        same = [n for n, a in chain if a == chain[0][1]]; real[same[-1]] += 1
        for name in set(n for n, _ in chain): incl[name] += 1
with open(sys.argv[1], 'w') as o:
    o.write('total\t%d\n' % total)
    for k, v in fn.most_common(): o.write('self\t%d\t%.2f%%\t%s\n' % (v, 100.0 * v / total, k))
    for k, v in real.most_common(): o.write('real\t%d\t%.2f%%\t%s\n' % (v, 100.0 * v / total, k))
    for k, v in incl.most_common(300): o.write('incl\t%d\t%.2f%%\t%s\n' % (v, 100.0 * v / total, k))
    for (k, a), v in pcs.most_common(2000): o.write('pc\t%d\t%s\t%s\n' % (v, a, k))
print('samples', total)
for k, v in real.most_common(40): print('%6d %5.2f%% %s' % (v, 100.0 * v / total, k))
