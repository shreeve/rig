#!/bin/sh
# usage: ab.sh ROUNDS ARGS -- BIN...   fewest instructions and cycles of each, interleaved; plus best steady time
R=$1; shift; A=$1; shift
for b in "$@"; do echo "$b" ; done > /dev/null
for r in $(seq 1 $R); do
  for b in "$@"; do
    /usr/bin/time -l $b $A 2>/tmp/ab.$$ >/tmp/ab.out.$$
    i=$(awk '/instructions retired/{print $1}' /tmp/ab.$$); c=$(awk '/cycles elapsed/{print $1}' /tmp/ab.$$); m=$(awk '/peak memory/{print $1}' /tmp/ab.$$); t=$(awk '{print $1}' /tmp/ab.out.$$)
    echo "$b $i $c $m $t"
  done
done | awk '{n=$1; if(!(n in I)||$2<I[n])I[n]=$2; if(!(n in C)||$3<C[n])C[n]=$3; if(!(n in M)||$4<M[n])M[n]=$4; if(!(n in T)||$5<T[n])T[n]=$5} END{for(n in I) printf "%-12s instr %11d cycles %10d peak %9d best_ns %s\n", n, I[n], C[n], M[n], T[n]}' | sort
rm -f /tmp/ab.$$ /tmp/ab.out.$$
