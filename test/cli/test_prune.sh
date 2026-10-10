# A run with no filter removes the output of tests that are gone, but
# keeps the output, and so the build cache, of every corpus program that
# still exists, though it runs only a sample of them. It also removes
# the build store's old builds.
source "$ROOT/test/cli/_lib.sh"
export RIG_BUILD_STORE=   # until the store's own check, below

out=$PWD/out
o=$(RIG_TEST_OUT="$out" "$ROOT/test/run" --prune 2>&1) || fail "first prune: $o"
[[ -f "$out/.rig-test" ]] || fail "the output directory was not marked"

names=$(cd "$ROOT/test/corpus" && ls | head -32 | sed 's/\.rig$//')
[[ $(wc -l <<<"$names") -eq 32 ]] || fail "expected 32 corpus programs, found: $names"
for n in $names gone-probe; do mkdir -p "$out/corpus/$n/.zig-cache" && : >"$out/corpus/$n/.zig-cache/kept"; done
mkdir -p "$out/behavior/gone_area/gone_test/.zig-cache"

o=$(RIG_TEST_OUT="$out" "$ROOT/test/run" --prune 2>&1) || fail "prune: $o"
for n in $names; do
  [[ -f "$out/corpus/$n/.zig-cache/kept" ]] || fail "removed the build cache of corpus/$n, which exists"
done
[[ -e "$out/corpus/gone-probe" ]] && fail "kept the output of a corpus program that is gone"
[[ -e "$out/behavior/gone_area" ]] && fail "kept the output of a test that is gone"

# The build store loses the builds unused for RIG_BUILD_STORE_DAYS.
# Each goes into the trash in one step, and the trash, with whatever an
# interrupted prune left there, is deleted.
mkdir -p store/old/package store/new/package store/.trash.1.interrupted/o store/.started
touch store/new/used store/.started/.started-new && touch -t 200001010000 store/old/used store/.started/.started-old
o=$(RIG_BUILD_STORE=$PWD/store RIG_BUILD_STORE_DAYS=3 RIG_TEST_OUT="$out" "$ROOT/test/run" --prune 2>&1) || fail "prune: $o"
[[ -e store/old ]] && fail "kept a build unused for years"
[[ -f store/new/used ]] || fail "removed a build used today"
[[ -n $(find store -name '.trash.*') ]] && fail "left the trash: $(find store -name '.trash.*')"
[[ -e store/.started/.started-old ]] && fail "kept the evidence file of a run long gone"
[[ -e store/.started/.started-new ]] || fail "removed the evidence file of a run that may be going on"

# So does a store that is a link to a directory elsewhere.
mkdir -p realstore/old/package && touch -t 200001010000 realstore/old/used && ln -s realstore linkstore
o=$(RIG_BUILD_STORE=$PWD/linkstore RIG_BUILD_STORE_DAYS=3 RIG_TEST_OUT="$out" "$ROOT/test/run" --prune 2>&1) || fail "prune: $o"
[[ -e realstore/old ]] && fail "kept a build unused for years in a linked store"

# By default a build goes once unused for 2 days.
ago() { date -v-"$1"H +%Y%m%d%H%M 2>/dev/null || date -d "-$1 hours" +%Y%m%d%H%M; }
mkdir -p dstore/three/package dstore/one/package
touch -t "$(ago 73)" dstore/three/used
touch -t "$(ago 25)" dstore/one/used
o=$(RIG_BUILD_STORE=$PWD/dstore RIG_BUILD_STORE_DAYS= RIG_TEST_OUT="$out" "$ROOT/test/run" --prune 2>&1) || fail "prune: $o"
[[ -e dstore/three ]] && fail "kept a build unused for 3 days by default"
[[ -f dstore/one/used ]] || fail "removed a build used a day ago by default"
o=$(RIG_TEST_OUT="$out" "$ROOT/test/run" --prune corpus 2>&1); expect_rc $? 2 "--prune with a filter"
exit 0
