# A program that declares an `extern` in any module links libc, which
# Zig requires for `extern "c"` on targets other than macOS: `run`,
# `build`, and `test` pass `-lc`. A program without one does not. One
# run builds with Zig; the others hand their arguments to a stand-in
# that only records them.
source "$ROOT/test/cli/_lib.sh"

real_zig=$(command -v "${ZIG:-zig}") || fail "no zig"
cat >zigw <<EOF2
#!/usr/bin/env bash
echo "\$*" >>"$PWD/zig.log"
exec "$real_zig" "\$@"
EOF2
cat >zigs <<EOF2
#!/usr/bin/env bash
echo "\$*" >>"$PWD/zig.log"
EOF2
chmod +x zigw zigs

cat >cabs.rig <<'EOF2'
extern fun abs(n: I32) -> I32

pub fun safe_abs(n: I32) -> I32
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

out=$(ZIG=$PWD/zigw rig run main.rig 2>&1); expect_eq "$out" "5" "run"
ZIG=$PWD/zigs rig build -o prog main.rig || fail "build"
ZIG=$PWD/zigs rig test main.rig >/dev/null 2>&1
ZIG=$PWD/zigs rig run plain.rig >/dev/null 2>&1

log=$(cat zig.log)
expect_eq "$(grep -c -- ' -lc' <<<"$log")" "3" "-lc for run, build, and test: $log"
expect_eq "$(tail -1 <<<"$log" | grep -c -- '-lc')" "0" "no -lc without an extern"
exit 0
