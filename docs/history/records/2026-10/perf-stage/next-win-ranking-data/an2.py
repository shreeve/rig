import statistics as st
d={}
for f in ["stat1.txt","stat2.txt"]:
  for l in open(f):
    p,r,v,c,i=l.split(); d.setdefault((p,v),[]).append((int(c),int(i)))
for p in ["mitt","zod3","tiny-invariant","ts-pattern"]:
    m={v:(st.median(c for c,i in d[(p,v)]),st.median(i for c,i in d[(p,v)])) for v in ["plain","pgo","local","shipped"]}
    s=" ".join("%s=%.0fMc/%.0fMi" % (v,m[v][0]/1e6,m[v][1]/1e6) for v in m)
    print(p, s, "| tsrs build %.1f%% fewer cyc; Trig PGO %.1f%%; plain/local %.3f; pgo/shipped %.3f" % (100*(1-m["shipped"][0]/m["local"][0]),100*(1-m["pgo"][0]/m["plain"][0]), m["plain"][0]/m["local"][0], m["pgo"][0]/m["shipped"][0]))
