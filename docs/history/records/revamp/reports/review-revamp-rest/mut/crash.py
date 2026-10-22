import os, subprocess, random, sys, glob
S=sys.argv[1]; R=S+'/rv/bin/rig'
root='/Users/shreeve/Data/Code/rig'
files=glob.glob(root+'/test/**/*.rig',recursive=True)+glob.glob(root+'/examples/*.rig')
files=[f for f in files if '/torture/' not in f]
random.seed(int(sys.argv[2])); N=int(sys.argv[3])
tmp=S+'/mut/c_%s'%sys.argv[2]; os.makedirs(tmp,exist_ok=True)
toks=['?','!','*','<','-','+','~','.','(',')','[',']','|','||',':','??',' ','\n','\n  ','=','=!','->','=>','..','of','if','else','while','for','in','match','return','break','continue','new','defer','pub','struct','enum','type','fun','sub','use','raw','none','true','0','-1','x','Int','U8','"s"','#','\\','@','as','catch','and','or','not']
n=0;c=0
while n<N:
    f=random.choice(files)
    try: src=open(f).read()
    except: continue
    if not src: continue
    m=src
    for _ in range(random.randint(1,4)):
        i=random.randrange(len(m)+1)
        op=random.randrange(3)
        if op==0: m=m[:i]+random.choice(toks)+m[i:]
        elif op==1: m=m[:i]+m[i+random.randint(1,5):]
        else:
            j=random.randrange(len(m)+1); k=min(len(m),j+random.randint(1,40)); m=m[:i]+m[j:k]+m[i:]
    d=os.path.dirname(f)
    p=tmp+'/m.rig'; open(p,'w').write(m)
    # multi-file tests: copy siblings not needed; single
    n+=1
    try:
        r=subprocess.run([R,'check',p],capture_output=True,text=True,timeout=20)
        out=r.stdout+r.stderr
        bad = r.returncode>1 or 'panic' in out or 'thread ' in out or 'internal' in out.lower() or 'unreachable' in out
    except subprocess.TimeoutExpired:
        bad=True; out='TIMEOUT'
    if bad:
        c+=1; q=tmp+'/crash%d.rig'%c; open(q,'w').write(m)
        print(q, r.returncode if out!='TIMEOUT' else 'T', out[:300].replace('\n',' | '))
        sys.stdout.flush()
print('done',n,c)
