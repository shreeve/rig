# std.os reads the arguments and environment the program started with:
# `rig run file.rig -- args...` passes arguments, as running a built
# executable does, and `fun main -> Int` can report on them.
source "$ROOT/test/cli/_lib.sh"

cat >args.rig <<'EOF2'
use std.os

fun main -> Int
  args = os.args()
  for a, i in args[1..]
    print(i, a)
  print(os.env("RIG_STD_OS_TEST") ?? "unset")
  args.len - 1
EOF2
out=$(rig run args.rig -- one "two words" 2>&1); expect_rc $? 2 "rig run with arguments"
expect_eq "$out" $'0 one\n1 two words\nunset' "rig run with arguments"
out=$(RIG_STD_OS_TEST=set rig run args.rig 2>&1); expect_rc $? 0 "rig run without arguments"
expect_eq "$out" "set" "the environment"
out=$(RIG_STD_OS_TEST= rig run args.rig 2>&1); expect_rc $? 0 "an empty variable"
expect_eq "$out" "" "an empty variable is set, to nothing"

rig build -o args args.rig >/dev/null 2>&1 || fail "build args.rig"
out=$(./args -x "" 2>&1); expect_rc $? 2 "built program's arguments"
expect_eq "$out" $'0 -x\n1 \nunset' "built program's arguments"

printf 'use std.os\n\nsub main()\n  print(os.args()[0].len > 0)\n' >name.rig
out=$(rig run name.rig 2>&1); expect_rc $? 0 "the program's name"
expect_eq "$out" "true" "the program's name comes first"

out=$("$RIG" check args.rig -- x 2>&1); expect_rc $? 2 "arguments after -- for check"
expect_has "$out" "arguments after \`--\` are for the program \`rig run\` runs" "arguments after -- for check"
exit 0
