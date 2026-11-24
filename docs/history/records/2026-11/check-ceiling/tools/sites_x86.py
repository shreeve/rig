#!/usr/bin/env python3
# sites_x86.py DIS REPORT BIN OUT.tsv: sites.py for x86-64 Linux: every conditional jump to a panic
# (a block that calls a panic function or reaches ud2 within 4 instructions, with no jump or ret
# before it) in each profiled function, weighted by the function's self samples (perf report
# `--sort sym -F overhead,sample,sym`, summed over runs) over its instructions, with the inline
# chain `addr2line -i` gives (innermost first), in sites.py's row format.
import sys, re, collections, subprocess
dis, rep, binp, outp = sys.argv[1:5]
samples = collections.Counter()
for line in open(rep, errors='replace'):
    m = re.match(r'\s*[\d.]+%\s+(\d+)\s+\[\.\]\s+(.*\S)\s*$', line)
    if m: samples[m.group(2)] += int(m.group(1))
fre = re.compile(r'^([0-9a-f]+) <(.*)>:$')
ire = re.compile(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$')
PANIC = re.compile(r'Panic|panic|oom\b|FullPanic')
COND = re.compile(r'^j(?!mp)[a-z]+$')
funcs = []; cur = None
for line in open(dis, errors='replace'):
    m = fre.match(line)
    if m:
        cur = [m.group(2), []] if m.group(2) in samples else None
        if cur: funcs.append(cur)
        continue
    if cur is None: continue
    m = ire.match(line)
    if m: cur[1].append((int(m.group(1), 16), m.group(2), m.group(3)))
def norm(name):
    name = re.sub(r'\+0x[0-9a-f]+$', '', name)
    name = name.replace("debug.FullPanic((function 'panicAfterFlush')).", 'zig.')
    return re.sub(r'__func_\d+', '', name).replace('rig.runtime.', '')
def kind_at(idx, ins):
    for k in range(idx, min(idx + 5, len(ins))):
        a, op, rest = ins[k]
        if op == 'ud2': return 'brk'
        if op.startswith('call'):
            m = re.search(r'<(.*)>', rest); name = m.group(1) if m else rest
            return norm(name) if PANIC.search(name) else None
        if op.startswith('jmp') or op.startswith('ret') or COND.match(op): return None
    return None
rows = []
for name, ins in funcs:
    pos = {a: i for i, (a, _, _) in enumerate(ins)}
    for a, op, rest in ins:
        if not COND.match(op): continue
        m = re.match(r'([0-9a-f]+)', rest)
        if not m: continue
        t = int(m.group(1), 16)
        if t in pos:
            k = kind_at(pos[t], ins)
            if k and k != 'brk': rows.append((name, samples[name], len(ins), a, k))
# addr2line -a -i -f: the address, then (function, file:line) per inline level, innermost first.
p = subprocess.run(['addr2line', '-a', '-i', '-f', '-e', binp], input='\n'.join('0x%x' % r[3] for r in rows), capture_output=True, text=True)
blocks = []; curb = None
for l in p.stdout.split('\n'):
    if re.match(r'^0x[0-9a-f]+$', l):
        curb = []; blocks.append(curb)
    elif curb is not None and l: curb.append(l)
assert len(blocks) == len(rows), (len(blocks), len(rows))
with open(outp, 'w') as o:
    for r, b in zip(rows, blocks):
        chain = []
        for i in range(0, len(b) - 1, 2):
            fn, loc = b[i], b[i + 1]
            loc = re.sub(r' \(discriminator \d+\)', '', loc)
            f = loc.rsplit('/', 1)[-1]
            chain.append('%s@%s' % (re.sub(r'__func_\d+', '', fn), f))
        o.write('%s\t%d\t%d\t0x%x\t%s\t%s\n' % (r[0], r[1], r[2], r[3], r[4], ' < '.join(chain)))
print(len(rows), 'branches in', len(funcs), 'functions')
