import os, subprocess, random, sys, glob, hashlib
S=sys.argv[1]
B=S+'/base/bin/rig'; R=S+'/rv/bin/rig'
root='/Users/shreeve/Data/Code/rig'
files=[f for f in glob.glob(root+'/test/behavior/**/*.rig',recursive=True)+glob.glob(root+'/examples/*.rig')]
random.seed(int(sys.argv[2]))
out=open(S+'/mut/diffs_%s.txt'%sys.argv[2],'w')
tmp=S+'/mut/t_%s'%sys.argv[2]; os.makedirs(tmp,exist_ok=True)
def parse(bin,path):
    p=subprocess.run([bin,'parse',path],capture_output=True,text=True,timeout=20)
    return p.returncode,(p.stdout+p.stderr).replace(path,'F')
n=0;d=0
N=int(sys.argv[3])
chars='?!*<-+.([~|:'
while n<N:
    f=random.choice(files)
    src=open(f).read()
    idx=[i for i,c in enumerate(src) if c in chars]
    if not idx: continue
    i=random.choice(idx)
    op=random.randrange(4)
    if op==0: m=src[:i]+' '+src[i:]
    elif op==1: m=src[:i+1]+' '+src[i+1:]
    elif op==2 and i>0 and src[i-1]==' ': m=src[:i-1]+src[i:]
    elif op==3 and i+1<len(src) and src[i+1]==' ': m=src[:i+1]+src[i+2:]
    else: continue
    p=tmp+'/m.rig'; open(p,'w').write(m)
    n+=1
    a=parse(B,p); b=parse(R,p)
    if a[0]==0 and a!=b or (a[0]!=0 and b[0]==0):
        d+=1
        name=tmp+'/d%d.rig'%d; open(name,'w').write(m)
        ln=m[:i].count('\n')+1
        out.write('%s op%d line%d %s\n  base:%s\n  rv:  %s\n'%(name,op,ln,f.replace(root+'/',''),a[1][:200].replace('\n',' | '),b[1][:200].replace('\n',' | ')))
        out.flush()
print(n,d)
