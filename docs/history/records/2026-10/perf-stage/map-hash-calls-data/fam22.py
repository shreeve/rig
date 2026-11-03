import sys,re,collections,os
sys.path.insert(0,os.path.dirname(__file__))
import importlib.util
spec=importlib.util.spec_from_file_location('fam',os.path.join(os.path.dirname(__file__),'fam.py'))
src=open(spec.origin).read().split('tr,tc=load')[0]
exec(src)
d=sys.argv[1]
def rows(v):
    c=collections.Counter(); t=0
    for l in open(os.path.join(d,'self.%s.txt'%v)):
        if '[.]' not in l: continue
        f=l.split('|'); n=int(f[1]); sym=l.split('[.]',1)[1].strip()
        t+=n
        if family(sym,v=='trig')=='runtime/std (maps, hash, interner)': c[sym]+=n
    cyc=int(re.search(r'cycles=(\d+)',open(os.path.join(d,'stat.%s'%v)).read()).group(1))
    return {k:x/t*cyc/1e6 for k,x in c.items()}
for v in ('trig','tsrs'):
    r=rows(v); print(v, 'total %.1f'%sum(r.values()))
    def g(s):
        s2=re.sub(r'\(.*','',s); s2=re.sub(r'__func_\d+','',s2)
        if v=='tsrs': s2=s[:110]
        return s2
    gc=collections.Counter()
    for k,x in r.items(): gc[g(k)]+=x
    for k,x in gc.most_common(30): print('  %7.1f %s'%(x,k))
if len(sys.argv)>2:
    r=rows('trig'); gc=collections.Counter(); gk=collections.Counter()
    for k,x in r.items():
        if k.startswith('rig.ordered'):
            m=re.match(r'rig\.ordered\.Ordered\((.*)\)\.(\w+)',k)
            gc[m.group(2)]+=x; gk[m.group(1)]+=x
    print('Ordered by method'); [print('  %7.1f %s'%(x,k)) for k,x in gc.most_common()]
    print('Ordered by key,value'); [print('  %7.1f %s'%(x,k)) for k,x in gk.most_common(15)]
