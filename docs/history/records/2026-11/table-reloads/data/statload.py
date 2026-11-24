#!/usr/bin/env python3
# statload.py OBJDUMP_TXT LO HI: per function, loads (memory source operands) and those whose displacement is in [LO,HI)
# (the Checker's store Table heads), from `objdump -d --no-show-raw-insn` text.
import sys, re, collections
lo, hi = int(sys.argv[2], 16), int(sys.argv[3], 16)
fn = None; st = collections.defaultdict(lambda: [0, 0, 0])
memsrc = re.compile(r'^\s*[0-9a-f]+:\s+(\w+)\s+(-?0x[0-9a-f]+|-?\d+)?\((%\w+)(,%\w+)?(,\d)?\),')
for l in open(sys.argv[1], errors='replace'):
    m = re.match(r'^[0-9a-f]+ <(.*)>:', l)
    if m: fn = m.group(1); continue
    if fn is None or ':' not in l: continue
    st[fn][0] += 1
    m = memsrc.match(l)
    if not m: continue
    op = m.group(1)
    if op.startswith('lea') or op.startswith('nop') or op.startswith('prefetch'): continue
    st[fn][1] += 1
    d = m.group(2)
    if d and m.group(4) is None:
        v = int(d, 16) if 'x' in d else int(d)
        if lo <= v < hi: st[fn][2] += 1
tot = [0, 0, 0]
rows = sorted(st.items(), key=lambda kv: -kv[1][0])
for f, (n, ld, sb) in rows:
    for i, x in enumerate((n, ld, sb)): tot[i] += x
print(f'all: insns {tot[0]} loads {tot[1]} store-head loads {tot[2]} ({100*tot[2]/max(1,tot[1]):.1f}% of loads)')
for f, (n, ld, sb) in rows[:40]:
    print(f'{n:7d} {ld:6d} {sb:5d} {100*sb/max(1,ld):5.1f}%  {f[:90]}')
