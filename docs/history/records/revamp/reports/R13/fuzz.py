import random, subprocess, os, sys
random.seed(int(sys.argv[1]) if len(sys.argv)>1 else 1)
N=int(sys.argv[2]) if len(sys.argv)>2 else 300
toks=['[',']','[',']','of','of','of',',','2','x','N','(',')','\n  ','\n','*','~','?','!','Int','none','.some','|a|','"s"','xs','.','<','+','-',' ',';','of:','f','1']
env=dict(os.environ, RIG_OUT_DIR=os.getcwd()+'/out')
bad=0
for i in range(N):
    body=''.join(random.choice(toks)+random.choice(['',' ',' ']) for _ in range(random.randint(1,14)))
    src=f"N =! 2\nfun f(of: Int) -> Int\n  of\n\nsub main\n  x = 1\n  xs = [1, 2]\n  y = {body}\n  print y\n"
    p=f'fz/s{sys.argv[1]}_c{i}.rig'
    open(p,'w').write(src)
    try:
        r=subprocess.run(['gtimeout','10','/Users/shreeve/Data/Code/rig/bin/rig','check',p],capture_output=True,text=True,env=env,timeout=20)
    except Exception as e:
        print('TIMEOUT',p); bad+=1; continue
    out=r.stdout+r.stderr
    import re
    ok = (r.returncode==0) or (r.returncode==1 and re.search(r'\.rig:\d+:\d+: error', out))
    if not ok or 'panic' in out or 'thread' in out:
        print('BAD',p,r.returncode,repr(body)); print(out[:500]); bad+=1
    elif r.returncode==0:
        r2=subprocess.run(['gtimeout','60','/Users/shreeve/Data/Code/rig/bin/rig','run',p],capture_output=True,text=True,env=env)
        if r2.returncode!=0:
            print('ACCEPT-FAIL',p,repr(body)); print((r2.stdout+r2.stderr)[:800]); bad+=1
        else: print('ACC',repr(body), r2.stdout.strip()[:60])
    else:
        os.remove(p)
print('bad',bad)
