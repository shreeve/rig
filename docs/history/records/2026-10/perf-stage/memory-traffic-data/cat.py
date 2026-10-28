#!/usr/bin/env python3
# cat.py BIN SAMPLES... : per event, samples by the kind of code that made
# the access, judged from the sampled instruction's whole inline chain, the
# first kind in RULES's order that any frame names. The kinds are the same for Trig
# and tsrs: hash tables (Rig's Map/Set; hashbrown), arena/table reads (Rig's
# Table; tsrs's P<T> arena handles), list/vec, memcpy and memset, the
# allocator, the rest by crate or module.
import sys, subprocess, collections, re, os
b = sys.argv[1]
ev_ips = collections.defaultdict(collections.Counter)
for p in sys.argv[2:]:
    bp = p[:-len('.samples')] + '.bias'
    bias = int(open(bp).read().strip() or '0', 16) if os.path.exists(bp) else 0
    for line in open(p, errors='replace'):
        f = line.split()
        if len(f) < 4: continue
        try: ev_ips[f[1].rstrip(':')][int(f[3], 16) - bias] += 1
        except ValueError: pass
ips = sorted({ip for c in ev_ips.values() for ip in c})
out = subprocess.run(['/usr/bin/llvm-symbolizer-22', '--inlines', '--obj=' + b], input='\n'.join('0x%x' % i for i in ips) + '\n', capture_output=True, text=True).stdout
chain = {}
for ip, blk in zip(ips, out.split('\n\n')):
    ls = [l for l in blk.strip().split('\n') if l]
    chain[ip] = [(ls[k], ls[k + 1]) for k in range(0, len(ls) - 1, 2)]
RULES = [
    ('hash table', r'rig\.ordered|rig\.unordered|hashbrown|ordered\.zig|unordered\.zig'),
    ('memcpy/memset', r'compiler_rt\.mem|memcpy|memmove|memset|copy_nonoverlapping<u8>$'),
    ('allocator', r'rig\.alloc\.|alloc\.zig|mi_|mimalloc|_mi_'),
    ('table/arena read', r'rig\.table\.|table\.zig|tsrs_core::ptr|P<'),
    ('list/vec', r'ListOf|alloc::vec|slice::index|core::slice'),
]
def kind(ch):
    # The first kind, in RULES's order, that any frame of the chain names:
    # hashbrown's group load is a copy_nonoverlapping inside find_inner.
    for k, rx in RULES:
        for fn, loc in ch:
            if re.search(rx, fn) or re.search(rx, loc.split('/')[-1]): return k
    fn = ch[0][0] if ch else '?'
    m = re.match(r'(?:<)?([a-z_]+)(?:::|\.)', fn)
    return 'other: ' + (m.group(1) if m else fn[:30])
for ev, c in ev_ips.items():
    tot = sum(c.values()); k = collections.Counter()
    for ip, n in c.items(): k[kind(chain.get(ip, []))] += n
    print('\n## %s: %d samples\n\n| kind | samples | share |\n|---|---:|---:|' % (ev, tot))
    for a, n in k.most_common(14): print('| %s | %d | %.1f%% |' % (a, n, 100 * n / tot))
