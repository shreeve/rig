# Locality model of bench/hash's golden-stride int rows: the table of
# unordered.zig (groups, quadratic probe, overflow bits, growth) with an
# LRU cache of two levels over the lines each op touches.
import sys
from collections import OrderedDict
M=(1<<64)-1; GOLD=0x9e3779b97f4a7c15
def rotl(x,r): return ((x<<r)|(x>>(64-r)))&M
class LRU:
    def __init__(s,cap): s.cap=cap; s.d=OrderedDict(); s.miss=0
    def touch(s,a):
        d=s.d
        if a in d: d.move_to_end(a); return True
        s.miss+=1; d[a]=1
        if len(d)>s.cap: d.popitem(last=False)
        return False
class Cache:
    def __init__(s,l1,l2,line): s.l1=LRU(l1); s.l2=LRU(l2); s.line=line
    def touch(s,addr):
        a=addr//s.line
        if not s.l1.touch(a): s.l2.touch(a)
class T:
    def __init__(s,W):
        s.W=W; s.NL=W-1; s.g8=(W==8); s.ln,s.ld=(4,5) if s.g8 else (7,8); s.ming=4 if s.g8 else 2
        s.size=0; s.g=0; s.ml=0; s.base=0
    def groupsFor(s,n):
        x=max(n//s.NL+1,s.ming); p=1
        while p<x: p*=2
        return p
    def build(s,n):
        s.g=s.groupsFor(n); s.sh=64-(s.g.bit_length()-1); s.cnt=[0]*s.g; s.ovf=[0]*s.g; s.tags=[[] for _ in range(s.g)]
        c=s.g*s.NL-1; s.ml= c if c<=2*s.NL-1 else c*s.ln//s.ld
        s.base+= 1<<40   # a fresh block
        s.ctrl=s.base + s.g*s.NL*16
    def place(s,t,cache=None):
        p=t>>s.sh; st=0; cls=1<<(t&7)
        if cache: cache.touch(s.ctrl+p*s.W)
        while s.cnt[p]>=s.NL:
            s.ovf[p]|=cls; st+=1; p=(p+st)&(s.g-1)
            if cache: cache.touch(s.ctrl+p*s.W)
        lane=s.cnt[p]; s.cnt[p]+=1; s.tags[p].append(t&0xff)
        if cache: cache.touch(s.base+(p*s.NL+lane)*16)
        return st
    def insert(s,t,keys,cache):
        if s.size>=s.ml:
            n=-(-((s.size+s.size//61+1)*s.ld)//s.ln); s.build(n)
            for k in keys: s.place(k)
        s.place(t,cache); s.size+=1
    def miss(s,t,cache):
        p=t>>s.sh; tg=t&0xff; cls=1<<(t&7); fm=0; st=0
        while True:
            cache.touch(s.ctrl+p*s.W)
            f=s.tags[p].count(tg); fm+=f
            if f: cache.touch(s.base+p*s.NL*16)
            if not (s.ovf[p]&cls): break
            st+=1; p=(p+st)&(s.g-1)
        return fm
MACH={'pup':(16,768,32768,64),'mac':(8,1024,131072,128)}
def rows(mul,mach,n,which=('ins','miss')):
    W,l1,l2,line=MACH[mach]
    c=Cache(l1,l2,line); t=T(W); keys=[]
    hs=[rotl((i*GOLD*mul)&M,8) for i in range(2*n)]
    for i in range(n): t.insert(hs[i],keys,c); keys.append(hs[i])
    out={'ins1':c.l1.miss/n,'ins2':c.l2.miss/n}
    c2=Cache(l1,l2,line)
    for i in range(n,2*n): t.miss(hs[i],c2)   # warm: a previous round
    c2.l1.miss=c2.l2.miss=0
    for i in range(n,2*n): t.miss(hs[i],c2)
    out['miss1']=c2.l1.miss/n; out['miss2']=c2.l2.miss/n
    return out
if __name__=="__main__":
    n=int(sys.argv[1]); mach=sys.argv[2]
    for m in sys.argv[3:]:
        mul=int(m,16); d=((GOLD*mul)<<8 & M)/2**64
        r=rows(mul,mach,n)
        print("%s dG=%.4f d2G=%.4f  ins L1 %.3f L2 %.3f  miss L1 %.3f L2 %.3f"%(m,d,(2*d)%1,r['ins1'],r['ins2'],r['miss1'],r['miss2']),flush=True)
