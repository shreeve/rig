#!/usr/bin/env python3
# panics.py DIS [FUNC_REGEX]: per function, instructions, conditional branches, and the conditional
# branches that go to a panic (a block that reaches a `bl` to a panic function or a `brk`
# within 4 instructions, with no branch or ret before it), by panic kind.
import sys, re, collections
dis = sys.argv[1]; pat = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
fre = re.compile(r'^([0-9a-f]+) <(.*)>:$')
ire = re.compile(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$')
PANIC = re.compile(r'Panic|panic|oom\b|FullPanic')
funcs = []; cur = None
for line in open(dis, errors='replace'):
    m = fre.match(line)
    if m: cur = [m.group(2), []]; funcs.append(cur); continue
    m = ire.match(line)
    if m and cur: cur[1].append((int(m.group(1), 16), m.group(2), m.group(3)))
COND = re.compile(r'^(b\.\w+|cbz|cbnz|tbz|tbnz)$')
def kind_at(idx, ins):
    for k in range(idx, min(idx + 5, len(ins))):
        a, op, rest = ins[k]
        if op == 'brk': return 'brk'
        if op == 'bl':
            m = re.search(r'<(.*)>', rest); name = m.group(1) if m else rest
            if PANIC.search(name):
                name = re.sub(r'\+0x[0-9a-f]+$', '', name)
                name = name.replace("_debug.FullPanic((function 'panicAfterFlush')).", 'zig.')
                return re.sub(r'__func_\d+', '', name)
            return None
        if op in ('b', 'ret', 'br') or COND.match(op): return None
    return None
out = []
for name, ins in funcs:
    if pat and not pat.search(name): continue
    pos = {a: i for i, (a, _, _) in enumerate(ins)}
    kinds = collections.Counter(); nb = 0
    for a, op, rest in ins:
        if not COND.match(op): continue
        nb += 1
        m = re.search(r'0x([0-9a-f]+)', rest)
        if not m: continue
        t = int(m.group(1), 16)
        if t in pos:
            k = kind_at(pos[t], ins)
            if k: kinds[k] += 1
    out.append((name, len(ins), nb, kinds))
if __name__ == '__main__':
    tot = collections.Counter(); ni = nb = 0
    for name, n, b, k in out:
        tot.update(k); ni += n; nb += b
    print('functions %d instructions %d cond branches %d to panic %d' % (len(out), ni, nb, sum(tot.values())))
    for k, v in tot.most_common(): print('  %6d %s' % (v, k))
