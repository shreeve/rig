#!/usr/bin/env python3
# sites.py DIS TSV DSYM OUT.tsv: every branch to a panic in each profiled function, with its
# weight (the function's self samples / its instructions, as weighted.py weighs) and the inline
# chain atos gives for the branch (innermost first), so each check is tied to its source line.
import sys, re, collections, subprocess
dis, tsv, dsym, outp = sys.argv[1:5]
samples = {}
for line in open(tsv):
    f = line.rstrip('\n').split('\t')
    if f[0] == 'real': samples[f[3]] = int(f[1])
fre = re.compile(r'^([0-9a-f]+) <(.*)>:$')
ire = re.compile(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$')
PANIC = re.compile(r'Panic|panic|oom\b|FullPanic')
COND = re.compile(r'^(b\.\w+|cbz|cbnz|tbz|tbnz)$')
funcs = []; cur = None
for line in open(dis, errors='replace'):
    m = fre.match(line)
    if m:
        name = m.group(2).lstrip('_')
        cur = [name, []] if name in samples else None
        if cur: funcs.append(cur)
        continue
    if cur is None: continue
    m = ire.match(line)
    if m: cur[1].append((int(m.group(1), 16), m.group(2), m.group(3)))
def kind_at(idx, ins):
    for k in range(idx, min(idx + 5, len(ins))):
        a, op, rest = ins[k]
        if op == 'brk': return 'brk'
        if op == 'bl':
            m = re.search(r'<(.*)>', rest); name = m.group(1) if m else rest
            if PANIC.search(name):
                name = re.sub(r'\+0x[0-9a-f]+$', '', name)
                name = name.replace("_debug.FullPanic((function 'panicAfterFlush')).", 'zig.')
                return re.sub(r'__func_\d+', '', name).replace('__rig.runtime.', '').replace('_rig.runtime.', '')
            return None
        if op in ('b', 'ret', 'br') or COND.match(op): return None
    return None
rows = []
for name, ins in funcs:
    pos = {a: i for i, (a, _, _) in enumerate(ins)}
    for a, op, rest in ins:
        if not COND.match(op): continue
        m = re.search(r'0x([0-9a-f]+)', rest)
        if not m: continue
        t = int(m.group(1), 16)
        if t in pos:
            k = kind_at(pos[t], ins)
            if k and k != 'brk': rows.append((name, samples[name], len(ins), a, k))
addrs = '\n'.join('0x%x' % r[3] for r in rows)
p = subprocess.run(['atos', '-o', dsym, '-arch', 'arm64', '-l', '0x100000000', '-i'], input=addrs, capture_output=True, text=True)
blocks = p.stdout.strip('\n').split('\n\n')
assert len(blocks) == len(rows), (len(blocks), len(rows))
fr = re.compile(r'^(.*) \(in bin\) \((.*)\)$')
with open(outp, 'w') as o:
    for r, b in zip(rows, blocks):
        chain = []
        for l in b.split('\n'):
            m = fr.match(l.strip())
            chain.append('%s@%s' % (re.sub(r'__func_\d+', '', m.group(1)), m.group(2)) if m else l.strip())
        o.write('%s\t%d\t%d\t0x%x\t%s\t%s\n' % (r[0], r[1], r[2], r[3], r[4], ' < '.join(chain)))
print(len(rows), 'branches in', len(funcs), 'functions')
