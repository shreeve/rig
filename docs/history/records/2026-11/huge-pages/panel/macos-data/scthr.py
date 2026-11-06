import sys, collections
exec(open('vmparse.py').read().split("kind=sys.argv[2]")[0])
b=collections.defaultdict(lambda:[0,0]); t0=None; allc=collections.defaultdict(lambda:[0,0])
evs=[]
for r in rows(sys.argv[1]):
    name=txt(r.get('syscall')); t=int(txt(r.get('start-time'))); c=int(txt(r.get('duration-on-core')) or 0)
    th=r.get('thread'); tid=txt(th.find('tid')) if th is not None and th.find('tid') is not None else '?'
    evs.append((t,name,c,tid))
t0=min(e[0] for e in evs)
for t,name,c,tid in evs:
    ph='start' if t-t0<25e6 else ('mid' if t-t0<190e6 else 'end')
    if name in ('BSC_munmap','BSC_mmap','BSC_mprotect','MSC_mach_vm_protect_trap'):
        b[(ph,tid,name)][0]+=1; b[(ph,tid,name)][1]+=c
for k in sorted(b, key=lambda k:(k[0],-b[k][1])): print('%-6s %-10s %-26s n %4d  %.2f ms'%(k[0],k[1],k[2],b[k][0],b[k][1]/1e6))
