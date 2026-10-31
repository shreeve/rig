# Rehash store-forward model: rehash walks the old table group by group,
# lane by lane, and places each entry (load its home group, and each group
# it probes; store a tag into the one it fills). Counted: placements whose
# loads meet a group stored to by one of the K placements before, per
# insert of the row (s keys a map, growth from empty).
import sys
M=(1<<64)-1; GOLD=0x9e3779b97f4a7c15
def rotl(x,r): return ((x<<r)|(x>>(64-r)))&M
Ks=(1,2,3,4,6,8)
def run(mul,W,s,maps,stride=GOLD,base0=0):
    NL=W-1; ln,ld=(4,5) if W==8 else (7,8); ming=4 if W==8 else 2
    hits={K:0 for K in Ks}; tot=0; moves=0
    for j in range(maps):
        size=0; ml=0; lanes=None; g=0
        for i in range(s):
            h=rotl(((base0+j*s+i)*stride*mul)&M,8)
            if size>=ml:
                n=-(-((size+size//61+1)*ld)//ln)
                x=max(n//NL+1,ming); ng=1
                while ng<x: ng*=2
                sh=64-(ng.bit_length()-1); nl=[[] for _ in range(ng)]
                recent=[]
                if lanes:
                    for grp in lanes:
                        for k in grp:
                            p=k>>sh; st=0; loads=[p]; stores=[]
                            while len(nl[p])>=NL: stores.append(p); st+=1; p=(p+st)&(ng-1); loads.append(p)
                            nl[p].append(k); stores.append(p); moves+=1
                            for K in Ks:
                                if any(q in ps for q in loads for ps in recent[-K:]): hits[K]+=1
                            recent.append(set(stores));
                            if len(recent)>16: recent=recent[-8:]
                lanes=nl; g=ng
                c=g*NL-1; ml=c if c<=2*NL-1 else c*ln//ld
            p=h>>sh; st=0
            while len(lanes[p])>=NL: st+=1; p=(p+st)&(g-1)
            lanes[p].append(h); size+=1; tot+=1
    return {K:hits[K]/tot for K in Ks}, moves/tot
if __name__=="__main__":
    W=int(sys.argv[1]); s=int(sys.argv[2]); maps=int(sys.argv[3])
    for m in sys.argv[4:]:
        mul=int(m,16); d=((GOLD*mul)<<8 & M)/2**64
        r,mv=run(mul,W,s,maps)
        print(m,"dG=%.4f moves %.2f"%(d,mv)," ".join("K%d:%.3f"%(K,v) for K,v in r.items()),flush=True)
