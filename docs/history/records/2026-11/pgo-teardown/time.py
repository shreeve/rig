#!/usr/bin/env python3
# Mac, interleaved and shuffled: PGO Trig built by main (a), its copy (b, A/A), and with the teardown fix (f).
import os,random,re,statistics as st,subprocess,sys,time,shutil
W=os.path.expanduser('~/Data/Code/Claude/rig/rig/pgo-teardown-ab'); T=os.path.expanduser('~/Data/Code/trig/misc/projects')
D='/tmp/pgo-teardown-arms'; shutil.rmtree(D,ignore_errors=True); os.makedirs(D)
for n,s in (('a','trig-base'),('b','trig-base'),('f','trig-fix')): shutil.copy2(f'{W}/{s}',f'{D}/{n}')
R=int(sys.argv[1]) if len(sys.argv)>1 else 20
P=['tiny-invariant','mitt','neverthrow','superstruct','zod3','ts-pattern']
env0=dict(os.environ); out=open(f'{W}/runs.txt','a'); res={}
def one(v,proj,cfg,c,libs):
    e=dict(env0)
    if not libs: e['TRIG_PREBUILT_LIBS']='0'
    a=['-p',cfg,'--noEmit']+(['--singleThreaded'] if c==1 else ['--checkers',str(c)])
    t0=time.perf_counter_ns(); r=subprocess.run([f'{D}/{v}']+a,cwd=f'{T}/{proj}',env=e,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return (time.perf_counter_ns()-t0)/1e6, r.returncode
for libs in (False,True):
  for proj in P:
    cfg='tsconfig.trig.json' if os.path.exists(f'{T}/{proj}/tsconfig.trig.json') else 'tsconfig.json'
    for c in (1,4,8):
      for v in 'abf': one(v,proj,cfg,c,libs)
      for r in range(R):
        arms=list('abf'); random.shuffle(arms)
        for v in arms:
          x=one(v,proj,cfg,c,libs); res.setdefault((libs,proj,c,v),[]).append(x); print(libs,proj,c,r,v,*x,file=out); out.flush()
m=lambda k: st.median(x[0] for x in res[k])
print(f"{'libs':5} {'project':15} c  {'main ms':>8} {'A/A':>7} {'fix ms':>8} {'faster':>7}")
for libs in (False,True):
  for proj in P:
    for c in (1,4,8):
      a,b,f=[(libs,proj,c,v) for v in 'abf']
      print(f"{'on' if libs else 'off':5} {proj:15} {c}  {m(a):8.2f} {(m(b)/m(a)-1)*100:+6.1f}% {m(f):8.2f} {(1-m(f)/m(a))*100:6.1f}%  rc={res[a][0][1]},{res[f][0][1]}")
