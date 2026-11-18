# `rig build` writes a native executable: ./<name> by default, or -o;
# Zig's debug mode by default, its safe mode with --release, which keeps
# overflow checks. No flag builds without them: `--release=fast` is a
# usage error that names the opt-outs a program writes instead.
# timeout: 120
# builds: shared
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

rig build sum.rig || fail "rig build"
[[ -x ./sum ]] || fail "rig build did not write ./sum"
out=$(./sum 2>&1); rc=$?
expect_has "$out" "total 135" "debug build"
expect_has "$out" "integer overflow" "debug build overflow check"
[[ $rc -ne 0 ]] || fail "debug build: overflow exited 0"

rig build --release -o bin/sum-safe sum.rig 2>/dev/null && fail "-o into a missing directory succeeded"
mkdir bin
rig build --release -o bin/sum-safe sum.rig || fail "rig build --release"
out=$(bin/sum-safe 2>&1); rc=$?
expect_has "$out" "total 135" "release build"
expect_has "$out" "integer overflow" "release build keeps overflow checks"
[[ $rc -ne 0 ]] || fail "release build: overflow exited 0"

for verb in build run test; do
    out=$(rig $verb --release=fast sum.rig 2>&1); rc=$?
    expect_rc $rc 2 "rig $verb --release=fast"
    expect_has "$out" "\`--release=fast\` is gone: every build keeps Rig's checks" "rig $verb --release=fast"
    expect_has "$out" "\`+%\`" "rig $verb --release=fast names wrapping arithmetic"
done
out=$(rig build --release=small sum.rig 2>&1); expect_rc $? 2 "rig build --release=small"
expect_has "$out" "unknown option \`--release=small\`" "rig build --release=small"
out=$(rig batch build --release=fast batch sum.rig 2>&1); expect_rc $? 2 "rig batch build --release=fast"
expect_has "$out" "\`--release=fast\` is gone" "rig batch build --release=fast"
[[ ! -e batch ]] || fail "rig batch build --release=fast made its directory"

cat >lib.rig <<'EOF'
pub fun twice(n: Int) -> Int
  n * 2
EOF
rig build lib.rig 2>err.txt; rc=$?
expect_rc $rc 1 "building a module without main"
expect_has "$(cat err.txt)" "no \`sub main()\`" "building a module without main"
exit 0
