#!/bin/bash
# ident.sh A B: run binaries A and B on Trig's six race projects at 1, 4 and 8 checkers
# (--noEmit), with --extendedDiagnostics (times dropped), with TRIG_LAZY_STATS=1, and on a
# small project with --noEmit --declaration and no other diagnostic; print every case
# whose output or status differs. Only while no timing slot is open; cores 16-19.
set -u
A=$1; B=$2; P=/zfs/trig-pup/full/trig/misc/projects; T=/zfs/rig-work/scaling/vmas/decl
n=0; bad=0
run() { # BIN ARGS... -> stdout, stderr, status, one blob
  out=$("$@" 2>/tmp/ident.err.$$); s=$?; printf '%s\n--stderr--\n%s\n--status %d\n' "$out" "$(cat /tmp/ident.err.$$)" $s
}
cmp1() { # NAME DIR FILTER ARGS...
  name=$1; dir=$2; filt=$3; shift 3
  [ -e /tmp/slot-active ] && { echo "slot open: stopping"; exit 3; }
  a=$(cd $dir && run taskset -c 16-19 $A "$@" | $filt); b=$(cd $dir && run taskset -c 16-19 $B "$@" | $filt)
  n=$((n+1)); if [ "$a" != "$b" ]; then bad=$((bad+1)); echo "DIFFERS: $name"; diff <(echo "$a") <(echo "$b") | head -5; fi
}
notime() { grep -v -E -i 'time:|memory used|^ *[A-Za-z ]+ time'; }
for proj in mitt neverthrow zod3 ts-pattern superstruct tiny-invariant; do
  for c in 1 4 8; do
    cmp1 "$proj c$c" $P/$proj cat -p tsconfig.trig.json --noEmit --checkers $c
    cmp1 "$proj c$c extended" $P/$proj notime -p tsconfig.trig.json --noEmit --checkers $c --extendedDiagnostics
  done
  TRIG_LAZY_STATS=1 cmp1 "$proj c4 lazy stats" $P/$proj cat -p tsconfig.trig.json --noEmit --checkers 4
done
for c in 1 4; do
  cmp1 "decl ok c$c" $T/ok cat -p tsconfig.json --noEmit --declaration --checkers $c
  cmp1 "decl err c$c" $T/err cat -p tsconfig.json --noEmit --declaration --checkers $c
done
rm -f /tmp/ident.err.$$
echo "$n cases, $bad differ"
