import sys,subprocess
# usage: hunks.py FILE idx,idx,...  -> stages those hunks (1-based) of FILE's diff
f=sys.argv[1]; want=set(int(x) for x in sys.argv[2].split(','))
d=subprocess.run(['git','diff','-U3',f],capture_output=True,text=True).stdout
lines=d.splitlines(keepends=True)
head=[];hunks=[];cur=None
for l in lines:
    if l.startswith('@@'):
        cur=[l];hunks.append(cur)
    elif cur is None: head.append(l)
    else: cur.append(l)
out=''.join(head)+''.join(''.join(h) for i,h in enumerate(hunks,1) if i in want)
subprocess.run(['git','apply','--cached','--recount','-'],input=out,text=True,check=True)
