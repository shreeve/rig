# std/unicode_tables.zig, std/char_tables.zig, std/width_tables.zig, and
# the census tests are what tools/gen-unicode.py generates from the
# pinned Character Database, and every code point's class matches the
# database (tools/verify-unicode.py). The generator's versions are the
# ones std.unicode reports. The database is read from $RIG_UCD, a
# directory holding a directory of each version's files, so without it
# the generated files are not rebuilt (set it to run this check; the
# generator fetches any file it lacks).
source "$ROOT/test/cli/_lib.sh"

version=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$ROOT/tools/gen-unicode.py")
id_version=$(sed -n 's/^ID_VERSION = "\(.*\)"$/\1/p' "$ROOT/tools/gen-unicode.py")
expect_has "$(cat "$ROOT/std/unicode.rig")" "pub VERSION = \"$version\"" "std.unicode.VERSION"
expect_has "$(cat "$ROOT/std/unicode.rig")" "pub ID_VERSION = \"$id_version\"" "std.unicode.ID_VERSION"
expect_has "$(cat "$ROOT/std/unicode_tables.zig")" "pub const version = \"$id_version\";" "identifier table version"
expect_has "$(cat "$ROOT/std/char_tables.zig")" "pub const version = \"$version\";" "char table version"
expect_has "$(cat "$ROOT/std/width_tables.zig")" "pub const version = \"$version\";" "width table version"

if [[ -z ${RIG_UCD:-} ]]; then
    echo "RIG_UCD is not set: tables not regenerated"
    exit 0
fi
command -v python3 >/dev/null || fail "python3 is needed to regenerate the tables"
python3 -I "$ROOT/tools/gen-unicode.py" --ucd "$RIG_UCD" --check || fail "generated files are stale"
python3 -I "$ROOT/tools/verify-unicode.py" --ucd "$RIG_UCD" --rig "$RIG" || fail "tables differ from the Character Database"
