# Fraction of a doubling rehash's entries that take the general path:
# not at home in the old table, or their new group already full.
import random
M=(1<<64)-1
def rotl(x): return ((x<<8)|(x>>56))&M
def sim(W,n,keyf):
    NL=W-1; ln,ld=(4,5) if W==8 else (7,8); ming=4 if W==8 else 2
    size=0; ml=0; lanes=None; g=0; slow=0; moves=0
    for i in range(n):
        h=rotl(keyf(i))
        if size>=ml:
            m=-(-((size+size//61+1)*ld)//ln); x=max(m//NL+1,ming); ng=1
            while ng<x: ng*=2
            sh=64-(ng.bit_length()-1); nl=[[] for _ in range(ng)]
            if lanes:
                assert ng==2*g
                for og,grp in enumerate(lanes):
                    for k in grp:
                        p=k>>sh; cap=NL-(p==ng-1)
                        if (p>>1)!=og or len(nl[p])>=cap: slow+=1
                        st=0
                        while len(nl[p])>=NL-(p==ng-1): st+=1; p=(p+st)&(ng-1)
                        nl[p].append(k); moves+=1
            lanes=nl; g=ng; c=g*NL-1; ml=c if c<=2*NL-1 else c*ln//ld
        p=h>>sh
        st=0
        while len(lanes[p])>=NL-(p==g-1): st+=1; p=(p+st)&(g-1)
        lanes[p].append(h); size+=1
    return slow/moves
rnd=random.Random(5)
R=[rnd.getrandbits(64) for _ in range(200000)]
for W in (16,8):
    print("W%d random %.3f golden %.3f"%(W, sim(W,100000,lambda i:R[i]*0x4b33a62ed433d4a3&M), sim(W,100000,lambda i:(i*0x9e3779b97f4a7c15*0x4b33a62ed433d4a3)&M)))
