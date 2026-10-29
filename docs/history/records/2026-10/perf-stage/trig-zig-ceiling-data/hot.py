#!/usr/bin/env python3
"""hot.py BIN IPS SYM [N]: the disassembly of function SYM (outermost
symbol), each instruction with its sample count from IPS and the innermost
inline frame's function and file:line, for the N hottest instructions'
neighbourhoods (whole function when N is 0)."""
import sys, subprocess, collections, re
bin_, ips, sym = sys.argv[1], sys.argv[2], sys.argv[3]
N = int(sys.argv[4]) if len(sys.argv) > 4 else 0
cnt = collections.Counter(int(l.strip(), 16) for l in open(ips) if l.strip())
tot = sum(cnt.values())
nm = subprocess.run(['nm', '-S', '--defined-only', bin_], capture_output=True, text=True).stdout
lo = hi = None
for l in nm.splitlines():
    p = l.split(None, 3)
    if len(p) == 4 and p[3] == sym:
        lo = int(p[0], 16); hi = lo + int(p[1], 16); break
if lo is None: sys.exit('no symbol ' + sym)
d = subprocess.run(['objdump', '-d', '--no-show-raw-insn', f'--start-address={lo:#x}', f'--stop-address={hi:#x}', bin_], capture_output=True, text=True).stdout
ins = []
for l in d.splitlines():
    m = re.match(r'\s*([0-9a-f]+):\s+(.*)', l)
    if m: ins.append((int(m.group(1), 16), m.group(2).strip()))
addrs = [a for a, _ in ins]
p = subprocess.run(['/usr/lib/llvm-22/bin/llvm-symbolizer', f'--obj={bin_}', '--inlines', '--functions=linkage', '--demangle'],
                   input='\n'.join(hex(a) for a in addrs) + '\n', capture_output=True, text=True)
blocks = p.stdout.strip('\n').split('\n\n')
src = {}
for a, b in zip(addrs, blocks):
    ls = b.split('\n'); fn = ls[0].split('.')[-1][:28]; loc = ls[1].split('/')[-1]
    depth = len(ls) // 2
    src[a] = f'{fn}@{loc.rsplit(":",1)[0]}'
fs = sum(cnt[a] for a in addrs)
print(f'# {sym}: {fs} samples of {tot} ({100*fs/tot:.2f}%), {len(ins)} instructions')
show = set(range(len(ins)))
if N:
    hot = sorted(range(len(ins)), key=lambda i: -cnt[ins[i][0]])[:N]
    show = set(j for i in hot for j in range(max(0, i-4), min(len(ins), i+3)))
last = -2
for i, (a, t) in enumerate(ins):
    if i not in show: continue
    if i != last + 1: print('   ...')
    c = cnt[a]
    print(f'{c:5d} {a:x}  {t[:60]:60s} {src[a]}')
    last = i
