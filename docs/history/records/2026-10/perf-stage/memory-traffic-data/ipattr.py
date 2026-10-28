#!/usr/bin/env python3
# ipattr.py BIN SAMPLES... : perf-script samples ("TIME EVENT: ADDR IP"),
# per event, by the sampled instruction's innermost inlined frame, and by
# that frame with the function it is inlined into (llvm-symbolizer
# --inlines). For a binary without symbols the rows are raw addresses.
import sys, subprocess, collections, re
b = sys.argv[1]
ev_ips = collections.defaultdict(collections.Counter)
import os
for p in sys.argv[2:]:
    # A position-independent binary's load address, from the run's
    # mmap events (pebs.sh writes it beside the samples).
    bp = p[:-len('.samples')] + '.bias'
    bias = int(open(bp).read().strip() or '0', 16) if os.path.exists(bp) else 0
    for line in open(p, errors='replace'):
        f = line.split()
        if len(f) < 4: continue
        try: ev_ips[f[1].rstrip(':')][int(f[3], 16) - bias] += 1
        except ValueError: pass
ips = sorted({ip for c in ev_ips.values() for ip in c})
q = '\n'.join('0x%x' % i for i in ips) + '\n'
out = subprocess.run(['/usr/bin/llvm-symbolizer-22', '--inlines', '--obj=' + b], input=q, capture_output=True, text=True).stdout
sym = {}
for ip, blk in zip(ips, out.split('\n\n')):
    ls = [l for l in blk.strip().split('\n') if l]
    sym[ip] = [(re.sub(r'__rig_m\d+_', '', ls[k])[:90], ls[k + 1].split('/')[-1]) for k in range(0, len(ls) - 1, 2)]
for ev, c in ev_ips.items():
    tot = sum(c.values())
    inner = collections.Counter(); pair = collections.Counter()
    for ip, n in c.items():
        ch = sym.get(ip) or [('?', '?')]
        inner[ch[0][0]] += n
        pair[(ch[0][0] + ' @ ' + ch[0][1].split(':')[0], ch[1][0] if len(ch) > 1 else '-')] += n
    print('\n## %s: %d samples\n\n| innermost function | samples | share |\n|---|---:|---:|' % (ev, tot))
    for k, n in inner.most_common(30): print('| %s | %d | %.1f%% |' % (k, n, 100 * n / tot))
    print('\n| innermost frame | inlined into | samples | share |\n|---|---|---:|---:|')
    for (k, k2), n in pair.most_common(30): print('| %s | %s | %d | %.1f%% |' % (k, k2, n, 100 * n / tot))
