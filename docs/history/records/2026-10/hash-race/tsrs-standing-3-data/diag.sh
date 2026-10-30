#!/bin/sh
# diag.sh BIN TAG [R]: where zod3's gap to tsrs comes from, on P-core 1 with
# its sibling 2 idle, Trig binary BIN against shipped tsrs, into $W/diag-TAG:
#   extdiag   --extendedDiagnostics, 5 runs each, zod3 and ts-pattern
#   fixed     20 interleaved runs of two tiny projects with zod3's options:
#             empty (one empty file, zod3's five libs) and nolib (noLib)
#   prof      R sampled profiles each of zod3 (a sample every 10M cycles, user
#             and kernel, frame-pointer stacks: whole in the kernel, the
#             leaf alone in Trig's user code, which keeps no frame pointer),
#             with exec, write, writev, exit_group and exit, and on Trig
#             uprobes at FileLoader.load and Checker.check_source_file (on a copy of BIN,
#             so the timed binary is never probed)
#   lbr       R profiles of Trig's user cycles on zod3 with LBR call stacks
#             (a sample every 10M cycles), for callers
#   faults    3 runs each recording every page fault, its address and the
#             function that touched it
#   strace    one run each counting syscalls, one listing the memory calls
#   Linux's free 2 MiB blocks (as Rig's huge-page gate counts them) are
#   logged before each profile and fault run, in huge2m.txt.
set -u
B=$1 TAG=$2 R=${3:-20}
W=/zfs/worktrees/rig/tsrs-standing-3
P=$W/trig/misc/projects
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
O=$W/diag-$TAG; mkdir -p $O
t="-p tsconfig.trig.json --noEmit --singleThreaded"
s="-p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers"
busy() {
  for _ in 1 2 3 4 5; do
    ps -eLo psr=,stat=,comm= | awk '($1 == 1 || $1 == 2) && $2 ~ /^R/ && $3 != "ps" && $3 != "awk" && $3 != "perf" { f=1 } END { exit !f }' && return 0
    sleep 0.2
  done
  return 1
}
quiet() { while busy; do echo "# $(date +%T) waiting: a process runs on core 1 or 2"; sleep 20; done; }
huge2m() { awk '$4 != "DMA" { n += $14 + 2 * $15 } END { print n }' /proc/buddyinfo; }
echo "# start $(date +%T) $B load $(cut -d' ' -f1-3 /proc/loadavg)"
# The tiny projects.
for k in empty nolib; do
  d=$W/tiny/$k; mkdir -p $d; : > $d/empty.ts
  if [ $k = empty ]; then
    python3 -c "import json,sys; c=json.load(open('$P/zod3/tsconfig.trig.json')); c['include']=['empty.ts']; json.dump(c, open('$d/tsconfig.trig.json','w'), indent=2)"
  else
    python3 -c "import json,sys; c=json.load(open('$P/zod3/tsconfig.trig.json')); c['include']=['empty.ts']; c['compilerOptions']['noLib']=True; c['compilerOptions'].pop('lib'); json.dump(c, open('$d/tsconfig.trig.json','w'), indent=2)"
  fi
done
# extdiag
for proj in zod3 ts-pattern; do
  cd $P/$proj
  for i in 1 2 3 4 5; do
    quiet
    taskset -c 1 $B $t --extendedDiagnostics 2>&1 | sed -n '/^Files:/,$p' > $O/extdiag.trig.$proj.$i
    taskset -c 1 env RAYON_NUM_THREADS=1 $TSRS $s --extendedDiagnostics 2>&1 | sed -n '/^Files:/,$p' > $O/extdiag.tsrs.$proj.$i
  done
done
# fixed
EV=duration_time,user_time,system_time,cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults
for k in empty nolib; do
  cd $W/tiny/$k
  i=1
  while [ $i -le 20 ]; do
    quiet
    for v in trig tsrs; do
      if [ $v = trig ]; then c="$B $t"; else c="env RAYON_NUM_THREADS=1 $TSRS $s"; fi
      /usr/bin/time -f "%M" -o $O/rss perf stat -x, -e $EV -o $O/perf taskset -c 1 $c > $O/fixed.out.$k.$v 2>&1
      f=$(awk -F, '/^[0-9]/ { k=$3; sub("cpu_core/", "", k); sub("/$", "", k); printf "%s=%s ", k, $1 }' $O/perf)
      echo "$k round=$i v=$v ${f}rss_kb=$(tail -n 1 $O/rss)"
    done
    i=$((i + 1))
  done
done > $O/fixed.txt
# Probes on a copy of BIN.
X=$O/trigprobe; cp $B $X
set -- $(readelf -lW $X | awk '$1 == "LOAD" && / R E / { print $2, $3 }')
delta=$(( $2 - $1 ))
off() { a=$(nm $X | awk -v s="$1" '$3 == s { print $1 }'); printf '0x%x' $(( 0x$a - delta )); }
sudo perf probe -q -d "s3:*" 2>/dev/null || true
sudo perf probe -q -x $X -a "s3:load=$(off compiler.FileLoader.load)"
sudo perf probe -q -x $X -a "s3:csf=$(off checker.Checker.check_source_file)"
TP="-e sched:sched_process_exec -e sched:sched_process_exit -e syscalls:sys_enter_write -e syscalls:sys_enter_writev -e syscalls:sys_enter_exit_group"
cd $P/zod3
i=1
while [ $i -le $R ]; do
  quiet
  echo "prof $i $(huge2m)" >> $O/huge2m.txt
  sudo perf record -q -c 10000000 --call-graph fp -e cpu_core/cycles/ $TP -e 's3:*' -o $O/p.data -- taskset -c 1 $X $t > /dev/null 2>&1
  sudo perf script --no-inline -i $O/p.data -F comm,pid,tid,time,event,trace,ip,sym,dso 2>/dev/null | gzip > $O/prof.trig.$i.txt.gz
  sudo perf record -q -c 10000000 --call-graph fp -e cpu_core/cycles/ $TP -o $O/p.data -- taskset -c 1 env RAYON_NUM_THREADS=1 $TSRS $s > /dev/null 2>&1
  sudo perf script --no-inline -i $O/p.data -F comm,pid,tid,time,event,trace,ip,sym,dso 2>/dev/null | gzip > $O/prof.tsrs.$i.txt.gz
  i=$((i + 1))
done
sudo perf probe -q -d "s3:*"
# lbr
i=1
while [ $i -le $R ]; do
  quiet
  sudo perf record -q -c 10000000 --call-graph lbr -e cpu_core/cycles/u -o $O/p.data -- taskset -c 1 $B $t > /dev/null 2>&1
  sudo perf script --no-inline -i $O/p.data -F comm,tid,time,event,ip,sym 2>/dev/null | gzip > $O/lbr.trig.$i.txt.gz
  i=$((i + 1))
done
# faults
for i in 1 2 3; do
  quiet
  echo "faults $i $(huge2m)" >> $O/huge2m.txt
  sudo perf record -q -c 1 -d --call-graph fp -e page-faults -o $O/p.data -- taskset -c 1 $B $t > /dev/null 2>&1
  sudo perf script --no-inline -i $O/p.data -F comm,tid,time,event,ip,sym,dso,addr 2>/dev/null | gzip > $O/faults.trig.$i.txt.gz
  sudo perf record -q -c 1 -d --call-graph fp -e page-faults -o $O/p.data -- taskset -c 1 env RAYON_NUM_THREADS=1 $TSRS $s > /dev/null 2>&1
  sudo perf script --no-inline -i $O/p.data -F comm,tid,time,event,ip,sym,dso,addr 2>/dev/null | gzip > $O/faults.tsrs.$i.txt.gz
done
sudo rm -f $O/p.data
# strace
quiet
strace -f -c -o $O/strace-c.trig taskset -c 1 $B $t > /dev/null 2>&1
strace -f -c -o $O/strace-c.tsrs taskset -c 1 env RAYON_NUM_THREADS=1 $TSRS $s > /dev/null 2>&1
strace -f -e trace=memory -o $O/strace-mem.trig taskset -c 1 $B $t > /dev/null 2>&1
strace -f -e trace=memory -o $O/strace-mem.tsrs taskset -c 1 env RAYON_NUM_THREADS=1 $TSRS $s > /dev/null 2>&1
echo "# done $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)"
