#!/usr/bin/env python3
# heap-resolve.py BIN DUMP OUT: resolves the heap census's stacks (tsrs_cli heapcensus.rs) with addr2line and writes
# live bytes per allocating site: the first tsrs frame (inlined frames expanded) and the container kind under it.
import sys, subprocess, re, collections

bin_, dump, outp = sys.argv[1:4]
header, maps, rows = None, [], []
for l in open(dump):
    if l.startswith('#'):
        header = l.strip()
    elif l.startswith('map '):
        maps.append(l[4:].split())
    else:
        n, b, u, fr = l.rstrip('\n').split('\t')
        rows.append((int(n), int(b), int(u), [int(x, 16) for x in fr.split()]))

# Load base: the binary's mapping with offset 0.
base = None
for m in maps:
    if len(m) >= 6 and m[5].endswith('/tsrs') and int(m[2], 16) == 0:
        base = int(m[0].split('-')[0], 16)
        break
lo_hi = [(int(m[0].split('-')[0], 16), int(m[0].split('-')[1], 16)) for m in maps if len(m) >= 6 and m[5].endswith('/tsrs')]


def inbin(ip):
    return any(a <= ip < b for a, b in lo_hi)


ips = sorted({ip for r in rows for ip in r[3] if inbin(ip)})
res = {}
CH = 20000
for i in range(0, len(ips), CH):
    chunk = ips[i:i + CH]
    p = subprocess.run(['addr2line', '-f', '-C', '-i', '-a', '-e', bin_] + ['%x' % (ip - base - 1) for ip in chunk],
                       capture_output=True, text=True)
    cur, frames, k = None, [], -1
    lines = p.stdout.split('\n')
    j = 0
    while j < len(lines):
        l = lines[j]
        if l.startswith('0x'):
            if k >= 0:
                res[chunk[k]] = frames
            k += 1
            frames = []
            j += 1
            continue
        if l == '':
            j += 1
            continue
        fn = l
        loc = lines[j + 1] if j + 1 < len(lines) else '?'
        frames.append((fn, loc))
        j += 2
    if k >= 0:
        res[chunk[k]] = frames

def ours(fn, loc):
    return '/crates/tsrs' in loc and 'heapcensus' not in loc and 'tsrs_cli/src/main.rs' not in loc


def container(fn, loc):
    s = fn + ' ' + loc
    if 'hashbrown' in s or 'HashMap' in s or 'HashSet' in s or 'hash_map' in s or 'hash_set' in s:
        return 'hash table'
    if 'indexmap' in s:
        return 'index map'
    if 'alloc/src/string.rs' in s or 'alloc/src/fmt.rs' in s or 'alloc/src/str.rs' in s:
        return 'string'
    if 'smallvec' in s:
        return 'smallvec'
    if 'alloc/src/sync.rs' in s or 'alloc/src/rc.rs' in s:
        return 'arc/rc'
    if 'alloc/src/boxed' in s:
        return 'box'
    if 'raw_vec' in s or 'alloc/src/vec' in s or 'alloc/src/slice.rs' in s or 'collections/vec_deque' in s:
        return 'vec'
    return 'other'


agg = collections.defaultdict(lambda: [0, 0, 0])
for n, b, u, fr in rows:
    frames = []
    for ip in fr:
        frames.extend(res.get(ip, [('??', '??')]))
    site, cont, idx = '?', 'other', len(frames)
    for i, (fn, loc) in enumerate(frames):
        if ours(fn, loc):
            site = f'{fn} @ {loc.split("/crates/")[-1]}'
            idx = i
            break
    for fn, loc in reversed(frames[:idx]):
        c = container(fn, loc)
        if c != 'other':
            cont = c
            break
    rest = [f'{fn}' for fn, loc in frames[idx + 1:] if ours(fn, loc)]
    ctx = ' < '.join(rest[:3])
    key = (site, cont, ctx)
    a = agg[key]
    a[0] += n; a[1] += b; a[2] += u

with open(outp, 'w') as o:
    o.write(header + '\n')
    o.write('usable_bytes\trequested_bytes\tblocks\tcontainer\tsite\tcallers\n')
    for k, v in sorted(agg.items(), key=lambda kv: -kv[1][2]):
        o.write(f'{v[2]}\t{v[1]}\t{v[0]}\t{k[1]}\t{k[0]}\t{k[2]}\n')
print('resolved', len(ips), 'ips;', len(agg), 'sites')
