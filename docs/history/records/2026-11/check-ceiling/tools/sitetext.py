#!/usr/bin/env python3
# sitetext.py SITES.tsv OUTDIR_ZIG OUT.tsv: per (site, kind): weight %, branches, the Zig line, top functions.
import sys, re, collections, os
KIND = {'indexPanic':'index','slicePanic':'slice','lenPanic':'len','zig.integerOutOfBounds':'conv','zig.integerOverflow':'ovf',
        'zig.outOfBounds':'zbounds','zig.startGreaterThanEnd':'zslice','bytesPanic':'bytes','shiftPanic':'shift'}
SKIP = re.compile(r'@(runtime|mem|math|debug|Threaded|array_list|hash_map|sort|fmt|unicode|Io|heap|ordered|unordered|alloc|sched|tasks)\.zig')
zdir = sys.argv[2]; cache = {}
def text(site):
    m = re.search(r'@([\w.]+\.zig):(\d+)$', site)
    if not m: return ''
    f, l = m.group(1), int(m.group(2))
    if f not in cache:
        p = os.path.join(zdir, f); cache[f] = open(p).read().split('\n') if os.path.exists(p) else []
    L = cache[f]
    return L[l-1].strip() if 0 < l <= len(L) else ''
w = collections.Counter(); n = collections.Counter(); fn = collections.defaultdict(collections.Counter); T = 0
for line in open(sys.argv[1]):
    f, s, ins, a, k, chain = line.rstrip('\n').split('\t')
    if k not in KIND: continue
    k = KIND[k]; wt = int(s) / int(ins); frames = chain.split(' < ')
    site = next((x for x in frames if not SKIP.search(x)), frames[-1])
    w[(site, k)] += wt; n[(site, k)] += 1; fn[(site, k)][f.split('.')[-1]] += 1; T += wt
with open(sys.argv[3], 'w') as o:
    for key, v in w.most_common():
        o.write('%.3f\t%d\t%s\t%s\t%s\t%s\n' % (100*v/T, n[key], key[1], key[0], text(key[0]), ','.join('%s:%d' % x for x in fn[key].most_common(3))))
