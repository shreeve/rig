import random, subprocess, sys
rows=[("sint","sorted",16),("sstr","sorted",4096),("sstr","sorted",65536),("rec","rev",16),("sint","rand",16),("rec","rand",65536)]
arms=["old","new"]
best={}
for rnd in range(20):
    jobs=[(a,k,p,n) for a in arms for (k,p,n) in rows]; random.shuffle(jobs)
    for a,k,p,n in jobs:
        v=float(subprocess.run([f"./rsort-{a}",k,p,str(n),"3"],capture_output=True,text=True).stdout.split()[-1])
        best[(k,p,n,a)]=min(best.get((k,p,n,a),v),v)
for (k,p,n) in rows:
    o,b=best[(k,p,n,"old")],best[(k,p,n,"new")]
    print(k,p,n,f"old {o:.3f} branch {b:.3f} ratio {b/o:.3f}")
