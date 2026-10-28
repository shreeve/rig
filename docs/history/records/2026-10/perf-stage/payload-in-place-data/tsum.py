import sys, re, statistics as st
rows = {}
bad = 0
for line in open(sys.argv[1]):
    f = dict(kv.split('=') for kv in line.split()[1:])
    p = line.split()[0]
    if f.get('same') == '0': bad += 1
    rows.setdefault((p, f['build']), []).append(f)
keys = ['ucycles', 'kcycles', 'instructions', 'stfwd', 'faults', 'secs', 'rss_kb']
for p in ['ts-pattern', 'zod3']:
    if (p, 'main') not in rows: continue
    print(f"## {p} ({len(rows[(p,'main')])} rounds)")
    print("| metric | main median | new median | new vs main |")
    print("|---|---:|---:|---|")
    for k in keys:
        m = [float(r[k]) for r in rows[(p, 'main')]]
        n = [float(r[k]) for r in rows[(p, 'new')]]
        mm, nm = st.median(m), st.median(n)
        d = (nm - mm) / mm * 100
        word = 'fewer' if k not in ('secs',) else 'faster'
        if k == 'secs':
            desc = f"{abs(d):.1f}% {'faster' if d < 0 else 'slower'} (fastest: {min(m):.3f} vs {min(n):.3f}, {abs((min(n)-min(m))/min(m)*100):.1f}% {'faster' if min(n) < min(m) else 'slower'})"
        elif k == 'rss_kb':
            desc = f"{abs(d):.1f}% {'lower' if d < 0 else 'higher'}"
        else:
            desc = f"{abs(d):.1f}% {'fewer' if d < 0 else 'more'}"
        fmt = (lambda x: f"{x:,.0f}") if k != 'secs' else (lambda x: f"{x:.3f}")
        print(f"| {k} | {fmt(mm)} | {fmt(nm)} | {desc} |")
print("outputs differing:", bad)
