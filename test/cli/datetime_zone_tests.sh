# std.datetime's own tests of zone rules, on the pinned test table
# (std/datetime/zone_test.rig, docs/design/datetime.md §7.5): `rig test
# std.datetime` runs them, from the checkout's std and from the one
# built into rig. A program cannot reach the test table: its function
# is only in the module's test file.
source "$ROOT/test/cli/_lib.sh"

for how in disk embedded; do
    if [[ $how == disk ]]; then
        out=$(RIG_STD="$ROOT/std" rig test std.datetime 2>&1)
    else
        out=$(rig test std.datetime 2>&1)
    fi
    expect_rc $? 0 "rig test std.datetime ($how): $out"
    expect_has "$out" 'ok    test "Dublin in the standard form: Irish Standard Time in summer, GMT in winter"' "Dublin ($how)"
    expect_has "$out" 'ok    test "Test/Morocco: daylight saving all year, +01:00 at each end of a year"' "Morocco ($how)"
    expect_has "$out" ' 0 failed' "the count ($how)"
done

cat >reach.rig <<'EOF2'
use std.datetime

sub main()
  print(datetime.test_zone_find("Europe/Dublin"))
EOF2
out=$("$RIG" check reach.rig 2>&1); expect_rc $? 1 "a program naming the test table"
expect_has "$out" "test_zone_find" "the test table's function is not std.datetime's"
