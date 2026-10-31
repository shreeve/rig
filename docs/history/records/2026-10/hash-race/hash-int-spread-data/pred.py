# Walk mispredicts: a predictor of each group's occupancy from the K groups
# before it, a table of C contexts (LRU), last value seen; R rounds of the walk.
import sys, subprocess
from collections import OrderedDict
def occ(m,s,W=16):
    return [ord(c)-97 for c in subprocess.run(["./simo",m],env={"OCCDUMP":str(s),"W":str(W)},capture_output=True,text=True).stdout.strip()]
def mp(seq,K,C,R=6):
    t=OrderedDict(); miss=0; n=len(seq); cnt=0
    hist=tuple(seq[-K:])
    for r in range(R):
        for g in range(n):
            ctx=hist; p=t.get(ctx)
            if r>=R-2:
                cnt+=1; miss+= (p!=seq[g])
            t[ctx]=seq[g]; t.move_to_end(ctx)
            if len(t)>C: t.popitem(last=False)
            hist=hist[1:]+(seq[g],)
    return miss/cnt
if __name__=="__main__":
  data={"4b33a62ed433d4a3":1.0,"eda75bda7f7727df":0.931,"e659ecc12e9bb7e9":1.051,"2f864fe527393797":1.062,"d26f35ca33b1ef03":1.03,"aba113f5c3135eb1":1.08,"f05c997b58257839":1.047,"bea701f7b47aa3f5":1.006,"3f515f7748c26c71":1.152,"257d3b7413cc915b":1.098,"6f95cb49323931f1":1.143,"3eb8fcdb368cf311":1.069,"69a71f9e674b8921":1.072,"c28b7b8dda08ae51":1.026,"f560eaeda7870df1":1.181,"0dbc375180285729":1.137,"dfa7b5c5d2779e9d":1.146}
  seqs={m:occ("0x"+m,100000) for m in data}
  def corr(a,b):
      n=len(a); ma=sum(a)/n; mb=sum(b)/n
      c=sum((x-ma)*(y-mb) for x,y in zip(a,b)); va=sum((x-ma)**2 for x in a); vb=sum((y-mb)**2 for y in b)
      return c/(va*vb)**.5
  ys=[data[m] for m in data]
  for K in (1,2,3,4,6,8):
      for C in (512,2048,8192):
          xs=[mp(seqs[m],K,C) for m in data]
          print(K,C,"corr %.2f"%corr(xs,ys)," ".join("%.2f"%x for x in xs),flush=True)
