import random, subprocess, os, re, sys
random.seed(int(sys.argv[1])); N=int(sys.argv[2])
env=dict(os.environ, RIG_OUT_DIR=os.getcwd()+'/out')
toks=['*','~','?','!','(',')','[',']','[]','[2]','N','Int','fun(','sub(',') -> ','Cell[','Vec[',',','geo.','of',' ','<']
bad=0
for i in range(N):
    T=''.join(random.choice(toks) for _ in range(random.randint(1,10)))
    where=random.choice(['type','expr'])
    body = f"  x: {T} = 1\n" if where=='type' else f"  x = Cell[{T}](value: none)\n"
    f=f'tf/r{sys.argv[1]}.rig'
    open(f,'w').write("use geo\nstruct N\n  a: Int\nsub main\n"+body+"  print 1\n")
    try:
        r=subprocess.run(['gtimeout','10','/Users/shreeve/Data/Code/rig/bin/rig','check',f],capture_output=True,text=True,env=env,timeout=20)
    except Exception: print('HANG',repr(T)); continue
    out=r.stdout+r.stderr
    if r.returncode not in (0,1) or (r.returncode==1 and not re.search(r'\.rig:\d+:\d+: error',out)) or 'panic' in out:
        print('BAD',where,repr(T),r.returncode,out[:300]); bad+=1
    elif r.returncode==0: print('ACC',where,repr(T))
print('bad',bad)
