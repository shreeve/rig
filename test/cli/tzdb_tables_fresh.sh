# std/tzdb_data.zig, std/tzdb_names.zig, and std/tzdb_test_data.zig are
# what tools/gen-tzdb.py generates from its pinned inputs (Jiff 1.0.0's
# crates and its test zone file), and the version std.datetime reports
# is the generator's. The inputs are read from $RIG_TZDB, else
# ~/.cache/rig-tzdb; where they are not all there the tables are not
# regenerated, since the generator would fetch them.
source "$ROOT/test/cli/_lib.sh"

version=$(sed -n 's/^TZDB_VERSION = "\(.*\)"$/\1/p' "$ROOT/tools/gen-tzdb.py")
[[ -n $version ]] || fail "no TZDB_VERSION in tools/gen-tzdb.py"
expect_has "$(cat "$ROOT/std/tzdb_data.zig")" "pub const version = \"$version\";" "the tables' version"
expect_has "$(head -3 "$ROOT/std/tzdb_names.zig")" "Database
//! $version" "the names' version"
names=$(grep -c '^    \\\\' "$ROOT/std/tzdb_names.zig")
expect_eq "$names" 598 "the names"

cat >version.rig <<'EOF2'
use std.datetime

sub main()
  print(datetime.tzdb_version(), datetime.zone_names().len)
EOF2
expect_eq "$(rig run version.rig 2>&1)" "$version $names" "tzdb_version and zone_names"

cache=${RIG_TZDB:-$HOME/.cache/rig-tzdb}
for f in jiff-1.0.0.crate jiff-tzdb-1.0.0.crate europe-dublin.tzif; do
    if [[ ! -f $cache/$f ]]; then
        echo "$cache/$f is not there: tables not regenerated"
        exit 0
    fi
done
command -v python3 >/dev/null || fail "python3 is needed to regenerate the tables"
python3 -I "$ROOT/tools/gen-tzdb.py" --cache "$cache" --check "$ROOT/std" || fail "the zone tables are stale"
echo "tables current ($version)"
