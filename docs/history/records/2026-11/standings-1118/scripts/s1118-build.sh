#!/bin/bash
# s1118-build.sh: the builds for the 2026-11-18 standings boards on pup, Rig a303f69fd:
# bench/fork (fork.rig and its Rayon twin) and std.json's competitors (bench/json: rig-safe,
# cbench's yyjson and simdjson DOM, rust-bench native, gobench). Everything runs on E-cores
# 12-19, each step only once no slot is open. Output: /zfs/trig-pup/standings-1118.
set -eu
S=/zfs/trig-pup/rig-a303f69fd; RIG=$S/bin/rig; O=/zfs/trig-pup/standings-1118
F=docs/history/records/2026-11/concurrency-bench-remeasure/fork
P=/zfs/trig-pup/bin/pup-slot
E="taskset -c 12-19"
free_slot() { for i in $(seq 360); do $P state | grep -q "slot=none" && return 0; sleep 10; done; echo "no free slot in an hour"; exit 1; }
mkdir -p $O/fork $O/src/bench $O/json-build
echo "# build start $(date +%T); rig $($RIG --version 2>&1 | head -n 1)"

free_slot
cd $S
RIG_OUT_DIR=$O/fork/pkg $E $RIG build --release -o $O/fork/rig $S/$F/fork.rig
cp $O/fork/rig $O/fork/rig-aa; cmp $O/fork/rig $O/fork/rig-aa
# The Rayon twin is unchanged since the 2026-11-15 remeasure: reuse its build.
cp /zfs/trig-pup/bench-remeasure-3f4564a4b/build/fork/rayon $O/fork/rayon
echo "# fork built $(date +%T)"

# A private copy of bench/json (its competitors build in place), std and tools; the six data
# files are copied in from the Mac before this runs, sha256-checked against tools/fetch-json-data.sh.
[ -d $O/src/bench/json/timers ] || cp -a $S/bench/json $O/src/bench/
[ -d $O/src/std ] || cp -a $S/std $S/tools $O/src/
cd $O/src
free_slot
RIG=$RIG $E python3 bench/json/bench-json --out $O/json-build --build-only --variants rig-safe
for f in twitter twitterescaped canada citm_catalog gsoc-2018 github_events; do
  rm -rf $O/json-build/$f-rig-aa; cp -a $O/json-build/$f-rig-safe $O/json-build/$f-rig-aa
  cmp $O/json-build/$f-rig-safe/prog $O/json-build/$f-rig-aa/prog
done
echo "# rig-safe built $(date +%T)"
free_slot
(cd bench/json/cbench && $E sh build.sh)
echo "# cbench built $(date +%T); cc $(cc --version | head -n 1)"
free_slot
CPUQ_CORES=8 $E sh bench/json/rust-bench/build.sh native
echo "# rust-bench built $(date +%T); $(rustc --version)"
free_slot
(export PATH=$HOME/.local/share/mise/installs/go/1.27.2/bin:$PATH; cd bench/json/gobench && $E sh build.sh && go version)
echo "# gobench built $(date +%T)"
ls -la $O/fork $O/src/bench/json/cbench/prog-* $O/src/bench/json/gobench/prog-go $O/src/bench/json/rust-bench/target-native/release/{serde_json_value,simdjson_tape,sonic_value}
echo "# build done $(date +%T)"
