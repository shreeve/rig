# Two programs in different directories whose output directories sit at
# the same path relative to where rig runs, with byte-identical root
# modules, each run their own code, never the other's cached executable.
# So does `rig test`, whose driver depends only on the module names, and
# so does a later edit to a module. Both hold for builds in the output
# directory, with Zig, and in a build store, whose entries a stand-in
# for Zig checks: each build has an entry, and so a Zig cache, of its
# own.
source "$ROOT/test/cli/_lib.sh"

for p in one two; do
  mkdir $p
  printf 'use util\n\nsub main()\n  print(util.who())\n' >$p/main.rig
  printf 'use util\n\ntest "who"\n  print(util.who())\n' >$p/t.rig
done

# A stand-in for `zig run ... --cache-dir DIR ROOT`: it records DIR, and
# runs the program by printing what the package's `who` returns.
cat >fakezig <<'SH'
#!/bin/sh
while [ $# -gt 0 ]; do
  case $1 in
    --cache-dir) dir=$2; shift ;;
    *.zig) root=$1 ;;
  esac
  shift
done
echo "$dir" >>"$CACHES"
: >"$RIG_PROGRAM_STARTED"
sed -n 's/.*return \([0-9]*\);.*/\1/p' "$(dirname "$root")/util.zig"
SH
chmod +x fakezig
export CACHES=$PWD/caches

# Built in the output directories with Zig, and in a build store.
for store in "" "$PWD/store"; do
  mode=${store:+ (store)}
  zig=${ZIG:-zig}
  [[ -n $store ]] && zig=$PWD/fakezig
  rm -rf one/out one/tout two/out two/tout caches
  printf 'pub fun who() -> Int\n  1\n' >one/util.rig
  printf 'pub fun who() -> Int\n  2\n' >two/util.rig

  out=$(cd one && ZIG=$zig RIG_BUILD_STORE=$store RIG_OUT_DIR=out "$RIG" run main.rig 2>&1); expect_eq "$out" "1" "first program$mode"
  out=$(cd two && ZIG=$zig RIG_BUILD_STORE=$store RIG_OUT_DIR=out "$RIG" run main.rig 2>&1); expect_eq "$out" "2" "second program, same relative output directory$mode"

  printf 'pub fun who() -> Int\n  3\n' >two/util.rig
  out=$(cd two && ZIG=$zig RIG_BUILD_STORE=$store RIG_OUT_DIR=out "$RIG" run main.rig 2>&1); expect_eq "$out" "3" "edited module$mode"

  out=$(cd one && ZIG=$zig RIG_BUILD_STORE=$store RIG_OUT_DIR=tout "$RIG" test t.rig 2>&1); expect_eq "${out%%$'\n'*}" "1" "first program's tests$mode"
  out=$(cd two && ZIG=$zig RIG_BUILD_STORE=$store RIG_OUT_DIR=tout "$RIG" test t.rig 2>&1); expect_eq "${out%%$'\n'*}" "3" "second program's tests$mode"
  if [[ -z $store ]]; then
    [[ -f one/out/__rig_main.zig && -d one/out/.zig-cache ]] || fail "without a store, rig did not build in the output directory"
  else
    [[ ! -e one/out && -n $(find store -mindepth 1 -maxdepth 1 -type d ! -name '.*') ]] || fail "with a store, rig did not build in it"
    expect_eq "$(wc -l <caches | tr -d ' ')" 5 "builds in the store"
    expect_eq "$(sort -u caches | wc -l | tr -d ' ')" 5 "Zig caches of the five builds in the store"
  fi
done
exit 0
