#!/usr/bin/env python3
# leaf2.py DIS OUT.tsv XML...: leaf.py, with leaf frames xctrace left as bare addresses inside `bin`
# (Trig's __rig_text) resolved to their function from DIS, by each trace's load address of `bin`.
import sys, re, bisect, collections
import xml.etree.ElementTree as ET
starts = []; names = []
for line in open(sys.argv[1], errors='replace'):
    m = re.match(r'^([0-9a-f]+) <(.*)>:$', line)
    if m: starts.append(int(m.group(1), 16)); names.append(m.group(2).lstrip('_'))
order = sorted(range(len(starts)), key=lambda i: starts[i]); starts = [starts[i] for i in order]; names = [names[i] for i in order]
def resolve(addr, load):
    f = addr - load + 0x100000000
    i = bisect.bisect_right(starts, f) - 1
    return names[i] if i >= 0 and f - starts[i] < 0x400000 else None
fn = collections.Counter(); real = collections.Counter(); total = 0; fixed = 0
for path in sys.argv[3:]:
    frames = {}; bts = {}; load = None
    root = ET.parse(path).getroot()
    for b in root.iter('binary'):
        if b.attrib.get('name') == 'bin' and 'load-addr' in b.attrib: load = int(b.attrib['load-addr'], 16); break
    for row in root.iter('row'):
        bt = (row.find('tagged-backtrace') if row.find('tagged-backtrace') is not None else row.find('backtrace'))
        if bt is None: continue
        if 'ref' in bt.attrib: chain = bts[bt.attrib['ref']]
        else:
            chain = []
            for f in bt.findall('frame'):
                if 'ref' in f.attrib: chain.append(frames[f.attrib['ref']])
                else:
                    v = (f.attrib.get('name', '?'), f.attrib.get('addr', '0')); frames[f.attrib['id']] = v; chain.append(v)
            bts[bt.attrib['id']] = chain
        if not chain: continue
        total += 1
        name, a = chain[0]
        if name.startswith('0x') and load is not None:
            r = resolve(int(a, 16), load)
            if r: real[r] += 1; fn[r] += 1; fixed += 1; continue
        fn[name] += 1
        same = [n for n, x in chain if x == a]; real[same[-1]] += 1
with open(sys.argv[2], 'w') as o:
    o.write('total\t%d\n' % total)
    for k, v in fn.most_common(): o.write('self\t%d\t%.2f%%\t%s\n' % (v, 100.0 * v / total, k))
    for k, v in real.most_common(): o.write('real\t%d\t%.2f%%\t%s\n' % (v, 100.0 * v / total, k))
print('samples', total, 'resolved from addresses', fixed)
