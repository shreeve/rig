# `rig build --release --pgo -- WORKLOAD` optimizes the executable by
# LLVM's profile-guided optimization, trained on the workload
# (src/pgo.zig). On Linux it needs a program that links no C library, and
# llvm-profdata and the profile runtime of the LLVM Zig is built on; on
# the Mac, Apple's command-line tools. Elsewhere, or without them, it
# fails at once and says what it needs.
# Where they are there, the optimized program prints what the plain one
# does, a program that ends by `os.exit` writes its profile too, a saved
# profile (`--pgo-profile`) builds with no workload, and a profile of an
# older program is reported out of date, not refused. With `--strip` the
# optimized program has no debug information.
# timeout: 900
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

out=$("$RIG" build --release --pgo -o prog p.rig 2>&1); expect_rc $? 2 "--pgo without a workload"
expect_has "$out" "needs a workload" "--pgo without a workload"
out=$("$RIG" build --pgo -o prog p.rig -- ./prog 2>&1); expect_rc $? 2 "--pgo on a debug build"
expect_has "$out" "add \`--release\`" "--pgo on a debug build"
out=$("$RIG" run --release --pgo p.rig 2>&1); expect_rc $? 2 "--pgo on run"
out=$("$RIG" build --release --pgo-profile=p.profdata -o prog p.rig 2>&1); expect_rc $? 2 "--pgo-profile alone"

case $(uname -s) in
Linux)
    prf_sections() { readelf -S "$1" | grep __llvm_prf; } ;;
Darwin)
    prf_sections() { otool -l "$1" | grep __llvm_prf; }
    if ! xcrun --find llvm-profdata >/dev/null 2>&1; then
        echo "note: no Apple command-line tools: the optimized build is not checked"
        exit 0
    fi ;;
*)
    out=$("$RIG" build --release --pgo -o prog p.rig -- ./prog 2>&1); expect_rc $? 1 "--pgo elsewhere"
    expect_has "$out" "needs Linux or the Mac" "--pgo elsewhere"
    exit 0 ;;
esac

# A Zig whose clang is LLVM 99: no such llvm-profdata, and the error
# names the version and what to install.
zig=$(command -v "${ZIG:-zig}")
if [[ $(uname -s) == Linux ]]; then
cat >zig99 <<EOF2
#!/bin/sh
if [ "\$1 \$2" = "cc --version" ]; then echo "clang version 99.0.0"; exit 0; fi
exec "$zig" "\$@"
EOF2
chmod +x zig99
out=$(ZIG=$PWD/zig99 "$RIG" build --release --pgo -o prog p.rig -- ./prog 2>&1); expect_rc $? 1 "--pgo with no tools of Zig's LLVM"
expect_has "$out" "needs LLVM 99's llvm-profdata" "--pgo with no tools of Zig's LLVM"

llvm=$("$zig" cc --version | sed -n 's/.*clang version \([0-9]*\)\..*/\1/p' | head -1)
if ! command -v "llvm-profdata-$llvm" >/dev/null && [[ ! -x /usr/lib/llvm-$llvm/bin/llvm-profdata ]]; then
    echo "note: no llvm-profdata of LLVM $llvm (Zig's): the optimized build is not checked"
    exit 0
fi
fi
want=$(rig run --release p.rig 2>&1) || fail "rig run: $want"
out=$(rig build --release --pgo --pgo-profile=p.profdata -o prog p.rig -- ./prog 2>&1); expect_rc $? 0 "build --pgo: $out"
expect_eq "$(./prog)" "$want" "the optimized program"
[[ -s p.profdata ]] || fail "--pgo-profile kept no profile"
[[ -z $(prf_sections prog) ]] || fail "the optimized program still counts: $(prf_sections prog)"
left=$(find "$RIG_OUT_DIR/programs" -mindepth 2 -maxdepth 2 -type d -name pgo)
[[ -z $left ]] || fail "--pgo left its working files: $left"
# The build that trains has its dense guard sealed, or its dense paths
# train as cold: the workload reads the guard from the executable it runs.
cat >dense.rig <<'EOF2'
fun one() -> Int
  1

sub main()
  t = one()&
  print(>t)
EOF2
cat >train.sh <<'EOF2'
python3 - <<'PY' || exit 7
import sys
d = open("dense", "rb").read()
i = d.find(b"rig-dense-guard!")
sys.exit(0 if i >= 0 and int.from_bytes(d[i + 16:i + 24], "little") > 0 else 1)
PY
exec ./dense
EOF2
"$RIG" emit dense.rig 2>&1 | grep -q 'spawnDense(one' || fail "dense.rig: one is not on a dense stack"
out=$(rig build --release --pgo -o dense dense.rig -- sh train.sh 2>&1); expect_rc $? 0 "build with a sealed trained program: $out"
expect_eq "$(./dense)" "1" "the program trained on a dense stack"
# The saved profile, with no workload: it fits, so nothing is said.
out=$(rig build --release --pgo --pgo-profile=p.profdata -o prog2 p.rig 2>&1); expect_rc $? 0 "build by a saved profile: $out"
expect_eq "$(./prog2)" "$want" "the program built by a saved profile"
[[ $out == *"out of date"* ]] && fail "a fitting profile reported out of date: $out"
# A profile of an older program fits the functions that did not change
# and says how many did.
cat >p2.rig <<'EOF2'
fun step(n: Int) -> Int
  if n % 3 == 0
    return n / 3
  if n % 5 == 0
    return n + 7
  n * 2 + 1

sub main()
  s = 0
  for i in 0..200000
    s += step(i) % 7
  print(s)
EOF2
want2=$(rig run --release p2.rig 2>&1) || fail "rig run p2: $want2"
out=$(rig build --release --pgo --pgo-profile=p.profdata -o prog3 p2.rig 2>&1); expect_rc $? 0 "build by an older profile: $out"
expect_has "$out" "out of date" "build by an older profile"
expect_eq "$(./prog3)" "$want2" "the program built by an older profile"

# A program that ends by `os.exit` writes its profile as it ends.
cat >q.rig <<'EOF2'
use std.os

fun step(n: Int) -> Int
  if n % 3 == 0
    return n / 3
  n * 2 + 1

sub main()
  s = 0
  for i in 0..100000
    s += step(i) % 7
  print(s)
  os.exit(3)
EOF2
want=$(rig run --release q.rig 2>&1); expect_rc $? 3 "rig run q"
out=$(rig build --release --pgo -o qprog q.rig -- ./qprog 2>&1); expect_rc $? 0 "build --pgo by a workload that exits by os.exit: $out"
out=$(./qprog); expect_rc $? 3 "the optimized program's os.exit"
expect_eq "$out" "$want" "the optimized program that exits by os.exit"

# Without debug information: the same program, and none in it.
out=$(rig build --release --pgo --strip -o lean p.rig -- ./lean 2>&1); expect_rc $? 0 "build --pgo --strip: $out"
expect_eq "$(./lean)" "$(./prog)" "the optimized program without debug information"
case $(uname -s) in
Linux) debug_info() { readelf -S "$1" | grep -c '\.debug_info'; } ;;
Darwin) debug_info() { nm -ap "$1" | grep -c ' OSO '; } ;;
esac
[[ $(debug_info prog) -gt 0 ]] || fail "the optimized program has no debug information to tell a stripped one by"
expect_eq "$(debug_info lean)" 0 "debug information in the optimized program built with --strip"

# On the Mac a program of tasks keeps its section apart, x15 is its own,
# and the profile holds what the workload ran.
if [[ $(uname -s) == Darwin ]]; then
    cat >tasks.rig <<'EOF2'
fun work(n: Int) -> Int
  s = 0
  for i in 0..n
    s += i % 7
  s

sub main()
  a = work(200000)&
  b = work(300000)&
  print(>a + >b)
EOF2
    want=$(rig run --release tasks.rig 2>&1) || fail "rig run tasks: $want"
    out=$(rig build --release --pgo --pgo-profile=tasks.profdata -o tprog tasks.rig -- ./tprog 2>&1); expect_rc $? 0 "build --pgo of a program of tasks: $out"
    expect_eq "$(./tprog)" "$want" "the optimized program of tasks"
    [[ -d tprog.dSYM ]] || fail "--pgo wrote no .dSYM for a program whose section is kept apart"
    otool -l tprog | grep -q __rig_text || fail "the optimized program has no __rig_text"
    used=$(xcrun llvm-objdump -d --section=__rig_text tprog | grep -cE '\b[xw]15\b')
    [[ $used == 0 ]] || fail "the optimized program's own code uses x15 $used times"
    xcrun llvm-profdata show tasks.profdata | grep -q "Total functions: [1-9]" || fail "the profile holds no functions"
fi
exit 0
