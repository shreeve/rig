import sys, glob, collections, os
d = collections.defaultdict(lambda: collections.defaultdict(list))
for f in glob.glob(sys.argv[1] + '/*.txt'):
    n = os.path.basename(f).rsplit('.', 2)[0]
    for l in open(f):
        p = l.split(); d[n][p[0] + ' ' + p[1]].append(int(p[2]) / 1e6)
rows = ['pair insert', 'pair hit', 'pair miss', 'triple insert', 'triple hit', 'triple miss']
print('%-34s' % 'ms, fastest of N' + ''.join('%14s' % r for r in rows))
for n in sorted(d):
    print('%-34s' % n + ''.join('%14.2f' % min(d[n][r]) for r in rows))
