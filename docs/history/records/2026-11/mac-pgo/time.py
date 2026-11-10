#!/usr/bin/env python3
# Interleaved, shuffled Mac timing: trig-base (a), its copy (b, A/A), trig-pgo (p). Held-out projects.
import os,random,re,statistics as st,subprocess,sys,time,shutil
W=os.path.expanduser('~/Data/Code/Claude/rig/rig/macpgo-trig'); T=os.path.expanduser('~/Data/Code/trig/misc/projects')
D='/tmp/macpgo-arms'; shutil.rmtree(D,ignore_errors=True); os.makedirs(D)
for n,s in (('a','trig-base'),('b','trig-base'),('p','trig-pgo')): shutil.copy2(f'{W}/{s}',f'{D}/{n}')
R=int(sys.argv[1]) if len(sys.argv)>1 else 20
P=[('tiny-invariant','tiny-invariant'),('ts-pattern','ts-pattern'),('contracts','dify/packages/contracts')]
env0=dict(os.environ); out=open(f'{W}/runs.txt','a')
def one(v,proj,cfg,c,libs):
    e=dict(env0); 
    if not libs: e['TRIG_PREBUILT_LIBS']='0'
    a=['-p',cfg,'--noEmit']+(['--singleThreaded'] if c==1 else ['--checkers',str(c)])
    t0=time.perf_counter_ns()
    r=subprocess.run(['/usr/bin/time','-l',f'{D}/{v}']+a,cwd=f'{T}/{proj}',env=e,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
    ms=(time.perf_counter_ns()-t0)/1e6
    g=lambda k: int(re.search(r'(\d+)\s+'+k,r.stderr).group(1))
    return ms,g('instructions retired'),g('cycles elapsed'),g('peak memory footprint'),r.returncode
res={}
for libs in (False,True):
  for name,proj in P:
    d=f'{T}/{proj}'; cfg='tsconfig.trig.json' if os.path.exists(f'{d}/tsconfig.trig.json') else 'tsconfig.json'
    for c in (1,4,8):
      for v in 'abp': one(v,proj,cfg,c,libs)
      for r in range(R):
        arms=list('abp'); random.shuffle(arms)
        for v in arms:
          x=one(v,proj,cfg,c,libs); res.setdefault((libs,name,c,v),[]).append(x)
          print(libs,name,c,r,v,*x,file=out); out.flush()
med=lambda k,i: st.median(x[i] for x in res[k])
print(f"{'libs':5} {'project':15} c  {'base ms':>9} {'A/A':>7} {'pgo ms':>9} {'faster':>7} {'ins':>7} {'cyc':>7} {'mem MiB b/p':>12}")
for libs in (False,True):
  for name,_ in P:
    for c in (1,4,8):
      a,b,p=[(libs,name,c,v) for v in 'abp']
      print(f"{'on' if libs else 'off':5} {name:15} {c}  {med(a,0):9.1f} {(med(b,0)/med(a,0)-1)*100:+6.1f}% {med(p,0):9.1f} {(1-med(p,0)/med(a,0))*100:6.1f}% {(1-med(p,1)/med(a,1))*100:6.1f}% {(1-med(p,2)/med(a,2))*100:6.1f}% {med(a,3)/1048576:6.1f}/{med(p,3)/1048576:.1f}  rc={res[a][0][4]},{res[p][0][4]}")
