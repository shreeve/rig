import json, sys, re, collections
res = json.load(open(sys.argv[1]))
tot = sum(r['n'] for r in res)
keys = ['CacheKey,u32', 'InstantiationKey,u32', 'CachedTypeKey,u32']
by = collections.Counter(); byline = collections.Counter(); bymap = collections.Counter()
for r in res:
    fs = r['f']
    if not fs: continue
    # the outermost Ordered frame names the map
    m = None
    for fn, loc in fs:
        mm = re.search(r'Ordered\(checker\.(\w+),(\w+)\)', fn)
        if mm: m = mm.group(1) + ',' + mm.group(2)
    if m is None: continue
    inner = fs[0]
    bymap[m] += r['n']
    if m in keys:
        fn = re.sub(r'rig\.ordered\.Ordered\([^)]*\)\.', '', inner[0])
        fn = re.sub(r'.*runtime\.', 'rt.', fn)
        byline[(m, fn[:50], inner[1])] += r['n']
print('total', tot)
for m, n in bymap.most_common(12): print('%6.2f%% %s' % (100.0 * n / tot, m))
print()
for k, n in byline.most_common(40): print('%6.2f%% %s %s %s' % (100.0 * n / tot, k[0], k[1], k[2]))
