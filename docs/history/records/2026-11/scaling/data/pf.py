# pf.py SMAPS < perf script -F addr: page faults by the advice of the mapping they hit.
import sys, re, bisect
from collections import Counter
vm = []; cur = None
for line in open(sys.argv[1]):
    m = re.match(r'([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)$', line)
    if m:
        cur = [int(m.group(1), 16), int(m.group(2), 16), m.group(4).strip() or '[anon]', '']
        vm.append(cur); continue
    m = re.match(r'VmFlags:\s*(.*)', line)
    if m and cur: cur[3] = m.group(1)
vm.sort(); los = [v[0] for v in vm]
c = Counter(); tot = 0
for line in sys.stdin:
    try: a = int(line.split()[0], 16)
    except (ValueError, IndexError): continue
    tot += 1
    i = bisect.bisect_right(los, a) - 1
    if i < 0 or a >= vm[i][1]: c['outside the snapshot'] += 1; continue
    lo, hi, name, fl = vm[i]; f = ' ' + fl + ' '
    if name != '[anon]': k = 'file: ' + name.split('/')[-1]
    elif ' nh ' in f: k = 'anon, NOHUGEPAGE (Table heads, region)'
    elif ' hg ' in f: k = 'anon, HUGEPAGE (Table tails, huge segments, large)'
    elif hi - lo >= 1 << 30: k = 'anon, >= 1 GiB unadvised (segment region / Tables gate shut)'
    else: k = 'anon, other'
    c[k] += 1
print(f'{tot} faults')
for k, n in c.most_common(): print(f'{100*n/tot:6.1f}%  {n:7d}  {k}')
