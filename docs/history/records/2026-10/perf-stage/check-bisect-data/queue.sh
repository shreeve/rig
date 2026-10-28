#!/bin/sh
# queue.sh SPEC...: make and compile each variant in turn. SPEC is
# NAME:OFF[:GROUP:MODE], OFF a comma list of kinds (or -), GROUP a
# g-GROUP.json, MODE rig, zig or rigzig.
W=/zfs/worktrees/rig/check-bisect
cd $W
for spec in "$@"; do
  name=$(echo $spec | cut -d: -f1); off=$(echo $spec | cut -d: -f2); grp=$(echo $spec | cut -d: -f3); mode=$(echo $spec | cut -d: -f4)
  [ "$off" = - ] && off=
  pad=; case $off in PAD*) pad="--pad ${off#PAD}"; off= ;; esac
  args="--off=$off $pad"
  [ -n "$grp" ] && args="$args --groups g-$grp.json"
  case $mode in *rig*) args="$args --rig" ;; esac
  case $mode in *zig*) args="$args --zig" ;; esac
  mkdir -p v/$name
  if [ "$off" = PRISTINE ]; then sh mk.sh $name; continue; fi
  taskset -c 0,5 python3 ceil.py emit/pkg v/$name/pkg $args > v/$name/ceil.out 2>&1 || { echo "$(date +%T) $name ceil FAILED"; continue; }
  sh mk.sh $name
done >> builds.out 2>&1
