#!/bin/bash
# tp.sh N TAG: every binary b-V-A-L.bin, N interleaved rounds (the arm order
# alternating each round), fastest of N a binary; per variant and row, the
# median of P's layouts' bests over M's, SLOWER when P's fastest layout is
# more than 2% over M's slowest, faster the reverse.
N=$1; TAG=$2
cd "$(dirname "$0")"
L="0 5 13 29"; mkdir -p out-$TAG; rm -f out-$TAG/*
for r in $(seq 1 $N); do
  arms="M P"; [ $((r % 2)) -eq 0 ] && arms="P M"
  for v in ${VARS:-map hash}; do for a in $arms; do for l in $L; do taskset -c 6 ./b-$v-$a-$l.bin > out-$TAG/$v-$a-$l.$r.txt 2>&1; done; done; done
done
python3 - $TAG "$L" "${VARS:-map hash}" <<'PY'
import sys, glob, statistics as st
tag=sys.argv[1]; L=sys.argv[2].split()
for v in sys.argv[3].split():
  best={}; order=[]
  for a in "MP":
    for l in L:
      for f in glob.glob(f"out-{tag}/{v}-{a}-{l}.*.txt"):
        for line in open(f):
          p=line.split()
          if len(p)!=4 or not p[2].isdigit(): continue
          k=p[0]+" "+p[1]
          if k not in best: best[k]={}; order.append(k)
          best[k][(a,l)]=min(int(p[2]),best[k].get((a,l),10**18))
  print(f"## {v}: row, main's median ms, rt-by-value / main, verdict")
  ns=nf=0
  for k in order:
    d=best[k]; xs=[d[("M",l)]/1e6 for l in L]; ys=[d[("P",l)]/1e6 for l in L]
    mx, my = st.median(xs), st.median(ys); vd=""
    if min(ys)>max(xs)*1.02: vd="SLOWER"; ns+=1
    elif max(ys)*1.02<min(xs): vd="faster"; nf+=1
    print("%-26s %9.3f %7.3f %s"%(k,mx,my/mx,vd))
  print(f"# {v}: {len(order)} rows, {ns} slower, {nf} faster")
PY
