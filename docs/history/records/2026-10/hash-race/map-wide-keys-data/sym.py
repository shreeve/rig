# sym.py BIN COUNTS OUT: symbolize "count ip" lines with inline chains.
import subprocess, sys, json
b, cf, out = sys.argv[1:4]
rows = [l.split() for l in open(cf)]
ips = [r[1] for r in rows]
p = subprocess.run(['/usr/bin/llvm-symbolizer-22', '--inlines', '--obj=' + b], input='\n'.join('0x' + i for i in ips) + '\n', capture_output=True, text=True)
blocks = p.stdout.split('\n\n')
res = []
for (n, ip), blk in zip(rows, blocks):
    ls = [l for l in blk.strip().split('\n') if l]
    frames = [(ls[k], ls[k + 1].split('/')[-1]) for k in range(0, len(ls) - 1, 2)]
    res.append({'n': int(n), 'ip': ip, 'f': frames})
json.dump(res, open(out, 'w'))
