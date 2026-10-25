#!/usr/bin/env python3
# sites.py BIN PERF_SCRIPT_IPS OUT: find every conditional branch into a block that calls a
# safety-panic handler (a check site), count perf samples on the branch or the instruction
# just before it, and attribute each sampled site to its innermost source frame (addr2line -i).
import sys, re, subprocess, collections
binp, ipsf, outp = sys.argv[1:4]
KIND = [('indexPanic', 'index'), ('slicePanic', 'index'), ('lenPanic', 'cast'), ('integerOutOfBounds', 'cast'),
        ('integerPartOutOfBounds', 'cast'), ('castToNull', 'cast'), ('integerOverflow', 'overflow'),
        ('shlOverflow', 'overflow'), ('shrOverflow', 'overflow'), ('outOfBounds', 'bounds'),
        ('startGreaterThanEnd', 'bounds'), ('inactiveUnionField', 'union'), ('corruptSwitch', 'union'),
        ('unwrapNull', 'unwrap'), ('unwrapError', 'unwrap'), ('memcpyAlias', 'other'), ('incorrectAlignment', 'other'),
        ('divideByZero', 'other'), ('reachedUnreachable', 'other'), ('defaultPanic', 'panic'), ('proofPanic', 'other')]
def kind_of(sym):
    for k, v in KIND:
        if k in sym: return v
    return None
lines = subprocess.run(['objdump', '-d', '--no-show-raw-insn', '-C', binp], capture_output=True, text=True).stdout.split('\n')
insts = []  # (addr, text)
for l in lines:
    m = re.match(r'^\s*([0-9a-f]+):\s+(.*)$', l)
    if m: insts.append((int(m.group(1), 16), m.group(2).strip()))
pos = {a: i for i, (a, _) in enumerate(insts)}
def handler_at(addr):
    i = pos.get(addr)
    if i is None: return None
    for j in range(i, min(i + 8, len(insts))):
        t = insts[j][1]
        if t.startswith('call'):
            return kind_of(t)
        if t.startswith(('ret', 'jmp')): return None
    return None
sites = {}  # jcc addr -> (kind, prev addr)
for i, (a, t) in enumerate(insts):
    m = re.match(r'^j(?!mp)[a-z]+\s+([0-9a-f]+)', t)
    if not m: continue
    k = handler_at(int(m.group(1), 16))
    if k: sites[a] = (k, insts[i - 1][0] if i else a)
print('sites', len(sites), collections.Counter(k for k, _ in sites.values()).most_common(), file=sys.stderr)
byaddr = {}
for a, (k, p) in sites.items():
    byaddr[a] = a; byaddr[p] = a
samples = collections.Counter(); total = 0
for l in open(ipsf):
    l = l.strip()
    if not l: continue
    try: ip = int(l.split()[-1], 16)
    except ValueError: continue
    total += 1
    s = byaddr.get(ip)
    if s is not None: samples[s] += 1
hit = sorted(samples, key=lambda a: -samples[a])
frames = {}
if hit:
    top = hit[:3000]
    o = subprocess.run(['addr2line', '-a', '-i', '-f', '-C', '-e', binp] + ['0x%x' % a for a in top], capture_output=True, text=True).stdout.split('\n')
    cur = None; fr = []
    def flush():
        if cur is None: return
        fns = fr[0::2]; locs = fr[1::2]
        # the first frame outside Rig's runtime and Zig's std: the program's (or std.rig's) code
        k = next((j for j, f in enumerate(fns) if not f.startswith(('rig.runtime', 'rig.table', 'debug.', 'math.', 'mem.'))), 0)
        frames[cur] = (fns[k] if fns else '?', locs[k] if k < len(locs) else '?', ' < '.join(fns[:6]))
    for l in o:
        if re.match(r'^0x[0-9a-f]+$', l):
            flush(); cur = int(l, 16); fr = []
        elif l: fr.append(l)
    flush()
with open(outp, 'w') as f:
    f.write('total_samples\t%d\n' % total)
    for a in hit:
        fn, loc, outer = frames.get(a, ('?', '?', '?'))
        f.write('%x\t%d\t%s\t%s\t%s\t%s\n' % (a, samples[a], sites[a][0], fn, loc, outer))
print('total samples', total, 'on sites', sum(samples.values()), file=sys.stderr)
