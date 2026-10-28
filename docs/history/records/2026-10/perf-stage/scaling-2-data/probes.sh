#!/bin/sh
# probes.sh BIN NAME: uprobes on a copy of a Trig binary (a copy, so the
# timed binary is never probed), at file offsets computed from the
# executable segment (perf probe takes a raw address as a file offset):
#   NAME:NAME_task      checker k's task starts (check_group's spawn entry; k
#                  is the argument the loop compares associations[f] to;
#                  sp maps it to the self of its check_source_file calls)
#   NAME:NAME_csf      Checker.check_source_file entry (self, file)
#   NAME:NAME_csfdone  in the task, the instruction after check_source_file
#                  returns (no uretprobe: a fiber switched inside a probed
#                  function returns through another thread's trampoline)
#   NAME:NAME_taskend  in the task, the call of rig.tasks.Control.finish
#   NAME:NAME_load      FileLoader.load entry (parse and bind start)
#   NAME:NAME_newck     checker.new_checker entry
#   NAME:NAME_sw        rig.sched.switchNaked entry: the stack a fiber leaves
#                  (sp) and the one it resumes (to), so a checker's CPU
#                  time is known when fibers share a thread
set -eu
B=$1 N=$2
set -- $(readelf -lW $B | awk '$1 == "LOAD" && / R E / { print $2, $3 }')
delta=$(( $2 - $1 ))
set -- $B $N
off() { a=$(nm $B | awk -v s="$1" '$3 == s { print $1 }'); printf '0x%x' $(( 0x$a - delta )); }
task=$(objdump -d --no-show-raw-insn $B | awk '/^[0-9a-f]+ <rig.sched.spawn__func_[0-9]+.Full.start>:$/ { fn = $2 } /call.*<checker.Checker.check_source_file>/ { print fn }' | tr -d '<>:' | sort -u)
sudo perf probe -q -d "$N:*" 2>/dev/null || true
for t in $task; do
  # The static assignment's task loads k from 0x84b0(%rdi); the queue's does not.
  if objdump -d --no-show-raw-insn $B --start-address=0x$(nm $B | awk -v s="$t" '$3 == s { print $1 }') 2>/dev/null | head -30 | grep -q '0x84b0(%rdi),%rbp'; then
    sudo perf probe -q -x $B -a "$N:${N}_task=$(off $t) k=+0x84b0(%di):s64 sp=%sp:u64"
    a=$(nm $B | awk -v s="$t" '$3 == s { print $1 }')
    body=$(objdump -d --no-show-raw-insn $B --start-address=0x$a --stop-address=$(printf '0x%x' $(( 0x$a + 0x800 ))))
    done=$(echo "$body" | awk '/call.*<checker.Checker.check_source_file>/ { getline; sub(":", "", $1); print $1; exit }')
    fin=$(echo "$body" | awk '/call.*<rig.tasks.Control.finish>/ { sub(":", "", $1); print $1; exit }')
    sudo perf probe -q -x $B -a "$N:${N}_csfdone=$(printf '0x%x' $(( 0x$done - delta )))"
    sudo perf probe -q -x $B -a "$N:${N}_taskend=$(printf '0x%x' $(( 0x$fin - delta )))"
  fi
done
sudo perf probe -q -x $B -a "$N:${N}_csf=$(off checker.Checker.check_source_file) self=%di:u64 file=%si:s64"
sudo perf probe -q -x $B -a "$N:${N}_load=$(off compiler.FileLoader.load)"
sudo perf probe -q -x $B -a "$N:${N}_newck=$(off checker.new_checker)"
sudo perf probe -q -x $B -a "$N:${N}_sw=$(off rig.sched.switchNaked) to=%si:u64 sp=%sp:u64"
sudo perf probe -l "$N:*" || true
