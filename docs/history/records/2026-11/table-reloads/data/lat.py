#!/usr/bin/env python3
# lat.py SCRIPT_TXT BINARY [--min W]: rank sampled loads by the innermost inlined function (the accessor), its
# caller chain head, and the data region, weighted by latency. SCRIPT_TXT: `perf script -F ip,addr,weight` lines
# (ip hex, addr hex, weight). Symbolizes IPs with llvm-symbolizer (inline chains).
import sys, subprocess, collections, argparse
ap = argparse.ArgumentParser(); ap.add_argument('txt'); ap.add_argument('bin'); ap.add_argument('--min', type=int, default=0)
ap.add_argument('--top', type=int, default=40); ap.add_argument('--regions')
a = ap.parse_args()
S = []
for l in open(a.txt, errors='replace'):
    f = l.split()
    if len(f) < 3: continue
    try: ip = int(f[0], 16); ad = int(f[1], 16); w = int(f[2])
    except ValueError: continue
    if w < a.min: continue
    S.append((ip, ad, w))
ips = sorted({s[0] for s in S})
p = subprocess.run(['llvm-symbolizer-22', '--obj=' + a.bin, '--inlining', '--functions=linkage', '--no-demangle'],
                   input='\n'.join(hex(i) for i in ips) + '\n', capture_output=True, text=True)
chains = {}; blocks = p.stdout.strip('\n').split('\n\n')
for ip, b in zip(ips, blocks):
    ls = b.split('\n'); fr = [(ls[i], ls[i + 1]) for i in range(0, len(ls) - 1, 2)]
    chains[ip] = fr
def short(fn): return fn.replace('checker.Checker.', '').replace('rigx_checker__Checker__', '')
tot = sum(w for _, _, w in S)
inner = collections.Counter(); outer = collections.Counter(); pair = collections.Counter(); line = collections.Counter()
for ip, ad, w in S:
    fr = chains.get(ip) or [('?', '?')]
    inn = short(fr[0][0]); out = short(fr[-1][0])
    inner[inn] += w; outer[out] += w; pair[(inn, out)] += w
    line[(inn, fr[0][1].rsplit('/', 1)[-1])] += w
print(f'# {len(S)} samples, weight {tot}')
for title, c in (('innermost function (accessor)', inner), ('outermost (non-inlined) function', outer), ('accessor x function', pair), ('accessor line', line)):
    print(f'## {title}')
    for k, w in c.most_common(a.top): print(f'{100 * w / tot:6.2f}  {k}')
