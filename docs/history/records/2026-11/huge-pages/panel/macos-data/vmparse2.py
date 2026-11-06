import sys, collections
sys.path.insert(0,'.')
exec(open(sys.argv[0].replace('vmparse2','vmparse')).read().split("kind=sys.argv[2]")[0])
R=collections.defaultdict(lambda:[0,0,0,0,set()])  # dur, cpu, wait, n, threads
T=collections.defaultdict(lambda:[0,0,0])
tot=[0,0,0,0]
for r in rows(sys.argv[1]):
    op=txt(r.get('vm-op'))
    if op!='Zero Fill': continue
    d=int(txt(r.get('duration')) or 0); c=int(txt(r.get('duration-on-core')) or 0); w=int(txt(r.get('duration-waiting')) or 0)
    th=r.get('thread'); tid=txt(th.find('tid')) if th is not None and th.find('tid') is not None else '?'
    a=int(txt(r.get('address')) or 0); k=hex(a>>30)  # 1 GiB granules
    e=R[k]; e[0]+=d; e[1]+=c; e[2]+=w; e[3]+=1; e[4].add(tid)
    t=T[tid]; t[0]+=d; t[1]+=1
    tot[0]+=d; tot[1]+=c; tot[2]+=w; tot[3]+=1
print('zero fill: %d faults, duration %.2f ms, on-core %.2f ms, waiting %.2f ms'%(tot[3],tot[0]/1e6,tot[1]/1e6,tot[2]/1e6))
print('by 1 GiB granule (addr>>30): faults, threads, us each, wait ms')
for k,e in sorted(R.items(), key=lambda kv:-kv[1][0])[:14]:
    print('  %-8s %6d faults %2d thr %6.2f us  dur %6.2f ms  wait %6.2f ms'%(k,e[3],len(e[4]),e[0]/e[3]/1e3,e[0]/1e6,e[2]/1e6))
print('threads:')
for t,v in sorted(T.items(), key=lambda kv:-kv[1][0]): print('  %s %6d faults %6.2f ms'%(t,v[1],v[0]/1e6))
