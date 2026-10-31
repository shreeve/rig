#!/usr/bin/env python3
# kt.py ROUNDS INPUT name=cmd ...: interleaved; parses "k1 N k2 N k4 N" (us) from stderr; min of each
import os, sys, re, shlex, subprocess
rounds = int(sys.argv[1]); inp = sys.argv[2]; arms = [a.split('=', 1) for a in sys.argv[3:]]
res = {n: {} for n, _ in arms}
for r in range(rounds):
    for n, c in arms:
        with open(inp, 'rb') as f:
            p = subprocess.run(shlex.split(c), stdin=f, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        for k, v in re.findall(r'(k\d+)\s+(\d+)', p.stderr):
            res[n].setdefault(k, []).append(int(v))
print('uptime:', os.popen('uptime').read().strip())
base = None
for n, _ in arms:
    d = res[n]
    row = '  '.join(f"{k} {min(v)/1000:7.1f}" for k, v in d.items())
    print(f"{n:16s} {row}")
