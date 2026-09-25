# Two programs in different directories whose output directories sit at
# the same path relative to where rig runs, with byte-identical root
# modules, each run their own code: Zig keys a cached build by the root
# file's cwd-relative path, so a shared Zig cache would hand the second
# program the first one's executable. So does `rig test`, whose driver
# depends only on the module names, and so does a later edit to a module.
source "$ROOT/test/cli/_lib.sh"

for p in one two; do
  mkdir $p
  printf 'use util\n\nsub main()\n  print(util.who())\n' >$p/main.rig
  printf 'use util\n\ntest "who"\n  print(util.who())\n' >$p/t.rig
done
printf 'pub fun who() -> Int\n  1\n' >one/util.rig
printf 'pub fun who() -> Int\n  2\n' >two/util.rig

out=$(cd one && RIG_OUT_DIR=out "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "first program"
out=$(cd two && RIG_OUT_DIR=out "$RIG" run main.rig 2>&1); expect_eq "$out" "2" "second program, same relative output directory"

printf 'pub fun who() -> Int\n  3\n' >two/util.rig
out=$(cd two && RIG_OUT_DIR=out "$RIG" run main.rig 2>&1); expect_eq "$out" "3" "edited module"

out=$(cd one && RIG_OUT_DIR=tout "$RIG" test t.rig 2>&1); expect_eq "${out%%$'\n'*}" "1" "first program's tests"
out=$(cd two && RIG_OUT_DIR=tout "$RIG" test t.rig 2>&1); expect_eq "${out%%$'\n'*}" "3" "second program's tests"
exit 0
