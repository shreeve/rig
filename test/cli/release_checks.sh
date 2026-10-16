# Release builds keep indexing, slicing, element-method, and (with
# --release) conversion checks: each program below panics instead of
# running on. The first is built with `rig build` and its executable
# run; the rest use `rig run`, which builds in the same mode and caches
# its build for the next run.
# timeout: 600
source "$ROOT/test/cli/_lib.sh"

# Indexing and slicing stay checked under --release=fast.
cat >index.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  a = [1, 2, 3]
  print(a[rt(3)])
EOF
rig build --release=fast -o index index.rig || fail "rig build --release=fast"
out=$(RIG_NO_CRASH_REPORT=1 ./index 2>&1); rc=$?
expect_has "$out" "index out of bounds" "fast build index check"
[[ $rc -ne 0 ]] || fail "fast build: out-of-bounds index exited 0"

cat >slice.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  s = "abc"
  print(s[0..rt(4)])
EOF
out=$(RIG_NO_CRASH_REPORT=1 rig run --release=fast slice.rig 2>&1); rc=$?
expect_has "$out" "slice bounds out of range" "fast build slice check"
[[ $rc -ne 0 ]] || fail "fast build: out-of-range slice exited 0"

# So do the element methods' checks.
cat >copy.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  a = [1, 2, 3]
  b = [4, 5, 6]
  !a.copy(?b[..rt(2)])
EOF
out=$(RIG_NO_CRASH_REPORT=1 rig run --release=fast copy.rig 2>&1); rc=$?
expect_has "$out" "copy between slices of different lengths" "fast build copy check"
[[ $rc -ne 0 ]] || fail "fast build: copy of a different length exited 0"

cat >swap.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  a = [1, 2, 3]
  !a.swap(0, rt(3))
EOF
out=$(RIG_NO_CRASH_REPORT=1 rig run --release=fast swap.rig 2>&1); rc=$?
expect_has "$out" "index out of bounds" "fast build swap check"
[[ $rc -ne 0 ]] || fail "fast build: out-of-range swap exited 0"

cat >bytes.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  b: [4]U8 = [1, 2, 3, 4]
  print(b.read[U32, .big](rt(1)))
EOF
out=$(RIG_NO_CRASH_REPORT=1 rig run --release=fast bytes.rig 2>&1); rc=$?
expect_has "$out" "byte read out of range" "fast build read check"
[[ $rc -ne 0 ]] || fail "fast build: read past the end exited 0"

cat >store.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  b: [4]U8 = [1, 2, 3, 4]
  !b.write[U16, .little](rt(3), 7)
EOF
out=$(RIG_NO_CRASH_REPORT=1 rig run --release=fast store.rig 2>&1); rc=$?
expect_has "$out" "byte write out of range" "fast build write check"
[[ $rc -ne 0 ]] || fail "fast build: write past the end exited 0"

# --release keeps the conversion checks.
cat >convert.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  print(I8(rt(300)))
EOF
out=$(RIG_NO_CRASH_REPORT=1 rig run --release convert.rig 2>&1); rc=$?
expect_has "$out" "integer does not fit in destination type" "release build conversion check"
[[ $rc -ne 0 ]] || fail "release build: failing conversion exited 0"

# Vector lanes follow the scalar rule: --release keeps the lane overflow
# check and --release=fast drops it (an overflowing lane is undefined
# there, so the run asserts only that no check fired).
cat >vecover.rig <<'EOF'
fun rt(n: I8) -> I8
  n

sub main()
  v = Simd[I8, 16].splat(rt(127))
  print(v + 1)
  print(v << 1)
EOF
out=$(RIG_NO_CRASH_REPORT=1 rig run --release vecover.rig 2>&1); rc=$?
expect_has "$out" "integer overflow" "release build vector add check"
[[ $rc -ne 0 ]] || fail "release build: overflowing vector add exited 0"
out=$(rig run --release=fast vecover.rig 2>&1); rc=$?
[[ "$out" != *overflow* ]] || fail "fast build kept a vector overflow check: $out"
expect_rc "$rc" 0 "fast build vector overflow"

# A vector program that does not overflow prints the same in every mode.
cat >vecsame.rig <<'EOF'
fun rt(n: I16) -> I16
  n

sub main()
  a = Simd[I16, 8].splat(rt(100))
  b = Simd[I16, 8].splat(rt(-7))
  print(a + b)
  print(a - b)
  print(a * b)
  print(-b)
  print(a << 2)
EOF
want=$(rig run vecsame.rig 2>&1) || fail "debug vector run: $want"
for m in --release --release=fast; do
    got=$(rig run "$m" vecsame.rig 2>&1) || fail "vector run $m: $got"
    expect_eq "$got" "$want" "vector output under $m"
done
