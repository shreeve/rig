import random, subprocess, os, re, sys
random.seed(int(sys.argv[1]))
N=int(sys.argv[2])
env=dict(os.environ, RIG_OUT_DIR=os.getcwd()+'/out')
RIG='/Users/shreeve/Data/Code/rig/bin/rig'
def gen(d=0):
    r=random.random()
    if d>3 or r<0.25: return random.choice(['N','Int','geo.N','W[Int]','Vec[Int]'])
    k=random.choice(['sh','wk','opt','opt','fal','rb','wb','par','sl','arr','fun','sub','cell','w'])
    t=gen(d+1)
    return {'sh':'*'+t,'wk':'~'+t,'opt':t+'?','fal':t+'!','rb':'?'+t,'wb':'!'+t,'par':'('+t+')','sl':'[]'+t,'arr':'[2]'+t,
            'fun':'fun('+t+') -> Int','sub':'sub('+t+')','cell':'Cell['+t+']','w':'W['+t+']'}[k]
HDR="use geo\nstruct N\n  a: Int\nstruct W[T]\n  v: T\n\nsub main\n"
def run(body,f):
    open(f,'w').write(HDR+body)
    r=subprocess.run(['gtimeout','10',RIG,'check',f],capture_output=True,text=True,env=env)
    return r.returncode, r.stdout+r.stderr
seen=set()
for i in range(N):
    T=gen()
    if T in seen: continue
    seen.add(T)
    f=f'tf/s{sys.argv[1]}.rig'
    rc,out=run(f"  x: {T} = 1\n",f)
    if rc not in (0,1) or not re.search(r'\.rig:\d+:\d+: error',out):
        print('CRASH',T,rc,out[:300]); continue
    m=re.search(r'type mismatch: expected `(.*)`, got `Int`',out)
    if not m: continue
    P=m.group(1)
    rc2,out2=run(f"  x: {P} = 1\n",f)
    m2=re.search(r'type mismatch: expected `(.*)`, got `Int`',out2)
    if not m2 or m2.group(1)!=P:
        print('ROUNDTRIP',repr(T),'->',repr(P),'->',out2.splitlines()[0] if out2 else '')
    # expression position
    rc3,out3=run(f"  y: Cell[{T}] = Cell[{T}](value: 1)\n",f)
    m3=re.search(r'type mismatch: expected `Cell\[(.*)\]`, got `Cell\[(.*)\]`',out3)
    if m3 and m3.group(1)!=m3.group(2):
        print('EXPRDIFF',repr(T),m3.group(1),'vs',m3.group(2))
print('done')
