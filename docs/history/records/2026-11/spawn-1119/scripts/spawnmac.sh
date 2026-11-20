#!/bin/bash
# spawnmac.sh M: spawn-only program (bench/tasks' spawn x5, 500k tasks) per arm; /usr/bin/time -l instructions and
# wall at RIG_WORKERS=1 and 10, 5 runs each, rotated; medians per spawn.
M=$1; A="base:fae440c77 s1180:17282fb1c s1173:63fc4bb68 s1181:beaef4053 main:636fd02a5"
cd $M
for r in 1 2 3 4 5; do for w in 1 10; do for a in $A; do n=${a%%:*}
  /usr/bin/time -l env RIG_WORKERS=$w $M/spawn-$n > $M/so-$n-w$w-r$r.txt 2> $M/se-$n-w$w-r$r.txt; done; done; done
python3 - $M <<'PY'
import sys,glob,re,statistics as st
m=sys.argv[1]
for w in (1,10):
  print("== RIG_WORKERS=%d, per spawn (500k)"%w)
  for n in ("base","s1180","s1173","s1181","main"):
    ins=[];ns=[]
    for f in glob.glob(m+"/se-%s-w%d-r*.txt"%(n,w)):
      x=re.search(r"(\d+)\s+instructions retired",open(f).read())
      if x: ins.append(int(x.group(1))/500000)
    for f in glob.glob(m+"/so-%s-w%d-r*.txt"%(n,w)):
      for l in open(f):
        x=re.match(r"spawn\s+(\d+)",l)
        if x: ns.append(int(x.group(1))/100000)
    print("  %-6s %7.1f ns (min %.1f)  %7.1f instructions"%(n,st.median(ns),min(ns),st.median(ins)))
PY
