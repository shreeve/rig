# `rig build` writes a native executable: ./<name> by default, or -o;
# Debug by default, ReleaseSafe with --release, ReleaseFast with
# --release=fast. ReleaseSafe keeps overflow checks.
source "$ROOT/test/cli/_lib.sh"

cat >sum.rig <<'EOF'
fun scale(n: Int, by: Int) -> Int
  n * by

sub main()
  total = 0
  i = 0
  while i < 10
    total += scale(i, 3)
    i += 1
  print("total", total)
  print(scale(4611686018427387904, total))
EOF

"$RIG" build sum.rig || fail "rig build"
[[ -x ./sum ]] || fail "rig build did not write ./sum"
out=$(./sum 2>&1); rc=$?
expect_has "$out" "total 135" "debug build"
expect_has "$out" "integer overflow" "debug build overflow check"
[[ $rc -ne 0 ]] || fail "debug build: overflow exited 0"

"$RIG" build --release -o bin/sum-safe sum.rig 2>/dev/null && fail "-o into a missing directory succeeded"
mkdir bin
"$RIG" build --release -o bin/sum-safe sum.rig || fail "rig build --release"
out=$(bin/sum-safe 2>&1); rc=$?
expect_has "$out" "total 135" "release build"
expect_has "$out" "integer overflow" "release build keeps overflow checks"
[[ $rc -ne 0 ]] || fail "release build: overflow exited 0"

cat >fast.rig <<'EOF'
sub main()
  print("fast", 6 * 7)
EOF
"$RIG" build --release=fast -o bin/fast fast.rig || fail "rig build --release=fast"
expect_eq "$(bin/fast)" "fast 42" "fast build"

# Indexing and slicing stay checked under --release=fast.
cat >index.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  a = [1, 2, 3]
  print(a[rt(3)])
EOF
"$RIG" build --release=fast -o bin/index index.rig || fail "rig build --release=fast index.rig"
out=$(bin/index 2>&1); rc=$?
expect_has "$out" "index out of bounds" "fast build index check"
[[ $rc -ne 0 ]] || fail "fast build: out-of-bounds index exited 0"

cat >slice.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  s = "abc"
  print(s[0..rt(4)])
EOF
"$RIG" build --release=fast -o bin/slice slice.rig || fail "rig build --release=fast slice.rig"
out=$(bin/slice 2>&1); rc=$?
expect_has "$out" "slice bounds out of range" "fast build slice check"
[[ $rc -ne 0 ]] || fail "fast build: out-of-range slice exited 0"

# --release keeps the conversion checks.
cat >convert.rig <<'EOF'
fun rt(n: Int) -> Int
  n

sub main()
  print(I8(rt(300)))
EOF
"$RIG" build --release -o bin/convert convert.rig || fail "rig build --release convert.rig"
out=$(bin/convert 2>&1); rc=$?
expect_has "$out" "integer does not fit in destination type" "release build conversion check"
[[ $rc -ne 0 ]] || fail "release build: failing conversion exited 0"

cat >lib.rig <<'EOF'
pub fun twice(n: Int) -> Int
  n * 2
EOF
"$RIG" build lib.rig 2>err.txt; rc=$?
expect_rc $rc 1 "building a module without main"
expect_has "$(cat err.txt)" "no \`sub main()\`" "building a module without main"
exit 0
