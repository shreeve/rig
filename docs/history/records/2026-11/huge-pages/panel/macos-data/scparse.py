import sys, collections
exec(open('vmparse.py').read().split("kind=sys.argv[2]")[0])
by=collections.Counter(); oc=collections.Counter(); n=collections.Counter()
for r in rows(sys.argv[1]):
    name=txt(r.get('syscall')); d=int(txt(r.get('duration')) or 0); c=int(txt(r.get('duration-on-core')) or 0)
    by[name]+=d; oc[name]+=c; n[name]+=1
print('syscalls: %d, duration %.2f ms, on-core %.2f ms'%(sum(n.values()),sum(by.values())/1e6,sum(oc.values())/1e6))
for k,_ in oc.most_common(18): print('  %-34s n %6d  on-core %7.2f ms  duration %8.2f ms'%(k,n[k],oc[k]/1e6,by[k]/1e6))
