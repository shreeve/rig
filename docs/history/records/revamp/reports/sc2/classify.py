import re, subprocess, sys, os
S=os.path.dirname(os.path.abspath(__file__))
RIG=sys.argv[1]
pats=['(shared (optional','(weak (optional','(shared (error_union','(weak (error_union','(optional (shared','(optional (weak','(error_union (shared','(error_union (weak','(share (propagate_none','(weak (propagate_none']
files=subprocess.run(['git','ls-files'],capture_output=True,text=True).stdout.split()
units=[]
for f in files:
    if f.endswith('.rig'): units.append((f,open(f).read()))
    elif f.endswith('.md'):
        t=open(f).read()
        for m in re.finditer(r'^```rig[^\n]*\n(.*?)^```',t,re.M|re.S):
            line=t[:m.start()].count('\n')+1
            units.append((f'{f}:L{line}',m.group(1)))
for name,src in units:
    p=os.path.join(S,'u.rig'); open(p,'w').write(src)
    out=subprocess.run([RIG,'parse',p],capture_output=True,text=True)
    o=out.stdout
    hits={k:o.count(k) for k in pats if k in o}
    if hits: print(name,hits)
