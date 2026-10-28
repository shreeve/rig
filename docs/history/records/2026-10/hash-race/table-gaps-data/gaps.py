import sys
rows=[]
for l in open(sys.argv[1]):
    p=l.split()
    if len(p)<6 or p[0]=='keys': continue
    try: rh,zh,rf,zo=map(float,p[2:6])
    except: continue
    rows.append((p[0],p[1],rh,zh,rf,zo))
for name,L in (("HashMap/zig-hash",[(k,o,rh/zh) for k,o,rh,zh,rf,zo in rows]),("Map/zig-ordered",[(k,o,rf/zo) for k,o,rh,zh,rf,zo in rows])):
    bad=sorted([x for x in L if x[2]>1.03],key=lambda x:-x[2])
    print(f"{name}: {len(L)} rows, {len(bad)} >3% behind")
    print("  "+", ".join(f"{k} {o} {r:.2f}" for k,o,r in bad))
