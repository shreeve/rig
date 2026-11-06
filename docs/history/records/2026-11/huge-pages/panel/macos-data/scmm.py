import sys, collections
exec(open('vmparse.py').read().split("kind=sys.argv[2]")[0])
ev=[]
for r in rows(sys.argv[1]):
    name=txt(r.get('syscall'))
    if name not in ('BSC_munmap','BSC_mmap','BSC_mprotect','BSC_madvise'): continue
    # args: find syscall-arg children in order: need raw element list; approximate
    ev.append((int(txt(r.get('start-time'))),name,int(txt(r.get('duration-on-core')) or 0),r))
t0=min(e[0] for e in ev)
b=collections.defaultdict(lambda:[0,0])
for t,nm,c,_ in ev:
    k=(nm,int((t-t0)/25e6)); b[k][0]+=1; b[k][1]+=c
for k in sorted(b): print('%-12s t=%3d-%3d ms  n %4d  on-core %.2f ms'%(k[0],k[1]*25,k[1]*25+25,b[k][0],b[k][1]/1e6))
