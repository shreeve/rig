# A run with no filter removes the output of tests that are gone, but
# keeps the output, and so the build cache, of every corpus program that
# still exists, though it runs only a sample of them.
source "$ROOT/test/cli/_lib.sh"

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

o=$(RIG_TEST_OUT="$out" "$ROOT/test/run" --prune corpus 2>&1); expect_rc $? 2 "--prune with a filter"
exit 0
