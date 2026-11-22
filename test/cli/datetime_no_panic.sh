# No call of std.time or std.datetime panics on any value: each is total
# or returns `!` (docs/design/datetime.md, "Total or visible", §7.2, §12).
# So no `panic(` appears in their source, and no other way to panic that
# a std file can write: `unreachable` or a `?? panic` fallback. Nor in
# their Zig shims and the zone tables: no `@panic`, `unreachable`, or
# `.?`.
source "$ROOT/test/cli/_lib.sh"

files=("$ROOT/std/time.rig" "$ROOT"/std/datetime/*.rig)
(( ${#files[@]} > 1 )) || fail "no std.datetime files under $ROOT/std/datetime"
found=$(grep -nE '\bpanic\(|\bunreachable\b' "${files[@]}" | grep -vE '^[^:]+:[0-9]+:\s*#')
[[ -z $found ]] || fail "std's time code can panic: $found"
shims=("$ROOT/std/time.zig" "$ROOT/std/datetime.zig" "$ROOT"/std/tzdb_*.zig)
found=$(grep -nE '@panic\(|\bunreachable\b|\.\?' "${shims[@]}" | grep -vE '^[^:]+:[0-9]+:\s*//')
[[ -z $found ]] || fail "std's time shims can panic: $found"
echo "no panic in ${#files[@]} files and ${#shims[@]} shims"
