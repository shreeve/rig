# timeout: 600
# The List and String hot paths, built with --release: clearing plain
# and owned elements and pushing across growth boundaries give the same
# output as the debug build, which the behavior tests check.
source "$ROOT/test/cli/_lib.sh"

for t in list_clear_reuse list_push_growth string_push_boundaries; do
  src="$ROOT/test/behavior/runtime/$t.rig"
  want=$(sed -n "/^# expect:/,\$p" "$src" | sed "1d;s/^# \\{0,1\\}//")
  out=$(rig run --release "$src" 2>&1) || fail "$t: rig run --release failed: $out"
  expect_eq "$out" "$want" "$t under --release"
done
