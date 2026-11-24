#!/usr/bin/env python3
# agg.py SITES.tsv [N]: weight per check site (innermost frame in a Rig module's .zig), per kind.
import sys, re, collections
KIND = {'indexPanic':'index','slicePanic':'slice','lenPanic':'len','zig.integerOutOfBounds':'conv','zig.integerOverflow':'ovf',
        'zig.outOfBounds':'zbounds','zig.startGreaterThanEnd':'zslice','bytesPanic':'bytes','shiftPanic':'shift','oom':'oom'}
SKIP = re.compile(r'@(runtime|mem|math|debug|Threaded|array_list|hash_map|sort|fmt|unicode|Io|heap|ordered|unordered|alloc|sched|tasks)\.zig')
w = collections.Counter(); n = collections.Counter(); fn = collections.defaultdict(collections.Counter); tot = collections.Counter()
for line in open(sys.argv[1]):
    f, s, ins, a, k, chain = line.rstrip('\n').split('\t')
    k = KIND.get(k, k)
    if k in ('oom','brk') or k.startswith('zig.reached'): continue
    wt = int(s) / int(ins)
    frames = chain.split(' < ')
    site = next((x for x in frames if not SKIP.search(x)), frames[-1])
    key = (site, k)
    w[key] += wt; n[key] += 1; fn[key][f] += 1; tot[k] += wt
T = sum(tot.values())
print('total weight %.1f; by kind: %s' % (T, ', '.join('%s %.1f%%' % (k, 100*v/T) for k, v in tot.most_common())))
N = int(sys.argv[2]) if len(sys.argv) > 2 else 80
for key, v in w.most_common(N):
    print('%5.2f%% %4d %-6s %-70s %s' % (100*v/T, n[key], key[1], key[0][:70], ','.join('%s:%d' % (a.split('.')[-1], c) for a, c in fn[key].most_common(3))))
