#!/bin/sh
# rec.sh ARM PROJ KIND TAG: one perf record (c1, caller's taskset). KIND: lat (load latency >16, data address),
# head (ld_head.any_at_ret, precise), loads (all loads, data address), headm (ld_head.l1_miss_at_ret, precise).
D=/zfs/trig-pup/trial/dload; O=$D/rec; mkdir -p $O
ARM=$1; P=$2; K=$3; TAG=$4
case $P in
  webpack) d=/zfs/trig-pup/corpus/webpack/.; c=tsconfig.json;;
  typeorm) d=/zfs/trig-pup/corpus/typeorm/packages/typeorm; c=tsconfig.json;;
  Compiler) d=/zfs/trig-pup/corpus/typescript-benchmarking/cases/solutions/Compiler/.; c=tsconfig.json;;
  Compiler-Unions) d=/zfs/trig-pup/corpus/typescript-benchmarking/cases/solutions/Compiler-Unions; c=tsconfig.json;;
  supabase-studio) d=/zfs/trig-pup/corpus/supabase-studio/apps/studio; c=tsconfig.trig.json;;
  *) echo "no project $P"; exit 2;;
esac
case $ARM in
  T) cmd="env -u TRIG_PREBUILT_LIBS $D/T --singleThreaded";;
  D) cmd="env -u TRIG_PREBUILT_LIBS $D/PD --singleThreaded";;
  Y) cmd="env RAYON_NUM_THREADS=1 /zfs/trig-pup/tsrs-src-0.23.0/bin/tsrs --singleThreaded --checkerAssignment go --noLazyMembers";;
  *) echo "no arm $ARM"; exit 2;;
esac
case $K in
  lat) EV="cpu_atom/mem_uops_retired.load_latency_gt_16/upp"; X="-c 101 -d -W";;
  head) EV="cpu_atom/ld_head.any_at_ret/upp"; X="-c 20011";;
  headm) EV="cpu_atom/ld_head.l1_miss_at_ret/upp"; X="-c 10007";;
  loads) EV="cpu_atom/mem_uops_retired.all_loads/upp"; X="-c 20011 -d";;
  *) echo "no kind $K"; exit 2;;
esac
cd -P $d || exit 3
perf record -q -m 64 -e "$EV" $X -o $O/$TAG.data -- $cmd -p $c --noEmit > $O/$TAG.out 2> $O/$TAG.err
echo "$TAG rc=$? $(md5sum < $O/$TAG.out | cut -c1-8) $(ls -la $O/$TAG.data | awk '{print $5}')" | tee -a $O/log
