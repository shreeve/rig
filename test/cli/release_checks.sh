# Release builds keep indexing, slicing, and (with --release) conversion
# checks: each program below panics instead of running on.
source "$ROOT/test/cli/_lib.sh"
mkdir bin

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
