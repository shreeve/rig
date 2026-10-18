# std.os reads the arguments and environment the program started with:
# `rig run file.rig -- args...` passes arguments, as running a built
# executable does, and `fun main() -> Int` can report on them. The first
# argument is the path the program was started by.
source "$ROOT/test/cli/_lib.sh"

# args.rig prints its arguments after the first, and a variable, and
# writes the first to stderr.
cat >args.rig <<'EOF2'
use std.os

fun main() -> Int
  args = os.args()
  warn(args[0])
  for a, i in args[1..]
    print(i, a)
  print(os.env("RIG_STD_OS_TEST") ?? "unset")
  args.len - 1
EOF2
# Under `rig run`, the first argument is the executable built in the
# package's cache, in the output directory or the build store.
out=$(RIG_BUILD_STORE= rig run args.rig -- one "two words" 2>err.txt); expect_rc $? 2 "rig run with arguments"
expect_eq "$out" $'0 one\n1 two words\nunset' "rig run with arguments"
expect_has "$(cat err.txt)" "$RIG_OUT_DIR/programs/args/.zig-cache/" "under rig run, the cached executable comes first"
out=$(RIG_BUILD_STORE= RIG_STD_OS_TEST=set rig run args.rig 2>/dev/null); expect_rc $? 0 "rig run without arguments"
expect_eq "$out" "set" "the environment"
out=$(RIG_BUILD_STORE= RIG_STD_OS_TEST= rig run args.rig 2>/dev/null); expect_rc $? 0 "an empty variable"
expect_eq "$out" "" "an empty variable is set, to nothing"
mkdir store
out=$(RIG_BUILD_STORE=store rig run args.rig 2>err.txt); expect_rc $? 0 "built in a store"
[[ $(cat err.txt) =~ store/[0-9a-f]{32}/ ]] || fail "under rig run with a store, the cached executable comes first: $(cat err.txt)"

rig build -o args args.rig >/dev/null 2>&1 || fail "build args.rig"
out=$(./args -x "" 2>err.txt); expect_rc $? 2 "built program's arguments"
expect_eq "$out" $'0 -x\n1 \nunset' "built program's arguments"
expect_eq "$(cat err.txt)" "./args" "a built program's name comes first"
out=$(./args $'\xff' 2>/dev/null); expect_rc $? 1 "bytes that are not UTF-8"
expect_eq "$out" $'0 \xff\nunset' "arguments are the bytes given, not checked as UTF-8"

out=$("$RIG" check args.rig -- x 2>&1); expect_rc $? 2 "arguments after -- for check"
expect_has "$out" "arguments after \`--\` are for the program \`rig run\` runs" "arguments after -- for check"
exit 0
