# `rig run` builds in the mode its flag names, and concurrent runs of one
# program share its default output directory without breaking each
# other's builds. The modes are read from what rig hands a stand-in Zig;
# the concurrent runs build with Zig, in the fast mode. Output printed
# before a panic is the case `run output before a panic`
# (test/rig/runtime-run.rig.test).
source "$ROOT/test/cli/_lib.sh"

cat >hi.rig <<'EOF'
sub main()
  print("hi", 1 + 2)
EOF

cat >zigs <<EOF
#!/usr/bin/env bash
echo "\$1 \$2" >>"$PWD/zig.log"
EOF
chmod +x zigs
for flag in "" --release --release=safe --release=fast; do
  ZIG=$PWD/zigs rig run $flag hi.rig >/dev/null 2>&1
done
expect_eq "$(cat zig.log)" $'run -Odebug\nrun -Osafe\nrun -Osafe\nrun -Ofast' "the mode of each flag"

for i in 1 2 3 4; do
  (unset RIG_OUT_DIR RIG_BUILD_STORE; XDG_CACHE_HOME=$PWD/cache "$RIG" run --release=fast hi.rig >"par$i.txt" 2>&1; echo "rc $?" >>"par$i.txt") &
done
wait
for i in 1 2 3 4; do expect_eq "$(cat "par$i.txt")" $'hi 3\nrc 0' "concurrent run $i"; done
exit 0
