import sys, collections, re
# cmp.py A_FILES... -- B_FILES...: fastest of N per row, B against A
def load(fs):
    best = {}
    order = []
    for f in fs:
        for l in open(f):
            p = l.split()
            # row name: leading words until a float
            for k in range(len(p)):
                try:
                    v = float(p[k]); break
                except ValueError: pass
            else: continue
            name = ' '.join(p[:k])
            if name not in best: order.append(name); best[name] = v
            else: best[name] = min(best[name], v)
    return best, order
i = sys.argv.index('--')
a, order = load(sys.argv[1:i]); b, _ = load(sys.argv[i+1:])
for n in order:
    if n in b and a[n] > 0:
        r = b[n] / a[n]
        print('%-28s %10.4f %10.4f  %s' % (n, a[n], b[n], ('%.1f%% faster' % (100*(1-r))) if r < 1 else ('%.1f%% slower' % (100*(r-1)))))
