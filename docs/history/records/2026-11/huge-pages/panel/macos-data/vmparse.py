import sys, xml.etree.ElementTree as ET, collections
def rows(path):
    ids={}
    for ev,el in ET.iterparse(path, events=('end',)):
        if el.tag=='row':
            out={}
            for c in el:
                if c.tag=='sentinel': continue
                v = ids[c.get('ref')] if c.get('ref') else c
                if c.get('id'): ids[c.get('id')]=c
                out[c.tag]=v
                # nested ids
                for d in c.iter():
                    if d.get('id'): ids[d.get('id')]=d
            yield out
            # keep el (ids reference it)
def txt(e): return (e.text or '').strip() if e is not None else ''
kind=sys.argv[2]
if kind=='vm':
    by_op=collections.Counter(); n_op=collections.Counter(); by_thr=collections.Counter(); by_rng=collections.Counter(); n_rng=collections.Counter(); wait=collections.Counter()
    starts=[]
    for r in rows(sys.argv[1]):
        op=txt(r.get('vm-op')); d=int(txt(r.get('duration')) or 0)
        th=r.get('thread'); thn=th.get('fmt') if th is not None else '?'
        a=int(txt(r.get('address')) or 0)
        by_op[op]+=d; n_op[op]+=1; by_thr[thn.split(' (')[0]]+=d
        rng=hex(a>>32)
        by_rng[(op,rng)]+=d; n_rng[(op,rng)]+=1
        starts.append(int(txt(r.get('start-time'))))
    tot=sum(by_op.values())
    print('total fault time %.2f ms over %d faults'%(tot/1e6,sum(n_op.values())))
    for op,d in by_op.most_common(): print('  %-22s %8.2f ms  %6d  %.2f us each'%(op,d/1e6,n_op[op],d/n_op[op]/1e3))
    print('by 4GiB range (op, addr>>32):')
    for k,d in by_rng.most_common(15): print('  %-40s %8.2f ms %6d  %.2f us'%(k,d/1e6,n_rng[k],d/n_rng[k]/1e3))
    print('threads:', len(by_thr)); 
    for t,d in by_thr.most_common(12): print('  %-30s %.2f ms'%(t,d/1e6))
    print('span %.1f ms'%((max(starts)-min(starts))/1e6))
else:
    by=collections.Counter(); n=collections.Counter()
    for r in rows(sys.argv[1]):
        nm=r.get('syscall'); name=nm.get('fmt') if nm is not None else '?'
        d=int(txt(r.get('duration')) or 0)
        by[name]+=d; n[name]+=1
    print('total syscall time %.2f ms, %d calls'%(sum(by.values())/1e6,sum(n.values())))
    for k,d in by.most_common(20): print('  %-28s %8.2f ms %6d'%(k,d/1e6,n[k]))
