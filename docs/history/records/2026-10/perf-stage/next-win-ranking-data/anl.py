import statistics as st
d={}
for l in open("lazy.txt"):
    if l.startswith("#"): print(l.strip()); continue
    p,r,v,c,i,m=l.split(); d.setdefault((p,v),[]).append((int(c),int(i),int(m)))
for p in ["mitt","neverthrow","superstruct","tiny-invariant","zod3","ts-pattern"]:
    b=[st.median(x[k] for x in d[(p,"bar")]) for k in range(3)]
    for v in ["lm","nodts"]:
        e=[st.median(x[k] for x in d[(p,v)]) for k in range(3)]
        print("%-15s %-6s cycles %+.1f%%  instr %+.1f%%  rss %+.1f%% (bar %.0fMc %.1fMB)" % (p,v,100*(e[0]/b[0]-1),100*(e[1]/b[1]-1),100*(e[2]/b[2]-1),b[0]/1e6,b[2]/1024))
