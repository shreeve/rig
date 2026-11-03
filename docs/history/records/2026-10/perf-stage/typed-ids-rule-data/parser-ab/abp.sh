#!/bin/sh
# usage: abp.sh ROUNDS PROJDIR BIN...  : interleaved, fewest instructions/cycles, lowest peak, per binary
R=$1; D=$2; shift 2
cd "$D"
for r in $(seq 1 $R); do
  for b in "$@"; do
    /usr/bin/time -l $b -p tsconfig.trig.json --noEmit --singleThreaded >/dev/null 2>/tmp/abp.$$
    i=$(awk '/instructions retired/{print $1}' /tmp/abp.$$); c=$(awk '/cycles elapsed/{print $1}' /tmp/abp.$$); m=$(awk '/peak memory/{print $1}' /tmp/abp.$$); rs=$(awk '/maximum resident/{print $1}' /tmp/abp.$$)
    echo "$(basename $b) $i $c $m $rs"
  done
done | awk '{n=$1; if(!(n in I)||$2<I[n])I[n]=$2; if(!(n in C)||$3<C[n])C[n]=$3; if(!(n in M)||$4<M[n])M[n]=$4; if(!(n in X)||$5<X[n])X[n]=$5} END{for(n in I) printf "%-10s instr %12d cycles %11d footprint %10d maxrss %10d\n", n, I[n], C[n], M[n], X[n]}' | sort
rm -f /tmp/abp.$$
