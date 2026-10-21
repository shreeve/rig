# Free tasks spread over the workers: eight tasks of CPU work, run with
# four workers, take at least 1.5 times as much CPU time as wall time
# (about 4 on a quiet machine, 2 on one every core of which is busy),
# where tasks pinned to one worker take about as much (a slip that
# pinned every task once passed every other test). A task given a `*T`
# is local and stays on its maker's worker, so it takes about 1x. The
# best of three runs counts.
# timeout: 300
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >spread.rig <<'EOF2'
fun spin(n: Int) -> Int
  total = 0
  for i in 0..n
    total = (total + i * 7) % 1000003
  total

sub main()
  ts = Tasks[Int]()
  for i in 0..8
    !ts.add(spin(15000000 + i)&)
  s = 0
  for x in >ts
    s += x
  print(s > 0)
EOF2

cat >pinned.rig <<'EOF2'
obj Cfg
  k: Int

fun spin(c: ?*Cfg, n: Int) -> Int
  total = 0
  for i in 0..n
    total = (total + i * c.k) % 1000003
  total

sub main()
  c = *Cfg(k: 7)
  ts = Tasks[Int]()
  for i in 0..8
    !ts.add(spin(?c, 15000000 + i)&)
  s = 0
  for x in >ts
    s += x
  print(s > 0)
EOF2

rig build --release=fast -o spread spread.rig || fail "build spread"
rig build --release=fast -o pinned pinned.rig || fail "build pinned"

# CPU time over wall time, times ten, of running `$1` with four workers:
# the best of three runs.
ratio() {
    local TIMEFORMAT='%R %U' t best=0 r
    for _ in 1 2 3; do
        t=$( { time RIG_WORKERS=4 "./$1" >/dev/null; } 2>&1 ) || fail "$1 failed"
        r=$(awk '{ printf "%d", ($1 > 0 ? $2 / $1 : 0) * 10 }' <<<"$t")
        (( r > best )) && best=$r
    done
    echo "$best"
}

free=$(ratio spread)
pinned=$(ratio pinned)
(( free >= 15 )) || fail "free tasks did not spread: CPU time over wall time was $free/10 (local tasks: $pinned/10), expected at least 1.5"
(( pinned <= 13 )) || fail "local tasks spread: CPU time over wall time was $pinned/10, expected about 1"
exit 0
