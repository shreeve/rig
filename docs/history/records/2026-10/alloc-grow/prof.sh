# prof.sh NAME BIN ROWS...: perf record of BIN's ROWS after map.zig's earlier rows.
D=/zfs/worktrees/rig/alloc-grow
cd $D
N=$1; B=$2; shift 2
rm -f perf.ctl; mkfifo perf.ctl
P=$(sh prefix.sh)
perf record -q -D -1 --control=fifo:perf.ctl -g -o $D/perf-$N.data taskset -c 6 ./$B $P on "$@" > $D/out-$N.txt 2>&1
perf report -i $D/perf-$N.data --no-children --percent-limit 1.5 --stdio -g none 2>/dev/null | grep -v "^#" | grep -v "^$" | head -40
