# Store-forward model: each insert loads the groups it probes and stores
# a tag into the group it fills (and an overflow bit into each full group
# it passes). A load of a group stored to by one of the K inserts before
# it is counted, per insert, for K = 1..8. Inserts only, growth included
# (rehash placements not counted).
import sys
M=(1<<64)-1; GOLD=0x9e3779b97f4a7c15
def rotl(x,r): return ((x<<r)|(x>>(64-r)))&M
def run(mul,W,s,maps,stride=GOLD,Ks=(1,2,3,4,6,8)):
    NL=W-1; ln,ld=(4,5) if W==8 else (7,8); ming=4 if W==8 else 2
    hits={K:0 for K in Ks}; tot=0
    for j in range(maps):
        size=0; g=0; ml=0; cnt=None; keys=[]
        recent=[]   # per insert: set of stored groups (with table generation)
        gen=0
        for i in range(s):
            h=rotl(((j*s+i)*stride*mul)&M,8)
            if size>=ml:
                n=-(-((size+size//61+1)*ld)//ln)
                x=max(n//NL+1,ming); g=1
                while g<x: g*=2
                sh=64-(g.bit_length()-1); cnt=[0]*g; gen+=1; recent=[]
                c=g*NL-1; ml=c if c<=2*NL-1 else c*ln//ld
                for k in keys:
                    p=k>>sh; st=0
                    while cnt[p]>=NL: st+=1; p=(p+st)&(g-1)
                    cnt[p]+=1
            p=h>>sh; st=0; loads=[p]; stores=[]
            while cnt[p]>=NL:
                stores.append(p); st+=1; p=(p+st)&(g-1); loads.append(p)
            cnt[p]+=1; stores.append(p); keys.append(h); size+=1
            for K in Ks:
                prev=recent[-K:]
                if any(q in ps for q in loads for ps in prev): hits[K]+=1
            recent.append(set(stores)); recent=recent[-8:]
            tot+=1
    return {K:hits[K]/tot for K in Ks}
if __name__=="__main__":
    W=int(sys.argv[1]); s=int(sys.argv[2]); maps=int(sys.argv[3])
    for m in sys.argv[4:]:
        mul=int(m,16); d=((GOLD*mul)<<8 & M)/2**64
        r=run(mul,W,s,maps)
        print(m,"dG=%.4f"%d," ".join("K%d:%.3f"%(K,v) for K,v in r.items()),flush=True)
