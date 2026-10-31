#!/bin/bash
# tpm-rot-mac.sh N TAG MAIN CAND... (arm order rotated each round): every arm in layouts 0 5 13 29 (p-MUL-NOPS.bin), N interleaved rounds
# unpinned (macOS), fastest of N per binary; per row and candidate, the median of its layouts' bests over
# main's, SLOWER when its fastest layout is more than 2% over main's slowest, faster the reverse.
N=$1; TAG=$2; shift 2
cd "$(dirname "$0")"
L="0 5 13 29"; mkdir -p out-$TAG; rm -f out-$TAG/*
ARMS="$*"
for r in $(seq 1 $N); do set -- $(echo $ARMS | awk -v r=$r '{n=NF; for(i=0;i<n;i++) printf "%s ", $(((i+r-1)%n)+1)}'); for m in "$@"; do for l in $L; do ./p-$m-$l.bin > out-$TAG/$m-$l.$r.txt 2>&1; done; done; done
python3 - $TAG "$L" $ARMS <<'PY'
import sys, glob, statistics as st
tag=sys.argv[1]; L=sys.argv[2].split(); arms=sys.argv[3:]
best={}; order=[]
for m in arms:
  for l in L:
    for f in glob.glob(f"out-{tag}/{m}-{l}.*.txt"):
      for line in open(f):
        p=line.split()
        if len(p)!=4 or not p[2].isdigit(): continue
        k=p[0]+" "+p[1]
        if k not in best: best[k]={}; order.append(k)
        best[k][(m,l)]=min(int(p[2]),best[k].get((m,l),10**18))
print("%-24s %8s"%("row","main")+"".join(" %16s"%a[2:8] for a in arms[1:]))
for k in order:
  d=best[k]; xs=[d[(arms[0],l)]/1e6 for l in L]; mx=st.median(xs); s="%-24s %8.2f"%(k,mx)
  for a in arms[1:]:
    ys=[d[(a,l)]/1e6 for l in L]; my=st.median(ys); v=""
    if min(ys)>max(xs)*1.02: v="SLOWER"
    elif max(ys)*1.02<min(xs): v="faster"
    s+=" %8.3f %-7s"%(my/mx,v)
  print(s)
PY
