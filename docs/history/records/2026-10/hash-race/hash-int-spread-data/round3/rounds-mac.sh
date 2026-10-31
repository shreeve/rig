#!/bin/bash
# rounds.sh R "ARGS" MUL...: R interleaved rounds on P-core 6; best ns per row and multiplier
cd "$(dirname "$0")"
R=$1; a=$2; shift 2
for r in $(seq 1 $R); do for m in "$@"; do ./p-$m-0.bin $a | sed "s/^/$m /"; done; done | python3 -c '
import sys
best={}; order=[]; ms=[]
for l in sys.stdin:
    p=l.split()
    if len(p)<4: continue
    m=p[0]
    if p[1]=="insert-only": row="insert-only "+p[2]; ns=int(p[3])
    else: row=" ".join(p[1:-2]); ns=int(p[-2])
    if m not in ms: ms.append(m)
    if row not in best: best[row]={}; order.append(row)
    best[row][m]=min(ns,best[row].get(m,1e18))
print("%-26s"%"row"," ".join("%10s"%m[2:8] for m in ms))
for row in order: print("%-26s"%row," ".join("%10.3f"%(best[row][m]/best[row][ms[0]]) if i else "%10d"%best[row][m] for i,m in enumerate(ms)))
'
