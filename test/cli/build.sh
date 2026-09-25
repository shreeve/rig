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

cat >lib.rig <<'EOF'
pub fun twice(n: Int) -> Int
  n * 2
EOF
"$RIG" build lib.rig 2>err.txt; rc=$?
expect_rc $rc 1 "building a module without main"
expect_has "$(cat err.txt)" "no \`sub main()\`" "building a module without main"
exit 0
