#!/usr/bin/env python3
# abrows.py REPS LABEL=EXE ...: run each bench/hash executable REPS times,
# interleaved, pinned by the caller; print the fastest ns/op of each row
# for each, and the change of each against the first.
import sys, subprocess, collections
reps = int(sys.argv[1]); vs = [a.split('=', 1) for a in sys.argv[2:]]
best = collections.defaultdict(dict); order = []; checks = {}
for r in range(reps):
    for lab, exe in (vs[r % len(vs):] + vs[:r % len(vs)]):
        p = subprocess.run([exe], capture_output=True, text=True, check=True)
        for line in (p.stdout + p.stderr).splitlines():
            k, op, ns, ck = line.split()
            row = (k, op)
            if row not in order: order.append(row)
            ns = int(ns); best[row][lab] = min(best[row].get(lab, ns), ns)
            checks.setdefault(row, ck)
            if checks[row] != ck: print('CHECK MISMATCH', row, lab)
labs = [l for l, _ in vs]
print('%-10s %-18s' % ('keys', 'op') + ''.join('%12s' % l for l in labs))
for row in order:
    b = best[row]; base = b[labs[0]]
    out = '%-10s %-18s' % row + ''.join(('%12.2f' % (b[l] / 1e6)) if l in b else '%12s' % '-' for l in labs)
    for l in labs[1:]:
        if l not in b: continue
        d = b[l] / base - 1
        out += '  %s %.1f%% %s' % (l, abs(d) * 100, 'slower' if d > 0 else 'faster')
    print(out)
