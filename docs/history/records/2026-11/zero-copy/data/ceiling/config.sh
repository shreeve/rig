# time-ab.sh config: the zero-copy ceiling, Trig libs-embed (le-pnew) by one
# PGO profile: a0 as built, a0b the same binary (A/A), a1 item 4 and bulk
# reads copied, a2 a1 with option C (pages mapped from /proc/self/exe).
V="a0 a1 a3 a0b"
W=/zfs/rig-work/zero-copy/time
cmd_of() { echo "taskset -c 3 /tmp/zc-$1 -p tsconfig.trig.json --noEmit --checkers 1"; }
