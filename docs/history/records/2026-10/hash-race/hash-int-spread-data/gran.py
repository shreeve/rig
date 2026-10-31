# Rehash collisions at a granule: a placement whose home group shares a
# 2^b-group granule with the group one of the last K placements filled.
import sys
M=(1<<64)-1; GOLD=0x9e3779b97f4a7c15
def rotl(x): return ((x<<8)|(x>>56))&M
def run(mul,W,s,maps,bs=(0,1,2,3,4),Ks=(1,2,4)):
    NL=W-1; ln,ld=(4,5) if W==8 else (7,8); ming=4 if W==8 else 2
    hits={(b,K):0 for b in bs for K in Ks}; tot=0
    for j in range(maps):
        size=0; ml=0; lanes=None; g=0
        for i in range(s):
            h=rotl(((j*s+i)*GOLD*mul)&M)
            if size>=ml:
                n=-(-((size+size//61+1)*ld)//ln); x=max(n//NL+1,ming); ng=1
                while ng<x: ng*=2
                sh=64-(ng.bit_length()-1); nl=[[] for _ in range(ng)]; recent=[]
                if lanes:
                    for grp in lanes:
                        for k in grp:
                            p=k>>sh; st=0
                            while len(nl[p])>=NL-(p==ng-1): st+=1; p=(p+st)&(ng-1)
                            home=k>>sh
                            for b in bs:
                                for K in Ks:
                                    if any((home>>b)==(q>>b) for q in recent[-K:]): hits[(b,K)]+=1
                            nl[p].append(k); recent.append(p); recent=recent[-8:]
                lanes=nl; g=ng; c=g*NL-1; ml=c if c<=2*NL-1 else c*ln//ld
            p=h>>sh; st=0
            while len(lanes[p])>=NL-(p==g-1): st+=1; p=(p+st)&(g-1)
            lanes[p].append(h); size+=1; tot+=1
    return hits,tot
W=8
for s,maps in ((1000,30),(100000,1),(1000000,1)):
    print("s=%d"%s)
    for m in ("4b33a62ed433d4a3","fb59148934afb5bd","a1b9b543bccba13c","bc61e80a2a0d4f95","b54f96b65bd18951"):
        h,t=run(int(m,16),W,s,maps)
        print(" ",m[:4]," ".join("b%dK%d:%.3f"%(b,K,h[(b,K)]/t) for b in (0,1,2,3,4) for K in (1,2,4)),flush=True)
