#!/bin/bash
# tp.sh N "A0 A8 A24" "H0 H8 H24" [PIN]: main's and the branch's binaries, each in several layouts,
# interleaved, fastest of N each; per row, each arm's median of its layouts' bests and its spread.
N=$1; X=$2; Y=$3; PIN=${4:-}
cd "$(dirname "$0")"
rm -f out.*.txt
for r in $(seq 1 $N); do for b in $X $Y; do $PIN ./$b.bin > out.$b.$r.txt 2>&1; done; done
python3 - "$X" "$Y" <<'PY'
import sys, glob, statistics as st
X=sys.argv[1].split(); Y=sys.argv[2].split()
best={}
for b in X+Y:
    for f in glob.glob(f"out.{b}.*.txt"):
        for l in open(f):
            p=l.split()
            if len(p)!=4 or not p[2].isdigit(): continue
            k=p[0]+" "+p[1]; best.setdefault(k,{}); best[k][b]=min(int(p[2]),best[k].get(b,10**18))
print("%-24s %8s %8s %7s %15s %15s %s"%("row","main","branch","b/m","main spread","branch spread","verdict"))
for k,d in best.items():
    xs=[d[b]/1e6 for b in X]; ys=[d[b]/1e6 for b in Y]
    mx, my = st.median(xs), st.median(ys)
    v=""
    if min(ys) > max(xs)*1.02: v="SLOWER"
    elif max(ys)*1.02 < min(xs): v="faster"
    print("%-24s %8.2f %8.2f %7.3f %7.2f-%-7.2f %7.2f-%-7.2f %s"%(k,mx,my,my/mx,min(xs),max(xs),min(ys),max(ys),v))
PY
