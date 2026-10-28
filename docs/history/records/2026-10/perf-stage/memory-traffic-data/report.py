#!/usr/bin/env python3
# report.py RES.json BIN [TOP]: memtrace.py's result, symbolized against BIN
# (llvm-symbolizer --inlines), as tables: allocation volume by owner, by
# mechanism (the innermost runtime or std function on the allocating
# path), and by caller (the first frame in the program's own code); and,
# per sampled event, its samples by region, by owner, by mechanism and
# caller, and by the sampled instruction's function.
import json, sys, subprocess, collections, re

# Several runs' results merge: owners by name, sites by owner and frames.
# Volume is the first run's (every run allocates the same); samples add up.
paths = sys.argv[1].split(',')
binary = sys.argv[2]
TOP = int(sys.argv[3]) if len(sys.argv) > 3 else 25
SYM = '/usr/bin/llvm-symbolizer-22'
gnames = {}   # owner name -> global id
names = {}
gsites = {}   # (owner gid, frames) -> global site id
sites = {}
def gowner(nm):
    if nm not in gnames:
        gnames[nm] = len(gnames) + 1
        names[gnames[nm]] = nm
    return gnames[nm]
res = {'samples': collections.defaultdict(list), 'volume_owner': {}, 'volume_site': {}, 'copies_site': {}}
for k, path in enumerate(paths):
    r = json.load(open(path))
    nm = {int(a): b for a, b in r['names'].items()}
    omap = {o: gowner(n) for o, n in nm.items()}
    smap = {}
    for sid, v in r['sites'].items():
        key = (omap.get(v[0], gowner('?%d' % v[0])),) + tuple(v[1:])
        if key not in gsites:
            gsites[key] = len(gsites)
            sites[gsites[key]] = [key[0]] + list(key[1:])
        smap[int(sid)] = gsites[key]
    if k == 0:
        res['records'] = r['records']; res['peak_live_block_bytes'] = r['peak_live_block_bytes']
        res['volume_owner'] = {str(omap.get(int(o), 0)): v for o, v in r['volume_owner'].items()}
        res['volume_site'] = {str(smap[int(s)]): v for s, v in r['volume_site'].items()}
        res['copies_site'] = {str(smap[int(s)]): v for s, v in r['copies_site'].items()}
    for ev, rows in r['samples'].items():
        for reg, o, st, ip, c in rows:
            res['samples'][ev].append([reg, omap.get(o, o) if o >= 0 else o, smap.get(st, st) if st >= 0 else st, ip, c])
RUNTIME = ('runtime.zig', 'alloc.zig', 'ordered.zig', 'unordered.zig', 'table.zig', 'sched.zig', 'tasks.zig')


def symbolize(addrs, ret=True):
    addrs = sorted(set(addrs))
    if not addrs:
        return {}
    # A return address is the instruction after its call.
    q = '\n'.join('0x%x' % ((a - 1) if ret else a) for a in addrs) + '\n'
    p = subprocess.run([SYM, '--inlines', '--obj=' + binary], input=q, capture_output=True, text=True)
    out = {}
    for a, blk in zip(addrs, p.stdout.split('\n\n')):
        ls = [l for l in blk.strip().split('\n') if l]
        out[a] = [(ls[k], ls[k + 1].split('/')[-1].split(':')[0], ls[k + 1]) for k in range(0, len(ls) - 1, 2)]
    return out


def short(fn):
    fn = re.sub(r'__rig_m\d+_', '', fn)
    fn = re.sub(r'\(comptime [^)]*\)', '', fn)
    return fn[:110]


def owner_name(o):
    if o == -1: return '(freed block)'
    if o == -2: return '(stack)'
    if o == -3: return '(binary data)'
    if o == -4: return '(anon mapping)'
    if o == -5: return '(unmapped)'
    return short(names.get(o, '?%d' % o))


frames_all = []
for v in sites.values():
    frames_all += [int(x, 16) for x in v[1:] if int(x, 16)]
fsym = symbolize(frames_all)


def site_info(sid):
    """(mechanism, caller, chain) of a site: the innermost runtime/std
    function on the path and the first function in the program."""
    if sid < 0 or sid not in sites:
        return ('-', '-', '')
    chain = []
    for x in sites[sid][1:]:
        a = int(x, 16)
        if a == 0:
            break
        chain += fsym.get(a, [])
    mech = '-'
    caller = '-'
    for fn, f, loc in chain:
        rt = f in RUNTIME or '/lib/std/' in loc or 'std_' in f or f.startswith('__rig_std')
        if rt and mech == '-' and 'AllocTrace' not in fn and 'Allocator' not in fn and not fn.startswith('mem.Allocator'):
            mech = short(fn)
        if not rt:
            caller = short(fn) + ' (' + loc.split('/')[-1] + ')'
            break
    return (mech, caller, ' < '.join(short(fn) for fn, _, _ in chain[:8]))


def mechanism_class(mech, owner):
    m = mech
    if owner.startswith('map index'): return 'Map index'
    if owner.startswith('map entries'): return 'Map entries'
    if owner.startswith('map gone'): return 'Map gone bits'
    if owner.startswith('hashmap'): return 'HashMap block'
    if owner.startswith('box '): return 'box (create)'
    if 'reallocSlice' in m or '.grow' in m: return 'List/String growth'
    if 'clone' in m: return 'clone'
    if 'fromSlice' in m or 'initCapacity' in m: return 'List made to size'
    if 'allocSlice' in m: return 'allocSlice (other)'
    return m


def table(title, rows, cols):
    print('\n## ' + title + '\n')
    print('| ' + ' | '.join(cols) + ' |')
    print('|' + '|'.join('---:' if i else '---' for i in range(len(cols))) + '|')
    for r in rows:
        print('| ' + ' | '.join(str(x) for x in r) + ' |')


# Volume.
vo = {int(k): v for k, v in res['volume_owner'].items()}
vs = {int(k): v for k, v in res['volume_site'].items()}
tot_b = sum(v[0] for v in vo.values())
tot_n = sum(v[1] for v in vo.values())
print('# %s (%d runs)\n\nrecords %d; allocated %.1f MB in %d blocks; peak of live blocks %.1f MB' % (
    sys.argv[1].split(',')[0], len(paths), res['records'], tot_b / 1e6, tot_n, res['peak_live_block_bytes'] / 1e6))
rows = sorted(vo.items(), key=lambda kv: -kv[1][0])[:TOP]
table('Volume by owner (bytes requested)', [(owner_name(o), '%.1f' % (v[0] / 1e6), '%.1f%%' % (100 * v[0] / tot_b), v[1], '%.1f%%' % (100 * v[1] / max(tot_n, 1)), v[0] // max(v[1], 1)) for o, v in rows], ['owner', 'MB', 'share', 'blocks', 'share', 'avg B'])
by_mech = collections.defaultdict(lambda: [0, 0])
by_caller = collections.defaultdict(lambda: [0, 0])
by_mc = collections.defaultdict(lambda: [0, 0])
info = {}
for sid, (b, nb) in vs.items():
    mech, caller, chain = site_info(sid)
    info[sid] = (mech, caller, chain)
    on = owner_name(sites[sid][0])
    mc = mechanism_class(mech, on)
    by_mech[mc][0] += b; by_mech[mc][1] += nb
    by_caller[caller][0] += b; by_caller[caller][1] += nb
    by_mc[(mc, on, caller)][0] += b; by_mc[(mc, on, caller)][1] += nb
table('Volume by mechanism', [(k, '%.1f' % (v[0] / 1e6), '%.1f%%' % (100 * v[0] / tot_b), v[1], '%.1f%%' % (100 * v[1] / max(tot_n, 1))) for k, v in sorted(by_mech.items(), key=lambda kv: -kv[1][0])[:TOP]], ['mechanism', 'MB', 'share', 'blocks', 'share'])
table('Volume by caller', [(k, '%.1f' % (v[0] / 1e6), '%.1f%%' % (100 * v[0] / tot_b), v[1], '%.1f%%' % (100 * v[1] / max(tot_n, 1))) for k, v in sorted(by_caller.items(), key=lambda kv: -kv[1][0])[:TOP]], ['caller', 'MB', 'share', 'blocks', 'share'])
table('Volume by mechanism, owner, caller', [(k[0], k[1], k[2], '%.1f' % (v[0] / 1e6), '%.1f%%' % (100 * v[0] / tot_b), v[1]) for k, v in sorted(by_mc.items(), key=lambda kv: -kv[1][0])[:TOP * 2]], ['mechanism', 'owner', 'caller', 'MB', 'share', 'blocks'])
table('Blocks by mechanism, owner, caller', [(k[0], k[1], k[2], v[1], '%.1f%%' % (100 * v[1] / max(tot_n, 1)), '%.1f' % (v[0] / 1e6)) for k, v in sorted(by_mc.items(), key=lambda kv: -kv[1][1])[:TOP * 2]], ['mechanism', 'owner', 'caller', 'blocks', 'share', 'MB'])
cs = {int(k): v for k, v in res['copies_site'].items()}
crow = []
for sid, (b, nb) in sorted(cs.items(), key=lambda kv: -kv[1][0]):
    mech, caller, chain = info.get(sid) or site_info(sid)
    if 'reallocSlice' not in chain and 'grow' not in chain:
        continue
    crow.append((owner_name(sites[sid][0]), caller, '%.1f' % (b / 1e6), nb))
table('Bytes copied by growth that moved a block (reallocSlice)', crow[:TOP], ['owner', 'caller', 'MB', 'moves'])
print('\ncopied in all: %.1f MB' % (sum(float(r[2]) for r in crow) ))

# Samples.
ips = []
for ev, rows in res['samples'].items():
    ips += [int(r[3], 16) for r in rows]
isym = symbolize(ips, ret=False)


def ip_fn(ip):
    ch = isym.get(ip) or [('?', '?', '?')]
    fn, f, loc = ch[0]
    return short(fn) + ' (' + f + ')'


for ev, rows in res['samples'].items():
    tot = sum(r[4] for r in rows)
    print('\n# %s: %d samples' % (ev, tot))
    reg = collections.Counter(); own = collections.Counter(); mc = collections.Counter(); fn = collections.Counter(); oc = collections.Counter()
    for r, o, st, ip, c in rows:
        reg[r] += c
        on = owner_name(o)
        if r == 'table':
            on = owner_name(o)
        own[on] += c
        mech, caller, _ = info.get(st) or site_info(st)
        k = mechanism_class(mech, on) if st >= 0 else r
        mc[k] += c
        oc[(on, caller if st >= 0 else '-')] += c
        fn[ip_fn(int(ip, 16))] += c
    table(ev + ' by region', [(k, v, '%.1f%%' % (100 * v / tot)) for k, v in reg.most_common()], ['region', 'samples', 'share'])
    table(ev + ' by owner', [(k, v, '%.1f%%' % (100 * v / tot)) for k, v in own.most_common(TOP)], ['owner', 'samples', 'share'])
    table(ev + ' by owner and allocating caller', [(k[0], k[1], v, '%.1f%%' % (100 * v / tot)) for k, v in oc.most_common(TOP)], ['owner', 'caller', 'samples', 'share'])
    table(ev + ' by kind of block', [(k, v, '%.1f%%' % (100 * v / tot)) for k, v in mc.most_common(TOP)], ['kind', 'samples', 'share'])
    table(ev + ' by sampled function (innermost inlined frame)', [(k, v, '%.1f%%' % (100 * v / tot)) for k, v in fn.most_common(TOP)], ['function', 'samples', 'share'])
