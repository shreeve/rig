#!/usr/bin/env python3
"""chk.py BIN IPS [TOP]: every conditional jump in BIN whose target reaches
a panic (a call to a Rig or Zig panic function within a few instructions,
through at most one jmp) is a check, of the kind its panic names. With
IPS, precisely sampled retired instructions (one address a line), prints
each kind's share of all samples, counting the jump and the instruction
before it (the compare or the arithmetic that sets its flags), and the
TOP sites by samples with their innermost inline frame."""
import sys, re, subprocess, collections
bin_, ips = sys.argv[1], sys.argv[2]
TOP = int(sys.argv[3]) if len(sys.argv) > 3 else 40
KIND = [
    ('bounds', r'rig\.runtime\.(indexPanic|slicePanic|lenPanic|bytesPanic|String\.keepPanic)|FullPanic.*\.(outOfBounds|startGreaterThanEnd|sentinelMismatch|forLenMismatch|copyLenMismatch)'),
    ('overflow', r'FullPanic.*\.(integerOverflow|shlOverflow|divideByZero|exactDivisionRemainder)'),
    ('cast', r'FullPanic.*\.(integerOutOfBounds|integerPartOutOfBounds|castTruncatedData|negativeToUnsigned|sliceCastLenRemainder|incorrectAlignment)'),
    ('optional', r'FullPanic.*\.(unwrapNull|castToNull)'),
    ('error', r'FullPanic.*\.(unwrapError|invalidErrorCode|unexpectedErrorCode)'),
    ('tag', r'FullPanic.*\.(invalidEnumValue|corruptSwitch|inactiveUnionField)'),
    ('table full', r'rig\.table\.fullPanic'),
    ('unreachable', r'FullPanic.*\.reachedUnreachable'),
    ('other panic', r'[Pp]anic'),
]
def kind_of(name):
    for k, rx in KIND:
        if re.search(rx, name): return k
    return None
d = subprocess.run(['objdump', '-d', '--no-show-raw-insn', bin_], capture_output=True, text=True).stdout
ins = []  # (addr, text)
for l in d.splitlines():
    m = re.match(r'\s*([0-9a-f]+):\s+(.*)', l)
    if m: ins.append((int(m.group(1), 16), m.group(2).strip()))
idx = {a: i for i, (a, _) in enumerate(ins)}
def reaches(a, hops=1):
    i = idx.get(a)
    if i is None: return None
    for j in range(i, min(i + 14, len(ins))):
        t = ins[j][1]
        if t.startswith('call'):
            m = re.search(r'<(.*?)>', t)
            return kind_of(m.group(1)) if m else None
        if t.startswith('jmp'):
            m = re.match(r'jmp\s+([0-9a-f]+)', t)
            return reaches(int(m.group(1), 16), hops - 1) if m and hops > 0 else None
        if t.startswith('ret'): return None
    return None
cnt = collections.Counter(int(l, 16) for l in open(ips) if l.strip())
tot = sum(cnt.values())
sites = {}  # jcc addr -> kind
for i, (a, t) in enumerate(ins):
    m = re.match(r'j(?!mp)[a-z]+\s+([0-9a-f]+)', t)
    if not m: continue
    k = reaches(int(m.group(1), 16))
    if k: sites[a] = k
static = collections.Counter(sites.values())
dyn = collections.Counter(); dynj = collections.Counter(); per = collections.Counter()
for a, k in sites.items():
    i = idx[a]; prev = ins[i - 1][0]
    n = cnt.get(a, 0) + cnt.get(prev, 0)
    dyn[k] += n; dynj[k] += cnt.get(a, 0); per[a] = n
print(f'# {tot} samples; {len(sites)} check sites')
print(f'{"kind":12s} {"sites":>7s} {"jump+flag setter":>17s} {"jump alone":>11s}')
for k, _ in KIND:
    print(f'{k:12s} {static[k]:7d} {100*dyn[k]/tot:16.2f}% {100*dynj[k]/tot:10.2f}%')
print(f'{"all":12s} {len(sites):7d} {100*sum(dyn.values())/tot:16.2f}% {100*sum(dynj.values())/tot:10.2f}%')
top = [a for a, _ in per.most_common(TOP)]
p = subprocess.run(['/usr/lib/llvm-22/bin/llvm-symbolizer', f'--obj={bin_}', '--inlines', '--functions=linkage', '--demangle'],
                   input='\n'.join(hex(a) for a in top) + '\n', capture_output=True, text=True)
for a, b in zip(top, p.stdout.strip('\n').split('\n\n')):
    ls = b.split('\n'); fr = [(ls[i], ls[i+1].split('/')[-1]) for i in range(0, len(ls) - 1, 2)]
    i = idx[a]
    chain = ' < '.join(f'{f.split(".")[-1]}@{loc.rsplit(":",1)[0]}' for f, loc in fr[:3])
    print(f'{100*per[a]/tot:5.2f}% {sites[a]:9s} {ins[i-1][1][:28]:28s} | {ins[i][1][:10]:10s} {chain[:150]}')

# The Trig line each check sits on: the innermost frame outside the
# runtime, std's Zig and table.zig, aggregated by line, per kind.
if len(sys.argv) > 4:
    pkg = sys.argv[4]
    allsites = [a for a in per if per[a] > 0]
    p = subprocess.run(['/usr/lib/llvm-22/bin/llvm-symbolizer', f'--obj={bin_}', '--inlines', '--functions=linkage'],
                       input='\n'.join(hex(a) for a in allsites) + '\n', capture_output=True, text=True)
    byline = collections.defaultdict(collections.Counter)
    for a, b in zip(allsites, p.stdout.strip('\n').split('\n\n')):
        ls = b.split('\n'); fr = [(ls[i], ls[i+1]) for i in range(0, len(ls) - 1, 2)]
        loc = None
        for f, l in fr:
            fn = l.split('/')[-1]
            if not re.match(r'(runtime|table|ordered|unordered|alloc|sched|enums|math|mem|meta)\.zig', fn):
                loc = fn.rsplit(':', 1)[0]; break
        byline[sites[a]][loc or '?'] += per[a]
    for k in ('bounds', 'overflow', 'cast', 'tag', 'other panic', 'table full'):
        tot_k = sum(byline[k].values())
        print(f'\n## {k}: {100*tot_k/tot:.2f}% in {len(byline[k])} lines; the top lines')
        for loc, n in byline[k].most_common(int(sys.argv[5]) if len(sys.argv) > 5 else 25):
            src = ''
            if ':' in loc:
                f, ln = loc.split(':')
                try: src = open(f'{pkg}/{f}').read().split('\n')[int(ln) - 1].strip()
                except Exception: src = ''
            print(f'{100*n/tot:5.2f}% {loc:22s} {src[:170]}')
