# RIG_UNIT_LAUNCHER, a command split on spaces, goes before each unit's
# `zig build-obj` in a split build, and before nothing else: a wrapper
# that records its calls and runs its arguments runs once per unit, and
# the program it built runs. A launcher that is not there is named.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >launch.sh <<'EOF2'
#!/bin/sh
tag=$1; shift
printf '%s %s\n' "$tag" "$*" >>"$LAUNCH_LOG"
exec "$@"
EOF2
chmod +x launch.sh
export LAUNCH_LOG=$PWD/launch.log

cat >main.rig <<'EOF2'
called fun sq(x: Int) -> Int
  x * x

sub main()
  print("sq", sq(7))
EOF2

# The package's directory lasts between runs, for Zig's cache; the
# executable a build kept is removed, so Zig runs and the units compile.
dir="$RIG_OUT_DIR/programs/unit-launcher"
build() {
    rm -rf "$dir/.zig-cache/rig-build"
    RIG_OUT_DIR="$dir" "$RIG" build --units=2 -o prog main.rig
}

: >launch.log
RIG_UNIT_LAUNCHER="$PWD/launch.sh  tag-1" build || fail "rig build --units=2 under a launcher"
expect_eq "$(wc -l <launch.log | tr -d ' ')" 2 "one launch per unit, none for the link"
expect_eq "$(grep -c '^tag-1 .* build-obj ' launch.log)" 2 "each launch is a unit's build-obj, with the launcher's words"
grep -q '__rig_unit_0\.zig' launch.log || fail "unit 0 was not launched"
grep -q '__rig_unit_1\.zig' launch.log || fail "unit 1 was not launched"
expect_eq "$(./prog 2>&1)" "sq 49" "the program built under a launcher"

: >launch.log
rm -f prog
RIG_UNIT_LAUNCHER= build || fail "rig build --units=2 with RIG_UNIT_LAUNCHER empty"
[[ -s launch.log ]] && fail "an empty RIG_UNIT_LAUNCHER launched"
expect_eq "$(./prog 2>&1)" "sq 49" "the program built with no launcher"

RIG_UNIT_LAUNCHER="$PWD/no-such-launcher --" build 2>err.txt && fail "a missing launcher built"
expect_has "$(cat err.txt)" "cannot run \`$PWD/no-such-launcher\`, the command RIG_UNIT_LAUNCHER names" "a missing launcher"
exit 0
