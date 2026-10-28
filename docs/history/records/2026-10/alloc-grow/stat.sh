# stat.sh BIN ROWS...: perf stat of BIN's ROWS after map.zig's earlier rows.
D=/zfs/worktrees/rig/alloc-grow
cd $D
B=$1; shift
rm -f perf.ctl; mkfifo perf.ctl
P=$(sh prefix.sh)
perf stat -D -1 --control=fifo:perf.ctl -e cpu_core/cycles/u,cpu_core/cycles/k,cpu_core/instructions/u,page-faults,cpu_core/dTLB-load-misses/,cpu_core/dTLB-store-misses/,cpu_core/cache-misses/ -x, taskset -c 6 ./$B $P on "$@" 2>&1 >/dev/null | grep -v "^[a-z]*[0-9]* [a-z]* [0-9]" | grep cpu_core\\\|page | awk -F, '{printf "%s=%s ", $3, $1} END {print ""}' | sed 's/cpu_core\///g'
