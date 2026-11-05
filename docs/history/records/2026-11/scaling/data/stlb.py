# stlb.py MAPS < perf script -F addr,ip: STLB-missing loads by the mapping their data lies in.
import sys, bisect
from collections import Counter
vm = []
for line in open(sys.argv[1]):
    f = line.split()
    lo, hi = (int(x, 16) for x in f[0].split('-'))
    name = f[5] if len(f) > 5 else '[anon]'
    vm.append((lo, hi, name, f[1]))
vm.sort(); los = [v[0] for v in vm]
c = Counter(); tot = 0; miss = 0
for line in sys.stdin:
    f = line.split()
    if not f: continue
    try: a = int(f[0], 16)
    except ValueError: continue
    tot += 1
    i = bisect.bisect_right(los, a) - 1
    if i >= 0 and a < vm[i][1]:
        lo, hi, name, perm = vm[i]
        size = hi - lo
        c[(name, lo, size)] += 1
    else: miss += 1
print(f"{tot} samples, {miss} outside the last maps snapshot")
for (name, lo, size), n in c.most_common(int(sys.argv[2]) if len(sys.argv) > 2 else 15):
    print(f"{100*n/tot:6.2f}%  {name:28s} {lo:#x} {size/2**20:10.1f} MiB")
