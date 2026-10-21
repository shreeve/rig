# `rig build --release --bolt -- WORKLOAD` lays the executable out again
# with LLVM's BOLT, by a perf profile of the workload (src/bolt.zig). It
# needs Linux with perf, perf2bolt, and llvm-bolt: elsewhere, or without
# them, it fails at once and says what it needs; where they are there,
# the laid-out program prints what the plain one does, and a saved
# profile (`--bolt-profile`) lays a build out with no workload.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >p.rig <<'EOF2'
fun step(n: Int) -> Int
  if n % 3 == 0
    return n / 3
  n * 2 + 1

sub main()
  s = 0
  for i in 0..200000
    s += step(i) % 7
  print(s)
EOF2

out=$("$RIG" build --release --bolt -o prog p.rig 2>&1); expect_rc $? 2 "--bolt without a workload"
expect_has "$out" "needs a workload" "--bolt without a workload"
out=$("$RIG" build --bolt -o prog p.rig -- ./prog 2>&1); expect_rc $? 2 "--bolt on a debug build"
expect_has "$out" "add \`--release\`" "--bolt on a debug build"
out=$("$RIG" run --release --bolt p.rig 2>&1); expect_rc $? 2 "--bolt on run"
out=$("$RIG" build --release --bolt-profile=p.fdata -o prog p.rig 2>&1); expect_rc $? 2 "--bolt-profile alone"

if [[ $(uname -s) != Linux ]]; then
    out=$("$RIG" build --release --bolt -o prog p.rig -- ./prog 2>&1); expect_rc $? 1 "--bolt off Linux"
    expect_has "$out" "needs Linux" "--bolt off Linux"
    exit 0
fi

# No tools on PATH: perf, the first, is named.
mkdir empty
zig=$(command -v "${ZIG:-zig}")
out=$(PATH=$PWD/empty ZIG=$zig "$RIG" build --release --bolt -o prog p.rig -- ./prog 2>&1); expect_rc $? 1 "--bolt with no perf"
expect_has "$out" "needs perf" "--bolt with no perf"

have() {
    local n v
    for n in "$1" $(for v in $(seq 40 -1 14); do echo "$1-$v"; done); do command -v "$n" >/dev/null && return 0; done
    for v in $(seq 40 -1 14); do [[ -x /usr/lib/llvm-$v/bin/$1 ]] && return 0; done
    return 1
}
if ! command -v perf >/dev/null || ! have llvm-bolt || ! have perf2bolt; then
    echo "note: perf, llvm-bolt, or perf2bolt is missing: the laid-out build is not checked"
    exit 0
fi
want=$("$RIG" run --release p.rig 2>&1) || fail "rig run: $want"
out=$(rig build --release --bolt --bolt-profile=p.fdata -o prog p.rig -- ./prog 2>&1); expect_rc $? 0 "build --bolt: $out"
expect_eq "$(./prog)" "$want" "the laid-out program"
readelf -S prog | grep -q 'bolt' || fail "prog has no mark of BOLT: $(readelf -S prog | grep -c .)"
[[ -s p.fdata ]] || fail "--bolt-profile kept no profile"
[[ -e prog.perf.data || -e prog.bolt ]] && fail "--bolt left its working files"
# The saved profile, with no workload.
out=$(rig build --release --bolt --bolt-profile=p.fdata -o prog2 p.rig 2>&1); expect_rc $? 0 "build by a saved profile: $out"
expect_eq "$(./prog2)" "$want" "the program laid out by a saved profile"
exit 0
