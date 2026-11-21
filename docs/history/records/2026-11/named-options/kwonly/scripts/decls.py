# Count declarations (fun/sub) with a defaulted parameter other than the first (self not counted).
import re, sys, os
pat = re.compile(r'\b(fun|sub)\s+([A-Za-z_][\w]*)\s*(\[[^\]]*\])?\s*\(')
def params(s, i):
    depth=0; cur=''; out=[]
    while i < len(s):
        c=s[i]
        if c in '([{': depth+=1
        elif c in ')]}':
            if depth==0: out.append(cur); return out
            depth-=1
        elif c==',' and depth==0: out.append(cur); cur=''; i+=1; continue
        elif c=='"':
            j=i+1
            while j<len(s) and s[j]!='"': j+= 2 if s[j]=='\\' else 1
            cur+=s[i:j+1]; i=j+1; continue
        cur+=c; i+=1
    return out
tot=0; files={}
for root in sys.argv[1:]:
  for dp,_,fs in os.walk(root):
    for f in fs:
      if not f.endswith('.rig'): continue
      p=os.path.join(dp,f); s=open(p).read()
      for m in pat.finditer(s):
        ps=[x.strip() for x in params(s, m.end())]
        ps=[x for x in ps if x]
        if ps and re.match(r'^[?!<+]?@', ps[0]): ps=ps[1:]
        hits=[x for x in ps[1:] if re.search(r'(?<![=!<>])=(?!=)', x.split(':',1)[-1] if ':' in x else x)]
        if hits:
          tot+=1
          line=s.count('\n',0,m.start())+1
          print(f"{p}:{line}: {m.group(2)}: {', '.join(h.split(':')[0] for h in hits)}")
print("TOTAL", tot)
