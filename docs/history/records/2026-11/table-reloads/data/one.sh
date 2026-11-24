#!/bin/sh
# one.sh ARM PROJ SET RUN: one perf stat run of ARM on PROJ with event set SET (c1). Runs on the caller's taskset.
D=/zfs/trig-pup/trial/dload; O=$D/out; mkdir -p $O
ARM=$1; P=$2; SET=$3; RUN=$4
case $P in
  webpack) d=/zfs/trig-pup/corpus/webpack/.; c=tsconfig.json;;
  typeorm) d=/zfs/trig-pup/corpus/typeorm/packages/typeorm; c=tsconfig.json;;
  Compiler) d=/zfs/trig-pup/corpus/typescript-benchmarking/cases/solutions/Compiler/.; c=tsconfig.json;;
  Compiler-Unions) d=/zfs/trig-pup/corpus/typescript-benchmarking/cases/solutions/Compiler-Unions; c=tsconfig.json;;
  supabase-studio) d=/zfs/trig-pup/corpus/supabase-studio/apps/studio; c=tsconfig.trig.json;;
  playwright) d=/zfs/trig-pup/corpus/playwright/.; c=tsconfig.json;;
  *) echo "no project $P"; exit 2;;
esac
case $ARM in
  T) cmd="env -u TRIG_PREBUILT_LIBS /zfs/trig-pup/trial/dload/T --singleThreaded";;
  D) cmd="env -u TRIG_PREBUILT_LIBS /zfs/trig-pup/trial/cs5/trig-PD --singleThreaded";;
  G) cmd="env RAYON_NUM_THREADS=1 /zfs/trig-pup/tsrs-0.23.0/package/tsrs --singleThreaded --checkerAssignment go --noLazyMembers";;
  Y) cmd="env RAYON_NUM_THREADS=1 /zfs/trig-pup/tsrs-src-0.23.0/bin/tsrs --singleThreaded --checkerAssignment go --noLazyMembers";;
  *) echo "no arm $ARM"; exit 2;;
esac
A=cpu_atom
case $SET in
  td) EV="$A/cycles/u,$A/instructions/u,$A/topdown_retiring.all/u,$A/topdown_bad_speculation.all/u,$A/topdown_fe_bound.all/u,$A/topdown_be_bound.all/u,$A/topdown_be_bound.mem_scheduler/u,$A/topdown_be_bound.reorder_buffer/u";;
  be) EV="$A/cycles/u,$A/instructions/u,$A/topdown_be_bound.register/u,$A/topdown_be_bound.non_mem_scheduler/u,$A/topdown_be_bound.alloc_restrictions/u,$A/topdown_be_bound.serialization/u,$A/topdown_bad_speculation.mispredict/u,$A/topdown_bad_speculation.machine_clears/u";;
  ld) EV="$A/cycles/u,$A/instructions/u,$A/ld_head.any_at_ret/u,$A/ld_head.l1_miss_at_ret/u,$A/ld_head.l1_bound_at_ret/u,$A/ld_head.st_addr_at_ret/u,$A/ld_head.other_at_ret/u,$A/ld_head.dtlb_miss_at_ret/u";;
  ms) EV="$A/cycles/u,$A/instructions/u,$A/mem_bound_stalls_load.all/u,$A/mem_bound_stalls_load.l2_hit/u,$A/mem_bound_stalls_load.llc_hit/u,$A/mem_bound_stalls_load.llc_miss/u,$A/mem_uops_retired.all_loads/u,$A/mem_load_uops_retired.l1_miss/u";;
  sb) EV="$A/cycles/u,$A/instructions/u,$A/mem_scheduler_block.all/u,$A/mem_scheduler_block.ld_buf/u,$A/mem_scheduler_block.rsv/u,$A/mem_scheduler_block.st_buf/u,$A/mem_load_uops_retired.l2_hit/u,$A/mem_bound_stalls_load.sbfull/u";;
  *) echo "no set $SET"; exit 2;;
esac
cd -P $d || exit 3
perf stat -x, -e "$EV" -o $O/st.$ARM.$P.$SET.$RUN -- $cmd -p $c --noEmit > $O/out.$ARM.$P 2>&1
echo "$ARM $P $SET $RUN $(md5sum < $O/out.$ARM.$P | cut -c1-8) $(awk -F, '!/^#/ && NF>3 {n=$3; sub("cpu_atom/","",n); sub("/u$","",n); printf "%s=%s ", n, $1}' $O/st.$ARM.$P.$SET.$RUN)" >> $O/rows
