import os, subprocess, random, sys, glob, re
S=sys.argv[1]; R=S+'/rv/bin/rig'; B=S+'/base/bin/rig'
root='/Users/shreeve/Data/Code/rig'
files=[f for f in glob.glob(root+'/test/behavior/*/*.rig')+glob.glob(root+'/examples/*.rig')]
random.seed(int(sys.argv[2])); N=int(sys.argv[3])
tmp=S+'/mut/a_%s'%sys.argv[2]; os.makedirs(tmp,exist_ok=True)
env=dict(os.environ); env['RIG_OUT_DIR']=tmp+'/out'
reps=[(r'\?\?',' catch '),(r'\bInt\b','I32'),(r'\bInt\b','U8'),(r'\bInt\b','I128'),(r'\bInt\b','F64'),(r'<(\w)',r'+\1'),(r'\?(\w)',r'!\1'),(r'!(\w)',r'?\1'),(r'\+(\w)',r'\1'),(r'<(\w)',r'\1'),
 (r'(\w) = ',r'\1 =! '),(r'\bdefer\b','errdefer'),(r'\bbreak\b','continue'),(r'(\d+)',r'-\1'),(r'(\d+)',r'(\1 +% 1)'),(r'(\d+)',r'U8(\1)'),(r'\bfor (\w+) in (\w+)',r'for \1 in ?\2'),(r'\bfor (\w+) in (\w+)',r'for \1 in !\2'),(r'\bfor (\w+) in (\w+)',r'for \1 in <\2'),
 (r'(\w+)\.len',r'\1.len * 2'),(r' if ',' if not '),(r'\bnone\b','0'),(r'\?$','!'),(r'(\w+)\[(\w+)\]',r'\1[\2 % 1]'),(r'print\((\w+)\)',r'print(+\1)'),(r'print\((\w+)\)',r'print(?\1)'),(r'= (\w+)$',r'= <\1'),(r'= (\w+)$',r'= +\1'),(r'= (\w+)$',r'= ?\1')]
n=0;c=0;acc=0
while n<N:
    f=random.choice(files); src=open(f).read()
    lines=src.split('\n')
    pat,rep=random.choice(reps)
    cand=[i for i,l in enumerate(lines) if re.search(pat,l) and not l.lstrip().startswith('#')]
    if not cand: continue
    i=random.choice(cand)
    new=re.sub(pat,rep,lines[i],count=1)
    if new==lines[i]: continue
    lines[i]=new; m='\n'.join(lines)
    p=tmp+'/m.rig'; open(p,'w').write(m); n+=1
    r=subprocess.run([R,'check',p],capture_output=True,text=True,timeout=60)
    if r.returncode!=0: continue
    acc+=1
    try:
        r=subprocess.run([R,'run',p],capture_output=True,text=True,timeout=120,env=env)
        out=r.stdout+r.stderr
    except subprocess.TimeoutExpired:
        out='TIMEOUT'
    if re.search(r'\.zig:\d+:\d+: error|internal error|TIMEOUT|memory leak|Segmentation|General protection|unsupported',out):
        c+=1; q=tmp+'/bad%d.rig'%c; open(q,'w').write(m)
        print(q, f.replace(root+'/',''), 'L%d'%(i+1), repr(new.strip()), '::', re.findall(r'(?:error|leak|TIMEOUT|Segmentation|unsupported)[^\n]*',out)[:1])
        sys.stdout.flush()
print('done',n,acc,c)
