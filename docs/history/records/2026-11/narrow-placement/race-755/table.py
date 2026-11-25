import sys, statistics as st, collections as C  # table.py RUNS: race 755's tables (medians of rounds 1-10; round 0 is a warm-up)
rows=C.defaultdict(list)
for line in open(sys.argv[1]):
    if line.startswith('#') or not line.strip(): continue
    f=line.split(); proj=f[0]; kv=dict(x.split('=',1) for x in f[1:] if '=' in x)
    if kv['round']=='0': continue
    arm=kv['arm']; a,c=arm[0],arm[1:]
    rows[(proj,a,c)].append(kv)
projs=sorted({k[0] for k in rows}); arms="MWSPFQ"
def med(p,a,c,key,scale=1): return st.median(float(r[key])*scale for r in rows[(p,a,c)])
out=[]
out.append("| c | arm | summed wall (ratio to M) | parse+bind (ms) | check (ms) | peak RSS (ratio to M) |")
out.append("|---|---|---:|---:|---:|---:|")
for c in "248":
    base={}
    for a in arms:
        w=sum(med(p,a,c,'wall_ms') for p in projs)
        pb=sum(med(p,a,c,'parse',1000)+med(p,a,c,'bind',1000) for p in projs)
        ck=sum(med(p,a,c,'check',1000) for p in projs)
        rss=sum(med(p,a,c,'rss_kb') for p in projs)
        if a=='M': base=dict(w=w,rss=rss)
        out.append(f"| c{c} | {a} | {w:.0f} ms ({w/base['w']:.3f}) | {pb:.0f} | {ck:.0f} | {rss/base['rss']:.3f} |")
print("\n".join(out))
print()
# c4 per project wall, nuxt & webpack check
print("| project | " + " | ".join(arms) + " |"); print("|---|"+"---:|"*6)
for p in projs:
    m=med(p,'M','4','wall_ms')
    print(f"| {p} | {m:.0f} | " + " | ".join(f"{med(p,a,'4','wall_ms')/m:.3f}" for a in arms[1:]) + " |")
print()
for p in ("nuxt","webpack"):
  for a in arms:
    ck=sorted(float(r['check'])*1000 for r in rows[(p,a,'4')])
    print(p,a,"check median %.0f"%st.median(ck), "runs", " ".join("%.0f"%x for x in ck))
