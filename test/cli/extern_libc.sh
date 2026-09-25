# A program that declares an `extern` in any module links libc, which
# Zig requires for `extern "c"` on targets other than macOS: `run`,
# `build`, and `test` pass `-lc`. A program without one does not.
source "$ROOT/test/cli/_lib.sh"

real_zig=$(command -v "${ZIG:-zig}") || fail "no zig"
cat >zigw <<EOF2
#!/usr/bin/env bash
echo "\$*" >>"$PWD/zig.log"
exec "$real_zig" "\$@"
EOF2
chmod +x zigw
export ZIG=$PWD/zigw

cat >cabs.rig <<'EOF2'
extern fun abs(n: Int) -> Int

pub fun safe_abs(n: Int) -> Int
  raw
    abs(n)
EOF2
cat >main.rig <<'EOF2'
use cabs

sub main()
  print(cabs.safe_abs(-5))

test "abs"
  print(cabs.safe_abs(-6))
EOF2
cat >plain.rig <<'EOF2'
sub main()
  print(1)
EOF2

out=$("$RIG" run main.rig 2>&1); expect_eq "$out" "5" "run"
"$RIG" build -o prog main.rig || fail "build"
out=$("$RIG" test main.rig 2>&1); expect_has "$out" "1 passed" "test"
"$RIG" run plain.rig >/dev/null || fail "plain run"

log=$(cat zig.log)
expect_eq "$(grep -c -- ' -lc' <<<"$log")" "3" "-lc for run, build, and test: $log"
expect_eq "$(tail -1 <<<"$log" | grep -c -- '-lc')" "0" "no -lc without an extern"
exit 0
