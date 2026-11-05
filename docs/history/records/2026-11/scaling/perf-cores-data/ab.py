import sys,re,statistics as st,collections
d=collections.defaultdict(list)
for l in open(sys.argv[1]):
    m=re.search(r'c=(\d+) arm=(\w+) load=([\d.]+) wall (\d+) .*pshare ([\d.]+)%.* cpu',l) or re.search(r'c=(\d+) arm=(\w+) load=([\d.]+) wall (\d+) \d+ pcore wall [\d.]+ cpu [\d.]+ p [\d.]+ pshare ([\d.]+)%',l)
    if m: d[(int(m[1]),m[2])].append((int(m[4]),float(m[5]),float(m[3])))
print("c arm n wall_min wall_med pshare_med load_med")
for k in sorted(d):
    v=d[k]; w=[x[0] for x in v]; p=[x[1] for x in v]; ld=[x[2] for x in v]
    print(k[0],k[1],len(v),min(w),st.median(w),round(st.median(p),1),round(st.median(ld),1))
